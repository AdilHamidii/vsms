import SwiftUI

/// The paywall. Every credit the app has ever earned came through this sheet.
///
/// ── What the 2026-08 audit found here ────────────────────────────────────
///
/// **It never said what a credit BUYS.** The ladder led with credits and a
/// per-credit price, which answers "is this good value?" — a question nobody
/// asked. The question they arrive with is *"how many verifications is that?"*,
/// and the sheet had no answer anywhere on it. Each row now LEADS with that
/// figure, derived from real route prices, with credits and unit price demoted
/// to a secondary line. When it cannot be derived honestly (no catalog, or a
/// non-SMS purchase) it is simply absent — never estimated.
///
/// **It never said what the user was buying.** They tap "Buy credits · Need 4
/// more" on a specific number and land on a generic pack list, so the purchase
/// loses its purpose in transit. The shortfall context — service, country,
/// price, what they hold — is now the first thing on the sheet.
///
/// **The shortfall hint was GREEN.** Green is this app's semantic colour for
/// "your code arrived" and "your credits came back"; spending it on "you are 4
/// short" is the same collision `AccentColor` documents. It is the accent now,
/// and it sits ABOVE the balance rather than below it — the user was reading
/// their balance before learning why the sheet had opened.
///
/// **The reassurances were 12pt footnotes BELOW the packs.** "Credits never
/// expire" and "unused credits come back" are the two sentences that make a
/// first purchase safe to make. They are above the ladder now, at real weight.
///
/// **Purchase errors were dead ends** — centred 12pt red text, no action, and
/// no distinction between "we couldn't load the packs" (retry the load) and
/// "the purchase failed" (retry the purchase). Both now carry the right retry.
///
/// **Restore purchases was buried in Account.** A user who was charged and saw
/// no credits is standing in THIS sheet. App Review 3.1.1 also expects it
/// wherever purchases are offered.
///
/// ⚠️ **Only a pack marked `optional` is ever filtered out, and only on the
/// live StoreKit answer.** A previous audit claimed `credits.60`/`credits.150`
/// were not APPROVED and proposed hiding them; both read `APPROVED` in App
/// Store Connect and credits.60 has been the top revenue product. Nothing is
/// hidden on a claim about ASC state — `visiblePacks` drops a row only when
/// StoreKit itself did not return that product AND the pack declared its
/// absence expected. Every other pack degrades to "Unavailable" instead, and
/// the marketing badges never move — see `CreditPack`.
struct CreditsSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(IAPStore.self) private var iap
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api

    var balance: Int
    /// Credit shortfall for what the user was trying to buy (0 = no context).
    /// Drives both the preselection and the context card.
    var needed: Int = 0
    var onPurchased: () async -> Void

    /// The pack the sheet opens on with no shortfall context, and the fallback
    /// for every lookup below. Resolved BY ID, never by index into the ladder —
    /// the ladder's length is not fixed (see `visiblePacks`), so an index is a
    /// silent way to end up on a different pack than MOST POPULAR.
    private static let defaultPackId = "md"

    @State private var selected: String = CreditsSheet.defaultPackId
    @State private var purchasing = false
    @State private var didPreselect = false
    @State private var appeared = false
    @State private var restoreNote: Note?
    @State private var restoreTask: Task<Void, Never>?

    /// Credits one VERIFICATION costs, and where that figure came from. Computed
    /// ONCE in `.task` rather than as a computed property: `AppState` is
    /// `@Observable`, so a property that walks ~9,000 routes would be
    /// re-evaluated on every body evaluation of every view that reads it —
    /// the exact trap the eSIM map hit.
    @State private var unit: UnitPrice = .unknown

    private struct Note: Equatable {
        let text: String
        let ok: Bool
    }

    /// Where the "one verification costs N credits" figure came from. The basis
    /// is stated to the user, because a bare "≈ 3 verifications" with no stated
    /// basis is the same unearned confidence as a seeded success rate.
    private enum UnitPrice: Equatable {
        /// No catalog, or a product credits do not price per-verification —
        /// eSIM, e-mail, and the rented line, which credits cannot buy at all.
        case unknown
        /// The exact route the user is short for.
        case route(credits: Int, service: String, country: String)
        /// Median of every active priced route in the catalog.
        case median(credits: Int)

        var credits: Int? {
            switch self {
            case .unknown:               nil
            case .route(let c, _, _):    c
            case .median(let c):         c
            }
        }
    }

    /// The ladder AS RENDERED, and the only list any consumer below may read.
    /// A selection, a recommendation and a row list that disagree about which
    /// packs exist can confirm a pack that is not on screen.
    ///
    /// An `optional` pack drops out once StoreKit has answered without it: its
    /// App Store review may still be pending, so its absence is expected and a
    /// row reading "Unavailable" would advertise a pack nobody can buy yet.
    /// Every other pack keeps that row — for an approved product, a missing
    /// one IS the signal that the fetch broke. While products are still
    /// loading `isMissing` is false for everything, so the full ladder renders.
    private var visiblePacks: [CreditPack] {
        CreditPack.all.filter { !($0.optional && isMissing($0)) }
    }

    private var pack: CreditPack {
        visiblePacks.first { $0.id == selected }
            ?? visiblePacks.first { $0.id == Self.defaultPackId }
            ?? CreditPack.all[0]
    }

    /// The pack the sheet opened on when there is a shortfall — the smallest
    /// one that unblocks them. Labelled on the row; a filled radio button was
    /// the only signal that a recommendation had been made at all.
    /// Only ever a pack that can actually be bought: recommending one StoreKit
    /// did not return puts "Covers what you need" on a row whose own CTA reads
    /// "Unavailable", and leaves the label on a different row from the
    /// selection once `snapToAvailable()` moves it.
    private var recommendedId: String? {
        guard needed > 0 else { return nil }
        let buyable = visiblePacks.filter { !isMissing($0) }
        guard !buyable.isEmpty else { return nil }
        return buyable.first { $0.credits >= needed }?.id ?? buyable.last?.id
    }

    /// True once StoreKit has answered with at least one product. Until then a
    /// missing product means "still loading", not "unavailable" — which is the
    /// distinction that keeps a transient fetch from reading as a dead pack.
    ///
    /// Both this and `isMissing` go through `IAPStore` rather than reading
    /// `iap.products` here, so the screenshot harness has a single seam — see
    /// `IAPStore.screenshotPricing`.
    private var productsLoaded: Bool { iap.hasLoadedProducts }

    private func isMissing(_ p: CreditPack) -> Bool {
        productsLoaded && !iap.has(p)
    }

    private var buttonLabel: String {
        if purchasing { return String(localized: "Processing…") }
        if iap.isLoadingProducts && !iap.has(pack) {
            return String(localized: "Loading…")
        }
        if !iap.has(pack) { return String(localized: "Unavailable") }
        // String(localized:) at the source: interpolation happens BEFORE
        // PrimaryButton's LocalizedStringKey lookup, so "Buy 12 credits" as a
        // key missed the catalog and the purchase button rendered English in
        // all six locales. Localizing here makes the key "Buy %lld credits".
        return String(localized: "Buy \(pack.credits) credits")
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Buy credits")

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // The shortfall context leads. It answers "why am I here?"
                    // before the sheet asks for money, and it carries the
                    // balance so the two are never read in the wrong order.
                    if needed > 0 {
                        contextCard
                            .riseIn(appeared, index: 0)
                    } else {
                        balanceCard
                            .riseIn(appeared, index: 0)
                    }

                    assurances
                        .padding(.top, 14)
                        .riseIn(appeared, index: 1)

                    ladderHeader
                        .padding(.top, 24)
                        .riseIn(appeared, index: 2)

                    packsList
                        .padding(.top, 10)
                        .riseIn(appeared, index: 3)

                    if iap.lastError != nil {
                        errorCard
                            .padding(.top, 14)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)

            BottomBar { ctaBlock }
        }
        .background(theme.bg)
        .task {
            preselectForNeed()
            deriveUnit()
            withAnimation(RMotion.content) { appeared = true }
            await iap.loadProducts()
            // Also here, not only in `onChange(of: productsLoaded)`: products
            // are often already loaded when the sheet opens (Home fetches them
            // for its "about $x" line), so that change never fires and a
            // missing selected pack would keep its disabled CTA.
            snapToAvailable()
        }
        // An `optional` pack can be selected while the ladder is still loading
        // and then drop out when StoreKit answers without it. Snap back, or the
        // sheet renders no highlighted row while the CTA quotes a different pack.
        .onChange(of: visiblePacks.map(\.id)) { _, ids in
            guard !ids.contains(selected) else { return }
            selected = Self.defaultPackId
            snapToAvailable()
        }
        // 🔴 A PARTIAL StoreKit answer used to be a dead end with no error and
        // no retry.
        //
        // `IAPStore.loadProducts` sets `lastError` only when the fetch THROWS or
        // comes back completely empty. If StoreKit returns five of six and the
        // missing one happens to be the selected pack — the recommended pack,
        // i.e. the one the shortfall preselected — the row rendered
        // "Unavailable", the CTA read "Unavailable" and was disabled, and
        // `errorCard` never appeared because there was no error. The paywall's
        // only visible state was a greyed-out button, on the screen every credit
        // this app has ever earned came through.
        //
        // Moving the selection is the right repair rather than surfacing an
        // error: the other packs are genuinely purchasable, so the sheet should
        // sell one instead of reporting a fault the user cannot act on.
        .onChange(of: productsLoaded) { _, loaded in
            guard loaded else { return }
            snapToAvailable()
        }
        .onDisappear { restoreTask?.cancel() }
    }

    // MARK: - Context

    /// What the user was buying, named. Accent-tinted, never `live`.
    private var contextCard: some View {
        Card(elevation: .lifted) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    contextIcon
                    VStack(alignment: .leading, spacing: 2) {
                        MicroLabel("You're buying")
                        Text(verbatim: contextTitle)
                            .font(RFont.display(16, weight: .semibold))
                            .tracking(-0.3)
                            .foregroundStyle(theme.text)
                            .lineLimit(1)
                        if let sub = contextSubtitle {
                            Text(verbatim: sub)
                                .font(RFont.text(12))
                                .foregroundStyle(theme.text2)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if let cost = contextCost {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("\(cost)")
                                .font(RFont.display(19, weight: .bold))
                                .tracking(-0.4)
                                .foregroundStyle(theme.text)
                                .monospacedDigit()
                            Text("credits")
                                .font(RFont.text(12))
                                .foregroundStyle(theme.text2)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                RowRule(inset: 16)

                HStack(spacing: 10) {
                    Image(systemName: RIcon.coin)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.text2)
                    // Two complete sentences rather than one with a pluralised
                    // noun interpolated in — the Romance languages inflect the
                    // adjective to agree, so "%lld credit%@" cannot be
                    // translated at all.
                    Text("You have \(balance) credits")
                        .font(RFont.text(13, weight: .medium))
                        .foregroundStyle(theme.text2)
                    Spacer(minLength: 0)
                    shortfallPill
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    private var shortfallPill: some View {
        Group {
            if needed == 1 {
                Text("1 more needed")
            } else {
                Text("\(needed) more needed")
            }
        }
        .font(RFont.text(12, weight: .semibold))
        .foregroundStyle(theme.accent2)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(theme.inkSoft, in: .capsule)
    }

    @ViewBuilder
    private var contextIcon: some View {
        switch state.intent {
        case .sms:
            ServiceLogo(service: state.configuringService, size: 38, radius: RRadius.xs)
        case .esim:
            ReceiptIconBox(symbol: "simcard")
        case .email:
            ReceiptIconBox(symbol: "envelope")
        case .line:
            ReceiptIconBox(symbol: RIcon.phone)
        case .call:
            ReceiptIconBox(symbol: RIcon.phone)
        // Unreachable in practice — `creditsShortfall` returns 0 for this
        // intent (it is billed by StoreKit subscription, same as `.line`),
        // so nothing ever opens this sheet while it is set. Covered only
        // because the switch must be exhaustive.
        case .mailSubscription:
            ReceiptIconBox(symbol: "envelope")
        }
    }

    /// Names are catalog values (service names, mail domains, plan names), so
    /// they are rendered verbatim — translating "gmail.com" or "Deliveroo" is
    /// exactly the mistake `EmailDomainOption.displayName` warns about.
    private var contextTitle: String {
        switch state.intent {
        case .sms:   state.configuringService.name
        case .esim:  state.checkoutEsimPlan?.name ?? String(localized: "eSIM data plan")
        case .email: state.emailDomain?.displayName ?? String(localized: "Temporary e-mail")
        case .line:  String(localized: "Second number")
        // The destination is what the user is buying credits FOR, so name it.
        // A generic "International call" would leave them checking whether the
        // pack they are about to buy covers the country they dialled.
        case .call:  state.callDestinationLabel ?? String(localized: "International call")
        // Unreachable — see `contextIcon`.
        case .mailSubscription: String(localized: "Unlimited e-mail addresses")
        }
    }

    private var contextSubtitle: String? {
        switch state.intent {
        case .sms:
            let c = state.configuringCountry
            return "\(c.flag)  \(c.name)"
        case .esim:
            guard let p = state.checkoutEsimPlan else { return nil }
            return "\(p.dataLabel) · \(p.validityLabel)"
        case .email:
            return String(localized: "Temporary inbox")
        case .line:
            return nil
        case .call:
            return String(localized: "International call")
        // Unreachable — see `contextIcon`.
        case .mailSubscription:
            return nil
        }
    }

    private var contextCost: Int? {
        switch state.intent {
        case .sms:   routeCost
        case .esim:  state.checkoutEsimPlan?.retailCredits
        case .email: state.emailDomain?.credits
        case .line:  nil
        // What the CALL costs to start, not the wallet's shortfall — the sheet
        // renders cost and balance separately.
        case .call:  state.callCreditsNeeded
        // Unreachable — see `contextIcon`.
        case .mailSubscription: nil
        }
    }

    /// Live price of the route being configured, respecting the selected tier.
    private var routeCost: Int? {
        let s = state.configuringService, c = state.configuringCountry
        return state.effectiveCheckoutPremium
            ? (state.premiumCost(for: s, country: c) ?? state.cost(for: s, country: c))
            : state.cost(for: s, country: c)
    }

    private var balanceCard: some View {
        Card(elevation: .lifted) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    MicroLabel("Current balance")
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        MonoText("\(balance)", size: 26, weight: .semibold, color: theme.text)
                        Text("credits")
                            .font(RFont.text(13))
                            .foregroundStyle(theme.text2)
                    }
                }
                Spacer()
                StatusPill(text: "Pay per use",
                           tint: theme.accent2, soft: theme.inkSoft, dot: false)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Assurances

    /// The two sentences that make a first purchase safe, at real weight and
    /// ABOVE the ladder. They were 12pt `text2` in a box under the packs.
    private var assurances: some View {
        Card(elevation: .raised) {
            VStack(spacing: 0) {
                // The 8-minute window is the SMS window specifically. Quoting
                // it over an e-mail order (22 minutes) or an eSIM (no window at
                // all) would be a promise about the wrong product — the same
                // class of error as pricing one product line's checkout with
                // another's route.
                if state.intent == .sms {
                    BenefitRow(icon: RIcon.shield,
                               label: "No code in 8 minutes → your credits come straight back.",
                               tint: theme.live)
                } else {
                    BenefitRow(icon: RIcon.shield,
                               label: "If we can't deliver, your credits come straight back.",
                               tint: theme.live)
                }
                RowRule()
                BenefitRow(icon: "infinity",
                           label: "Credits never expire, and they work on every country.")
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Ladder

    private var ladderHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            MicroLabel("Choose a pack")
            basisLine
        }
    }

    /// States what the per-row figure is counted against. Without this the
    /// figure is a number with no provenance — and a number with no provenance
    /// is what the delivery badges spent a year unlearning.
    @ViewBuilder
    private var basisLine: some View {
        switch unit {
        case .unknown:
            EmptyView()
        // ⚠️ NO "totals include the N credits you already have" — the rows show
        // what each PACK adds, not a total, so that sentence would be describing
        // a figure that is no longer on screen. It was true of the old
        // balance-inclusive rows and became false with them.
        case .route(let credits, let service, let country):
            Text("\(service) in \(country) costs \(credits) credits.")
                .font(RFont.text(12))
                .foregroundStyle(theme.text2)
                .fixedSize(horizontal: false, vertical: true)
        case .median(let credits):
            Text("A typical verification costs \(credits) credits. Prices vary by service and country.")
                .font(RFont.text(12))
                .foregroundStyle(theme.text2)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var packsList: some View {
        VStack(spacing: 8) {
            ForEach(visiblePacks) { p in
                PackRow(pack: p,
                        active: selected == p.id,
                        verifications: verifications(from: p),
                        recommended: recommendedId == p.id,
                        unavailable: isMissing(p),
                        displayPrice: iap.displayPrice(p),
                        displayPerCredit: iap.perCredit(p)) {
                    guard !purchasing else { return }
                    RHaptic.select()
                    withAnimation(RMotion.select) { selected = p.id }
                }
            }
        }
        // The list is inert while a transaction is in flight. It used to stay
        // tappable, so the selection could change UNDER the purchase — the
        // sheet would then confirm a pack the user had already moved off.
        .disabled(purchasing)
        .opacity(purchasing ? 0.45 : 1)
        .animation(RMotion.content, value: purchasing)
    }

    /// How many VERIFICATIONS this pack buys on its own. nil when there is no
    /// honest figure to give.
    ///
    /// ⚠️ Not "numbers". Since the rented line shipped, a "number" is a
    /// different product that credits cannot buy at all — it is subscription
    /// only — so counting credits in numbers advertises the one thing they do
    /// not get you.
    ///
    /// ⚠️ It used to be `(balance + p.credits) / u` — the total after buying —
    /// and that made the row unreadable for anyone holding a real balance. At
    /// 99,989 credits the five packs rendered as 16665 / 16666 / 16669 / 16674 /
    /// 16689: the most prominent element on every row was a near-identical
    /// five-digit number, and the difference between the $2.99 and the $5.99
    /// pack read as ONE more number. Correct arithmetic, useless comparison.
    ///
    /// It degraded gracefully at a zero balance, which is why it shipped — the
    /// figure only collapses once the balance dwarfs the pack.
    private func verifications(from p: CreditPack) -> Int? {
        guard let u = unit.credits, u > 0 else { return nil }
        return p.credits / u
    }

    // MARK: - Errors

    /// A retry that actually retries the thing that failed. "Couldn't load" and
    /// "couldn't purchase" need different actions, and the old dead-end red
    /// text offered neither.
    @ViewBuilder
    private var errorCard: some View {
        if let err = iap.lastError {
            let loadFailure = !productsLoaded
            Card(radius: RRadius.md, elevation: .flat, fill: theme.failSoft) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.fail)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 10) {
                        // The message comes from IAPStore/StoreKit already
                        // composed, so it is rendered as-is rather than looked
                        // up as a key it was never registered under.
                        Text(verbatim: err)
                            .font(RFont.text(13, weight: .medium))
                            .foregroundStyle(theme.text)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            RHaptic.select()
                            Task {
                                iap.lastError = nil
                                if loadFailure {
                                    await iap.loadProducts()
                                } else {
                                    await buy()
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: RIcon.refresh)
                                    .font(.system(size: 11, weight: .bold))
                                if loadFailure {
                                    Text("Reload packs")
                                } else {
                                    Text("Try again")
                                }
                            }
                            .font(RFont.text(13, weight: .semibold))
                            .foregroundStyle(theme.text)
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .background(theme.elev, in: .capsule)
                            .contentShape(.capsule)
                        }
                        .pressable(0.96)
                        .disabled(purchasing || iap.isLoadingProducts)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
            }
        }
    }

    // MARK: - Action

    private var ctaBlock: some View {
        VStack(spacing: 12) {
            PrimaryButton(
                label: buttonLabel,
                sub: iap.has(pack) ? iap.displayPrice(pack) : nil,
                disabled: purchasing || !iap.has(pack),
                action: {
                    RHaptic.select()
                    Task { await buy() }
                }
            )
            .overlay(alignment: .trailing) {
                if purchasing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(theme.onInk)
                        .padding(.trailing, 22)
                }
            }

            restoreBlock
        }
    }

    /// Restore lives here as well as in Account, because this is where the
    /// person who was charged and saw no credits is standing. App Review 3.1.1
    /// also expects it wherever purchases are offered.
    private var restoreBlock: some View {
        VStack(spacing: 6) {
            Button {
                RHaptic.select()
                restore()
            } label: {
                HStack(spacing: 6) {
                    if iap.isRestoring {
                        ProgressView().controlSize(.mini).tint(theme.text2)
                    }
                    Text("Already paid? Restore purchases")
                        .font(RFont.text(13, weight: .medium))
                        .foregroundStyle(theme.text2)
                        .underline()
                }
                .contentShape(.rect)
            }
            .pressable(0.97)
            .disabled(iap.isRestoring || purchasing)

            if let note = restoreNote {
                HStack(spacing: 5) {
                    Image(systemName: note.ok ? RIcon.check : RIcon.info)
                        .font(.system(size: 11, weight: .semibold))
                    Text(verbatim: note.text)
                        .font(RFont.text(12, weight: .medium))
                }
                .foregroundStyle(note.ok ? theme.live : theme.text2)
                .transition(.opacity)
            }
        }
    }

    // MARK: - Behaviour

    /// Preselect the smallest pack that clears the current shortfall so the
    /// user isn't left reasoning about pack sizes mid-checkout. `visiblePacks`
    /// is ascending by credits, so the first covering pack is the cheapest one.
    /// Move off a pack StoreKit did not return, onto the nearest one it did.
    ///
    /// "Nearest" is deliberately not "the default pack": with a shortfall, the
    /// smallest pack that still clears it is the only correct answer, and
    /// falling back to MOST POPULAR would either undershoot (leaving the user
    /// short after paying) or overshoot. Without a shortfall it takes the
    /// closest size by credits, so the sheet stays near what the user picked.
    ///
    /// If NOTHING is purchasable it changes nothing — `loadProducts` has
    /// already set `lastError` for the empty case, and `errorCard` with its
    /// "Reload packs" retry is then the honest surface.
    private func snapToAvailable() {
        let available = visiblePacks.filter { iap.has($0) }
        guard !available.isEmpty else { return }
        guard !available.contains(where: { $0.id == selected }) else { return }
        let wanted = visiblePacks.first { $0.id == selected }?.credits ?? 0
        let replacement = available.first { $0.credits >= max(needed, wanted) }
            ?? available.last
        guard let replacement else { return }
        withAnimation(RMotion.select) { selected = replacement.id }
    }

    private func preselectForNeed() {
        guard !didPreselect else { return }
        didPreselect = true
        guard needed > 0 else { return }
        selected = recommendedId ?? selected
    }

    /// Resolve what one VERIFICATION costs.
    ///
    /// Prefers the exact route the user is short for; falls back to the median
    /// of every active priced route. Both are our own live retail prices, not
    /// seed data — and when neither exists (an offline launch keeps
    /// `routes == []`) the answer is nil and the sheet says nothing rather than
    /// guessing. Non-SMS purchases get no figure at all: the unit is the wrong
    /// noun for an eSIM plan or a mailbox, and inventing a per-unit price for
    /// them would be the same overclaim one product line over.
    ///
    /// ⚠️ The `intent == .sms` guard also keeps credits away from the RENTED
    /// LINE, which is subscription-only and never touches the credit wallet.
    /// Quoting any credit figure against it would advertise a way to buy it
    /// that does not exist.
    private func deriveUnit() {
        guard state.intent == .sms else { unit = .unknown; return }

        if needed > 0, let cost = routeCost, cost > 0 {
            unit = .route(credits: cost,
                          service: state.configuringService.name,
                          country: state.configuringCountry.name)
            return
        }

        var priced: [Int] = []
        priced.reserveCapacity(1024)
        for r in state.routes where r.status == "active" {
            if let c = r.retailCredits, c > 0 { priced.append(c) }
        }
        guard !priced.isEmpty else { unit = .unknown; return }
        priced.sort()
        unit = .median(credits: priced[priced.count / 2])
    }

    private func buy() async {
        purchasing = true
        defer { purchasing = false }
        let success = await iap.purchase(pack)
        guard success else {
            RHaptic.warn()
            return
        }
        RHaptic.success()
        // AWAIT the wallet refresh before dismissing. This used to be
        // fire-and-forget, racing the dismissal: the CTA could still read
        // "Buy credits — need N more" against a balance that had already been
        // credited, and because refreshWallet swallows every error a failed
        // refresh left the user paid-but-unchanged with no message at all —
        // which reads as "charged and got nothing".
        await onPurchased()
        dismiss()
    }

    /// Restores, reports, and CLEARS. The Account copy of this used to leave
    /// "Nothing to restore" on screen for the rest of the session.
    private func restore() {
        restoreTask?.cancel()
        restoreTask = Task {
            let n = await iap.restorePurchases()
            await state.refreshWallet(using: WalletAPI(client: api))
            guard !Task.isCancelled else { return }
            // Complete sentences per plural rather than an interpolated "s" —
            // the Romance languages inflect around the noun, so a stitched
            // plural cannot be translated at all.
            let text: String
            if n == 0 {
                text = String(localized: "Nothing left to restore.")
            } else if n == 1 {
                text = String(localized: "1 purchase restored. Your credits are back.")
            } else {
                text = String(localized: "\(n) purchases restored. Your credits are back.")
            }
            withAnimation(RMotion.content) {
                restoreNote = Note(text: text, ok: n > 0)
            }
            if n > 0 { RHaptic.success() }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(RMotion.content) { restoreNote = nil }
        }
    }
}

/// One rung of the ladder, leading with what it BUYS.
private struct PackRow: View {
    @Environment(\.theme) private var theme
    let pack: CreditPack
    let active: Bool
    /// Numbers obtainable in total after this pack. nil = no honest figure.
    let verifications: Int?
    /// This is the smallest pack that clears the current shortfall.
    let recommended: Bool
    /// StoreKit returned every other product but not this one.
    let unavailable: Bool
    let displayPrice: String
    let displayPerCredit: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .strokeBorder(active ? theme.ink : theme.sepStrong,
                                      lineWidth: active ? 6 : 1.5)
                        .frame(width: 22, height: 22)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        headline
                        if let badge = pack.badge {
                            Text(LocalizedStringKey(badge))
                                .font(RFont.text(10, weight: .heavy))
                                .tracking(0.3)
                                .foregroundStyle(theme.accent2)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(theme.inkSoft, in: .capsule)
                        }
                    }
                    secondary
                    if recommended {
                        Text("Covers what you need")
                            .font(RFont.text(11, weight: .semibold))
                            .foregroundStyle(theme.accent2)
                    }
                    if unavailable {
                        Text("Not available right now")
                            .font(RFont.text(11, weight: .semibold))
                            .foregroundStyle(theme.warn)
                    }
                }

                Spacer(minLength: 0)

                Text(verbatim: displayPrice)
                    .font(RFont.display(18, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(theme.text)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: RRadius.md, style: .continuous)
                    .fill(active ? theme.inkSoft.opacity(0.45) : theme.elev)
            }
            .overlay {
                RoundedRectangle(cornerRadius: RRadius.md, style: .continuous)
                    .strokeBorder(active ? theme.ink.opacity(0.55) : theme.sep,
                                  lineWidth: active ? 1.5 : 1)
            }
            .contentShape(.rect(cornerRadius: RRadius.md))
            .opacity(unavailable ? 0.55 : 1)
        }
        .pressable(0.985)
        .disabled(unavailable)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// The useful quantity first. Falls back to the credit count when we have
    /// no honest per-number price — never to an estimate.
    /// What this pack ADDS, always in credits.
    ///
    /// Credits are the thing being bought, they are exact, and — unlike a
    /// derived number count — the figure cannot degrade at any balance. The
    /// "how many verifications is that?" question is still answered, one line
    /// down, where being approximate is honest rather than confusing.
    @ViewBuilder
    private var headline: some View {
        Text("+\(pack.credits) credits")
        .font(RFont.display(19, weight: .bold))
        .tracking(-0.4)
        .foregroundStyle(theme.text)
        .monospacedDigit()
    }

    @ViewBuilder
    private var secondary: some View {
        HStack(spacing: 6) {
            // ⚠️ NEVER print the credit count here — the headline already says
            // it, and this line printing "5 credits" directly under "+5 credits"
            // is the duplication this row has already shipped once, on the app's
            // only revenue screen.
            //
            // `n >= 1` rather than `numbers != nil`: `numbers(from:)` returns 0,
            // not nil, when a pack cannot fund a single number, and `.some(0)`
            // satisfies a nil-check. At the live median of 6 credits that is the
            // $2.99 entry pack, which gets the explicit line below instead.
            if let n = verifications, n >= 1 {
                // ⚠️ "verifications", NEVER "numbers". Since the rented line
                // shipped, "number" is the name of a DIFFERENT product — one
                // that credits cannot buy at all, because it is subscription
                // only. Saying "≈ 25 numbers" on the credit paywall promises
                // exactly the thing credits do not get you. Credits buy
                // temporary numbers that receive verification codes, which is
                // the language the rest of the app already uses.
                Text(n == 1 ? "≈ 1 verification" : "≈ \(n) verifications")
                    .font(RFont.text(12))
                    .foregroundStyle(theme.text2)
                Text(verbatim: "·")
                    .font(RFont.text(12))
                    .foregroundStyle(theme.text3)
            }
            Text(verbatim: displayPerCredit)
                .font(RFont.text(12))
                .foregroundStyle(theme.text2)
        }
        // A pack that cannot buy a single number at typical prices says so.
        // It is the honest answer to "how many verifications is that?", and it
        // is what stops someone buying the entry pack twice.
        if verifications == 0 {
            Text("Not quite enough for one verification on its own")
                .font(RFont.text(11))
                .foregroundStyle(theme.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
