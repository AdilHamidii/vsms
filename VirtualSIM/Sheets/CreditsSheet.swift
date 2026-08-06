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
/// ⚠️ **No pack is ever filtered out of this ladder.** A previous audit claimed
/// `credits.60`/`credits.150` were not APPROVED and proposed hiding them; both
/// read `APPROVED` in App Store Connect and credits.60 has been the top revenue
/// product. A row degrades ONLY when StoreKit actually fails to return that
/// product at runtime, and the marketing badges never move — see `CreditPack`.
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

    @State private var selected: String = "md"
    @State private var purchasing = false
    @State private var didPreselect = false
    @State private var appeared = false
    @State private var restoreNote: Note?
    @State private var restoreTask: Task<Void, Never>?

    /// Credits one number costs, and where that figure came from. Computed
    /// ONCE in `.task` rather than as a computed property: `AppState` is
    /// `@Observable`, so a property that walks ~9,000 routes would be
    /// re-evaluated on every body evaluation of every view that reads it —
    /// the exact trap the eSIM map hit.
    @State private var unit: UnitPrice = .unknown

    private struct Note: Equatable {
        let text: String
        let ok: Bool
    }

    /// Where the "one number costs N credits" figure came from. The basis is
    /// stated to the user, because a bare "≈ 3 numbers" with no stated basis is
    /// the same unearned confidence as a seeded success rate.
    private enum UnitPrice: Equatable {
        /// No catalog, or a product whose price is not per-number (eSIM, e-mail).
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

    private var pack: CreditPack {
        CreditPack.all.first { $0.id == selected } ?? CreditPack.all[1]
    }

    /// The pack the sheet opened on when there is a shortfall — the smallest
    /// one that unblocks them. Labelled on the row; a filled radio button was
    /// the only signal that a recommendation had been made at all.
    private var recommendedId: String? {
        guard needed > 0 else { return nil }
        return CreditPack.all.first { $0.credits >= needed }?.id ?? CreditPack.all.last?.id
    }

    /// True once StoreKit has answered with at least one product. Until then a
    /// missing product means "still loading", not "unavailable" — which is the
    /// distinction that keeps a transient fetch from reading as a dead pack.
    private var productsLoaded: Bool { !iap.products.isEmpty }

    private func isMissing(_ p: CreditPack) -> Bool {
        productsLoaded && iap.products[p.productId] == nil
    }

    private var buttonLabel: String {
        if purchasing { return String(localized: "Processing…") }
        if iap.isLoadingProducts && iap.products[pack.productId] == nil {
            return String(localized: "Loading…")
        }
        if iap.products[pack.productId] == nil { return String(localized: "Unavailable") }
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
        }
    }

    private var contextCost: Int? {
        switch state.intent {
        case .sms:   routeCost
        case .esim:  state.checkoutEsimPlan?.retailCredits
        case .email: state.emailDomain?.credits
        case .line:  nil
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
        case .route(let credits, let service, let country):
            if balance > 0 {
                Text("Totals include the \(balance) credits you already have. \(service) in \(country) costs \(credits) credits.")
                    .font(RFont.text(12))
                    .foregroundStyle(theme.text2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(service) in \(country) costs \(credits) credits.")
                    .font(RFont.text(12))
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .median(let credits):
            if balance > 0 {
                Text("Totals include the \(balance) credits you already have. A typical number costs \(credits) credits. Prices vary by service and country.")
                    .font(RFont.text(12))
                    .foregroundStyle(theme.text2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("A typical number costs \(credits) credits. Prices vary by service and country.")
                    .font(RFont.text(12))
                    .foregroundStyle(theme.text2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var packsList: some View {
        VStack(spacing: 8) {
            ForEach(CreditPack.all) { p in
                PackRow(pack: p,
                        active: selected == p.id,
                        numbers: numbers(after: p),
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

    /// How many numbers the user could get in total after this pack. nil when
    /// there is no honest figure to give.
    private func numbers(after p: CreditPack) -> Int? {
        guard let u = unit.credits, u > 0 else { return nil }
        return (balance + p.credits) / u
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
                sub: iap.products[pack.productId] != nil ? iap.displayPrice(pack) : nil,
                disabled: purchasing || iap.products[pack.productId] == nil,
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
    /// user isn't left reasoning about pack sizes mid-checkout. `CreditPack.all`
    /// is ascending by credits, so the first covering pack is the cheapest one.
    private func preselectForNeed() {
        guard !didPreselect else { return }
        didPreselect = true
        guard needed > 0 else { return }
        selected = recommendedId ?? selected
    }

    /// Resolve what one number costs.
    ///
    /// Prefers the exact route the user is short for; falls back to the median
    /// of every active priced route. Both are our own live retail prices, not
    /// seed data — and when neither exists (an offline launch keeps
    /// `routes == []`) the answer is nil and the sheet says nothing rather than
    /// guessing. Non-SMS purchases get no figure at all: "numbers" is the wrong
    /// noun for an eSIM plan or a mailbox, and inventing a per-unit price for
    /// them would be the same overclaim one product line over.
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
    let numbers: Int?
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
    @ViewBuilder
    private var headline: some View {
        Group {
            if let n = numbers, n >= 1 {
                if n == 1 {
                    Text("1 number")
                } else {
                    Text("\(n) numbers")
                }
            } else {
                Text("\(pack.credits) credits")
            }
        }
        .font(RFont.display(19, weight: .bold))
        .tracking(-0.4)
        .foregroundStyle(theme.text)
        .monospacedDigit()
    }

    @ViewBuilder
    private var secondary: some View {
        HStack(spacing: 6) {
            if numbers != nil {
                Text("\(pack.credits) credits")
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
        if numbers == 0 {
            Text("Not quite enough for one number on its own")
                .font(RFont.text(11))
                .foregroundStyle(theme.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
