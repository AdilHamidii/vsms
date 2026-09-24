import StoreKit
import SwiftUI

/// The last screen before paying, and the FIRST one that mentions money.
///
/// ── Why it is shaped like this ────────────────────────────────────────────
///
/// Everything before it asks the user to choose — a city, then their actual
/// digits. By the time they land here the number on screen is already theirs in
/// every sense except the payment, which is the moment a price is worth
/// reading. Leading with "$5.99/month" asks someone to value a product they
/// have not seen.
///
/// The previous version failed on exactly one measurable thing: `theme.text`
/// appeared **twice** in the whole file. Everything below the number — the
/// benefits, the renewal terms, the emergency warning, the legal links —
/// rendered in `text2`/`text3` at 12–13pt, so the screen was one number sitting
/// on top of a grey column with no hierarchy at all. It also had no headline,
/// so the screen had no name; the city the user picked three taps earlier was
/// never mentioned; and the price appeared twice within 200pt.
///
/// It carries the App Store **3.1.2(a)** disclosures — price, billing period,
/// renewal terms and links to Terms and Privacy, all in-app and all before the
/// purchase. That is the most common subscription rejection.
struct LineCheckoutScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    @Environment(SubscriptionStore.self) private var subs
    @Environment(IAPStore.self) private var iap
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var appeared = false
    @State private var now = Date()
    @State private var isReserving = false
    @State private var isRestoring = false
    /// The "Good to know" disclosure. Collapsed on open — see `goodToKnow`.
    @State private var limitsShown = false
    /// The selected plan's border springs between rows (spec §3a).
    @Namespace private var planNS

    /// Scroll anchor for the plan picker. Only the screenshot harness uses it,
    /// but it is a plain view id rather than DEBUG-only state so the scroll
    /// target cannot drift out of sync with the section it names.
    private static let planAnchor = "plan-picker"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    numberCard.riseIn(appeared, index: 0)
                    // As prominent as the price: the term most likely to be
                    // discovered after paying rather than before.
                    capabilityNote.padding(.top, RSpace.md).riseIn(appeared, index: 1)
                    whatYouGet.padding(.top, RSpace.xl).riseIn(appeared, index: 2)
                    // Choice first, then the sentence that restates it with its
                    // renewal terms (3.1.2(a)). Putting the plans after the
                    // sentence would mean the disclosure is read before the
                    // thing it describes has been chosen.
                    plans.padding(.top, RSpace.xl).riseIn(appeared, index: 3)
                        .id(Self.planAnchor)
                    // Gated like `plans`: with no plan and no price on screen,
                    // renewal terms would describe nothing. The 3.1.2(a)
                    // sentence therefore renders whenever a plan does.
                    if subs.hasMonthly || subs.isLoadingProduct {
                        priceSentence.padding(.top, RSpace.md).riseIn(appeared, index: 3)
                        rentalLine.padding(.top, RSpace.sm).riseIn(appeared, index: 3)
                    }
                    // What this number does NOT do, collapsed. It stays ON the
                    // purchase screen (3.1.2(a): the limitations are terms the
                    // buyer accepts before paying), one tap away instead of in
                    // the way of the plan choice.
                    goodToKnow.padding(.top, RSpace.lg).riseIn(appeared, index: 4)
                    // The safety disclosure sits ABOVE the action, not between
                    // the price and the button.
                    emergency.padding(.top, RSpace.lg).riseIn(appeared, index: 4)
                    links.padding(.top, RSpace.lg).riseIn(appeared, index: 5)
                }
                .padding(.horizontal, RSpace.gutter)
                .padding(.top, RSpace.lg)
                .padding(.bottom, RSpace.lg)
            }
            .scrollIndicators(.hidden)
            // Content scrolls UNDER a material header instead of being cut flat
            // by a bare HStack (audit §2.2 item 5).
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                BottomBar(scrimHeight: 24, horizontalPadding: RSpace.gutter) { cta }
            }
            // A screenshot frame of a plan has to SHOW the plan choice and the
            // 3.1.2(a) renewal sentence, which sit below the fold on a fresh
            // open. Scrolled deterministically rather than by a scripted swipe,
            // so a frame comes out identical every run. The US frame
            // (`linePaywallUS`) shows the TOP, so it is not scrolled.
            // `screen` is a stored nil in Release, so this folds away.
            .task {
                guard ScreenshotMode.screen == .linePaywall
                        || ScreenshotMode.screen == .linePaywallYearly else { return }
                try? await Task.sleep(for: .milliseconds(400))
                proxy.scrollTo(Self.planAnchor, anchor: .top)
            }
        }
        .background(theme.bg.ignoresSafeArea())
        .onAppear { CheckoutVisit.begin() }
        .onDisappear {
            // Only a REAL exit counts. `line_checkout_view` usually arrives in
            // PAIRS per visit, which points at this cover's content being
            // built twice (inferred, not traced) — so a disappear while the
            // flow is still `.lineCheckout` is not a departure and must not
            // read as one.
            guard state.flow != .lineCheckout else { return }
            logExit(how: CheckoutVisit.exitVia ?? "back")
            CheckoutVisit.end()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                logExit(how: "background")
            case .active where state.flow == .lineCheckout:
                // Coming back is a new visit; the backgrounding already
                // closed the last one. A no-op while a visit is still open.
                CheckoutVisit.begin()
            default:
                break
            }
        }
        .task {
            // The middle of the line funnel, and until 2.8 the whole product
            // had exactly one event (`line_store_view`) — so "162 store views,
            // 0 subscriptions" could not be split into "never reached checkout"
            // and "left at Apple's sheet". The plan is carried because the
            // paywall opens on monthly and the choice is the thing we are
            // asking about.
            // Loads the localized price. Cheap and idempotent, and without it
            // the CTA falls back to a label with no price at all. Awaited
            // BEFORE the view event so `intro` below is the answer StoreKit
            // gave, not the pre-load nil.
            await subs.loadProduct()
            Analytics.shared.track("line_checkout_view", [
                "plan": .string(subs.selectedPlan.rawValue),
                // Whether the $3.99 first month was on this screen — the
                // denominator for reading the 2026-09-10 intro offer.
                "intro": .bool(subs.monthlyIntroPriceDisplay != nil)])
            withAnimation(RMotion.content) { appeared = true }
        }
        // ⚠️ Ticks ONLY while there is a countdown to tick.
        //
        // `now` drives exactly one thing: the "Held for you · 4:12" pill. It
        // used to be reassigned every second unconditionally, which invalidates
        // this whole body — number card, price block, legal text, the lot — at
        // 1 Hz on a screen that usually shows no hold at all and has
        // nothing to animate. `reserveNumber` is unproven against the live API
        // and a hold is explicitly optional, so the common case is no
        // countdown at all and the timer was pure waste.
        //
        // Keyed on `heldUntil` so it starts when a hold arrives and stops the
        // moment it lapses, rather than running for the life of the screen.
        .task(id: state.lineReservation?.heldUntil) {
            guard let until = state.lineReservation?.heldUntil else { return }
            while !Task.isCancelled, until > Date() {
                now = Date()
                try? await Task.sleep(for: .seconds(1))
            }
            now = Date()
        }
    }

    // MARK: - Chrome

    /// ✕, title, Restore on a `.bar` material. Restore lives here AND in the
    /// link row, not only in Account: a user who was charged and has no number
    /// is standing on this screen, not three taps deep in settings — and App
    /// Review 3.1.1 expects the control to be reachable wherever a purchase is
    /// offered.
    private var header: some View {
        ZStack {
            Text("Your own number")
                .font(RFont.text(17, weight: .semibold))
                .foregroundStyle(theme.text)
                .padding(.horizontal, RSpace.gutter)
            HStack {
                Button { state.flow = nil } label: {
                    Image(systemName: RIcon.close)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.text2)
                        .frame(width: 36, height: 36)
                        .background(theme.chipBg, in: .circle)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(PressScaleStyle(scale: 0.92))
                .accessibilityLabel(Text("Close"))
                Spacer()
                restoreButton
                    .font(RFont.text(15, weight: .medium))
                    .foregroundStyle(theme.text)
            }
            // The ✕ circle is 36pt inside a 44pt hit frame, so its visual
            // edge sits 4pt in from the frame: pull the frame out by 4 and
            // the circle lines up with the 16pt content column.
            .padding(.leading, RSpace.gutter - 4)
            .padding(.trailing, RSpace.gutter)
        }
        .frame(height: 52)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.sep).frame(height: 0.5)
        }
    }

    private var restoreButton: some View {
        Button(action: restore) {
            // Both instances (header, link row) get a 44pt tap target.
            Group {
                if isRestoring { Text("Restoring…") } else { Text("Restore") }
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isRestoring)
    }

    /// Moved verbatim from the old header's button (every comment kept).
    private func restore() {
        Task {
            isRestoring = true
            defer { isRestoring = false }
            // Cleared first so what we render afterwards describes THIS
            // restore and not some earlier failed purchase.
            subs.lastError = nil
            _ = await iap.restorePurchases()
            await state.loadLine(using: LineAPI(client: api))
            // ⚠️ `isLive`, not `!= nil`. `AppState.line` falls back to
            // ANY line when there is no live one, so a `failed` row
            // from an earlier botched activation made this report
            // success and dismiss the screen — to the one user who can
            // never be told that: someone already charged who still has
            // no number.
            if state.line?.status.isLive == true {
                RHaptic.success()
                CheckoutVisit.exitVia = "restore"
                state.flow = nil
            } else if let failure = subs.lastFailure {
                // A restore that recovers nothing must SAY so. Silence
                // reads as "it worked" — the worst possible answer for
                // the only person who ever taps this button: someone
                // who has been charged and has no number.
                //
                // Re-raised WITH its code. Passing `lastError` here
                // dropped it, and a codeless banner is blocking —
                // which on this flow means a red triangle with no
                // action and no auto-dismiss.
                RHaptic.warn()
                state.showError(failure)
            }
        }
    }

    // MARK: - What this screen is

    private var cityLabel: String? {
        guard let id = state.lineCity else { return nil }
        return state.lineCities.first { $0.id == id }?.label
    }

    // MARK: - What this number can do
    //
    // Three sources, in decreasing order of authority, and the ordering is the
    // point. The RESERVATION describes the exact number about to be bought;
    // the OFFER's `features[]` is Telnyx's own per-number list; the COUNTRY is
    // a generalisation. Only the first two are about the digits on screen.

    /// The country row backing this purchase, when we have one.
    private var country: LineCountry? {
        guard let iso = state.lineCountry else { return nil }
        if let c = state.lineSearchCountry, c.countryCode == iso { return c }
        return state.lineCountries.first { $0.countryCode == iso }
    }

    /// nil means "we do not know", and that is NOT the same as false. An
    /// unknown capability renders no claim at all — the same rule the delivery
    /// badges follow, one product line over.
    private var numberSendsTexts: Bool? {
        if let q = state.lineReservation, q.phoneNumber == state.lineOffer?.phoneNumber,
           let sms = quoteSupportsSms { return sms }
        if let fromOffer = state.lineOffer?.supports("sms") { return fromOffer }
        return country?.supportsSms
    }

    /// Held separately because `LineReservation` is the trimmed shape stored in
    /// state; the capability booleans live on the QUOTE, which the buy path
    /// keeps only long enough to start the purchase.
    @State private var quoteSupportsSms: Bool?

    /// Rendered ONLY on a positive "this number cannot text".
    ///
    /// An SMS-capable number keeps the existing copy — the benefit list
    /// already says what it receives — and an UNKNOWN capability says nothing,
    /// because a "calls only" warning over a number that texts perfectly well
    /// is a lie that costs the sale.
    /// Whether the uncollapsed US/PR sending warning is on screen. One
    /// definition, read by the view and by `line_checkout_exit`, so the event
    /// can never describe a different screen from the one rendered.
    private var sendingWarningShown: Bool {
        guard numberSendsTexts != false, let iso = state.lineCountry else { return false }
        // Uppercased like the swap sheet's check, so a lowercase ISO from any
        // source cannot silently drop the warning.
        return LineStoreScreen.unreliableSendingCountries.contains(iso.uppercased())
    }

    @ViewBuilder
    private var capabilityNote: some View {
        if sendingWarningShown {
            // 🔴 UNCOLLAPSED, and that is the point (2026-09-17). "Some
            // networks block texts sent from virtual numbers" already lived in
            // `goodToKnow`, which opens CLOSED — so the one limit this product
            // actually hits was a tap away from a buyer who never taps. It is
            // measured, not a caveat: 16 of 24 US sends failed with Telnyx
            // `40010` (sender not 10DLC-registered) over the 30 days to
            // 2026-09-17, against every Canadian send to a Canadian number
            // delivering, and two
            // subscribers turned auto-renew off minutes after their first
            // failed text. A limit discovered AFTER paying is a refund and an
            // Apple CONSUMPTION_REQUEST; this is the 3.1.2(a) surface, so it
            // belongs on it in full view.
            //
            // It no longer names Canada: CA→US fails the same way (0 of 8,
            // CLAUDE.md 2026-09-24), so a Canadian number is not a remedy.
            Card(radius: RRadius.group, elevation: .flat,
                 fill: theme.warnSoft, border: theme.warn.opacity(0.28)) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.warn)
                        .padding(.top, 1)
                    Text("Texts you send from an American number often don't arrive — most US networks block them. Receiving codes and calling work normally.")
                        .font(RFont.text(13, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        if numberSendsTexts == false {
            // Through `Card` with a semantic fill + hairline, identical to the
            // emergency block below: one caution surface on this screen rather
            // than hand-rolled backgrounds free to drift apart. The store
            // states the same limitation as a ✗ row in its `LineLedger`.
            Card(radius: RRadius.group, elevation: .flat,
                 fill: theme.warnSoft, border: theme.warn.opacity(0.28)) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.warn)
                        .padding(.top, 1)
                    Text("Calls only. This number can't send or receive texts.")
                        .font(RFont.text(13, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    /// The area code, read off the number itself rather than tracked in state —
    /// the server decides which code a city resolves to, and the digits on
    /// screen are the only authority on what it chose.
    private var areaCode: String? {
        let digits = (state.lineOffer?.phoneNumber ?? "").filter(\.isNumber)
        guard digits.count >= 11 else { return nil }
        let start = digits.index(digits.startIndex, offsetBy: 1)
        return String(digits[start..<digits.index(start, offsetBy: 3)])
    }

    // MARK: - The number

    /// The one object this screen is about. Flat, like every surface in the
    /// overhaul (no shadow, spec §3 rule 1): it separates from the canvas by
    /// FILL alone — `theme.elev` (white in light mode) on the warm `theme.bg`
    /// paper, and a raised grey on near-black in dark mode — and by being the
    /// largest type on the screen, not by elevation.
    private var numberCard: some View {
        VStack(spacing: RSpace.sm) {
            HStack(spacing: 6) {
                if let iso = state.lineOffer?.countryCode ?? state.lineCountry {
                    CodeFlag(code: iso, size: 18)
                }
                Text(placeLine)
                    .font(RFont.text(13, weight: .semibold))
                    .foregroundStyle(theme.text2)
            }
            Text(verbatim: PhoneFormat.national(state.lineOffer?.phoneNumber ?? ""))
                .numberStyle(size: 30, color: theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            holdLine
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, RSpace.xl)
        .padding(.horizontal, RSpace.lg)
        .background(theme.elev, in: .rect(cornerRadius: RRadius.card, style: .continuous))
    }

    private var placeLine: String {
        let city = cityLabel ?? country?.displayName ?? String(localized: "Canada")
        if let areaCode { return "\(city) · \(areaCode)" }
        return city
    }

    /// Only where the server actually holds the number (spec §4.2).
    ///
    /// `reserve-line-number` runs inside `buy()`, after Subscribe, and a fresh
    /// search clears `lineReservation` — so on a normal open there is no hold
    /// and nothing renders. The old "Available now" pill claimed a presence
    /// the server was not backing.
    @ViewBuilder
    private var holdLine: some View {
        if let until = state.lineReservation?.heldUntil, until > now {
            StatusPill(text: "Held for you · \(PhoneFormat.duration(Int(until.timeIntervalSince(now))))")
                .contentTransition(.numericText())
        }
    }

    // MARK: - What you get

    /// Five rows, down from nine (spec §4.2). The minutes row and the 50+
    /// countries row MUST stay: the store's "✓ Calls" carries no figures, and
    /// is honest only because these two state them before the purchase.
    /// The ✗ row is the store's, for a number that texts and is NOT US/PR
    /// (US/PR get the uncollapsed note above instead).
    ///
    /// ⚠️ **Only sell what ships**, and **emergency calling is NOT included**
    /// — it is disclosed separately below. Nothing in this list may imply the
    /// number can reach 911. Figures come from `LineProduct`, never literals.
    private var whatYouGet: some View {
        VStack(alignment: .leading, spacing: RSpace.sm) {
            MicroLabel("What you get")
            LineLedger {
                if numberSendsTexts != false {
                    LineLedgerRow(kind: .yes,
                                  text: Text("Receive texts and verification codes"),
                                  detail: Text("From US and Canadian numbers and services."))
                }
                // OUTGOING only, and that wording stays exact: inbound bills
                // nothing and is unmetered.
                LineLedgerRow(kind: .yes,
                              figure: "\(LineProduct.voiceAllowanceMinutes)",
                              text: Text("minutes of outgoing calls a month"))
                LineLedgerRow(kind: .yes,
                              text: Text("Call 50+ countries, priced per minute before you dial"))
                // NO client default for the price (`line_swap_credits` moves
                // without a release). "As many times as you want" is true only
                // while `line_swap_cooldown_days` is 0.
                if let cost = state.appStatus.lineSwapCredits {
                    LineLedgerRow(kind: .yes,
                                  text: Text("Switch to a new number for only \(cost) credits — any time, as many times as you want"))
                } else {
                    LineLedgerRow(kind: .yes,
                                  text: Text("Switch to a new number any time, as many times as you want"))
                }
                if numberSendsTexts != false, !sendingWarningShown {
                    LineLedgerRow(kind: .no,
                                  text: Text("Texts you send to US numbers usually don't arrive."))
                }
            }
        }
    }

    // MARK: - What it does NOT do

    /// The limitations, collapsed by default — four rows since 2026-09-08.
    ///
    /// ⚠️ It must stay ON this screen. This is the 3.1.2(a) disclosure screen —
    /// the one immediately before the purchase — and owner decision 2026-08-18
    /// is to state the limitations plainly, "for now": a limitation named
    /// before the buy is a term the user accepted, the same limitation
    /// discovered after is a refund and, on this product, an Apple
    /// CONSUMPTION_REQUEST. What changed is its POSITION: it used to be the
    /// tail of `included`, so the last thing read before the plan picker was a
    /// list of things the product cannot do.
    ///
    /// Hand-rolled rather than `DisclosureGroup`, which brings its own label
    /// typography and chevron and would be the only one of its kind in the app.
    @ViewBuilder
    private var goodToKnow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                RHaptic.select()
                withAnimation(RMotion.panel) { limitsShown.toggle() }
            } label: {
                HStack(spacing: 8) {
                    // Sentence case beside its chevron (audit §2.2 item 9),
                    // not a full-width MicroLabel that pushed the chevron
                    // to the far edge.
                    Text("Good to know")
                        .font(RFont.text(13, weight: .semibold))
                        .foregroundStyle(theme.text2)
                    Image(systemName: RIcon.chevDn)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.text3)
                        .rotationEffect(.degrees(limitsShown ? 0 : -90))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44, alignment: .leading)
            .accessibilityAddTraits(.isButton)

            if limitsShown {
                VStack(spacing: 0) {
                    // Muted tint + "Not yet" hint keeps each one a ledger
                    // line rather than an alarm.
                    // 🔴 REPLACED, NOT DELETED (2026-09-08). "Sending
                    // texts — Not yet" came off because sending is back;
                    // what took its place is the honest residue of that
                    // change. A message we accept can still be refused by
                    // the recipient's carrier minutes later — no number we
                    // own carries a 10DLC campaign — and this is the
                    // 3.1.2(a) disclosure screen, so a buyer who meets
                    // that after paying is a refund and a
                    // CONSUMPTION_REQUEST. `hint` says "Sometimes" rather
                    // than "Not yet": it is a real risk, not an absent
                    // feature.
                    BenefitRow(icon: "paperplane",
                               label: "Some networks block texts sent from virtual numbers",
                               hint: "Sometimes",
                               tint: theme.text3)
                        .opacity(0.72)
                    RowRule()
                    // 🔴 MOVED HERE FROM THE STORE PITCH (2026-09-09), not
                    // deleted. The store now sells the swap as a feature
                    // ("any time, as many times as you want") instead of a
                    // remedy, which removed the only place the app said
                    // that a service can refuse a virtual number at all.
                    // That is a real and common outcome — it is why the
                    // swap exists — and a buyer who meets it after paying
                    // is a refund and a CONSUMPTION_REQUEST. This is the
                    // 3.1.2(a) surface, so it belongs here if it is
                    // anywhere. `hint` is "Sometimes": a real risk, not an
                    // absent feature.
                    BenefitRow(icon: "questionmark.circle",
                               label: "Some services refuse virtual numbers — switch to a new one and try again",
                               hint: "Sometimes",
                               tint: theme.text3)
                        .opacity(0.72)
                    RowRule()
                    BenefitRow(icon: RIcon.message,
                               label: "Sending texts outside the US and Canada",
                               hint: "Not yet",
                               tint: theme.text3)
                        .opacity(0.72)
                    RowRule()
                    BenefitRow(icon: RIcon.globe,
                               label: "Receiving texts from outside the US and Canada",
                               hint: "Not yet",
                               tint: theme.text3)
                        .opacity(0.72)
                }
                .padding(.vertical, 4)
                .background(theme.elev, in: .rect(cornerRadius: RRadius.group, style: .continuous))
                .padding(.top, 6)
                .transition(.opacity)
            }
        }
    }

    // MARK: - Price
    //
    // App Store 3.1.2(a): price, period, renewal terms and the two legal links
    // must all appear in-app before the purchase. Every figure below comes
    // from StoreKit through `SubscriptionStore`; none is a literal.

    /// D4 (spec §4.2): "{regular}/month" at plan size, the intro beneath and
    /// smaller, behind the eligibility gate. Yearly is a plain second row.
    /// Only the selected plan carries a border. A single monthly row when the
    /// yearly is not offered in this storefront — never a choice one side of
    /// which cannot be bought.
    ///
    /// The REGULAR price leads because 3.1.2(a) wants the renewal figure
    /// visible, and the intro is the exception, not the price. The intro line
    /// vanishes for an Apple ID that is not eligible:
    /// `monthlyIntroPriceDisplay` is nil unless `isEligibleForIntroOffer`
    /// answered true — never read `introductoryOffer` directly.
    @ViewBuilder
    private var plans: some View {
        if subs.hasMonthly || subs.isLoadingProduct {
            VStack(spacing: RSpace.sm) {
                planRow(.monthly)
                if subs.hasYearly { planRow(.yearly) }
            }
        }
    }

    private func planRow(_ plan: LinePlan) -> some View {
        let active = subs.selectedPlan == plan
        return Button { select(plan) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Group {
                        if plan == .monthly { Text("Monthly") } else { Text("Yearly") }
                    }
                    .font(RFont.text(15, weight: .semibold))
                    .foregroundStyle(theme.text)
                    // Computed from the two live prices, so it cannot promise
                    // a saving the store will not honour.
                    if plan == .yearly, let pct = subs.yearlySavingsPercent {
                        // A text tag, never a second bordered thing (emphasis rule).
                        Text("SAVE \(pct)%")
                            .font(RFont.text(11, weight: .heavy))
                            .tracking(0.3)
                            .foregroundStyle(theme.text2)
                    }
                }
                planPrice(plan)
                planNote(plan)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(RSpace.lg)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: RRadius.group, style: .continuous)
                        .fill(theme.elev)
                    if active {
                        // One border that springs between rows (spec §3a).
                        RoundedRectangle(cornerRadius: RRadius.group, style: .continuous)
                            .strokeBorder(theme.ink, lineWidth: 1)
                            .matchedGeometryEffect(id: "planBorder", in: planNS)
                    }
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressScaleStyle(scale: 0.99))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }

    /// The height is reserved while StoreKit loads ("—", redacted), so the
    /// renewal sentence below never slides up and back on first paint.
    @ViewBuilder
    private func planPrice(_ plan: LinePlan) -> some View {
        let price = plan == .monthly ? subs.monthlyPriceDisplay : subs.yearlyPriceDisplay
        if let price {
            Group {
                if plan == .monthly { Text("\(price)/month") } else { Text("\(price)/year") }
            }
            .numberStyle(size: 20, color: theme.text)
        } else {
            Text(verbatim: "—")
                .numberStyle(size: 20, color: theme.text3)
                .redacted(reason: subs.isLoadingProduct ? .placeholder : [])
        }
    }

    @ViewBuilder
    private func planNote(_ plan: LinePlan) -> some View {
        if plan == .monthly, let intro = subs.monthlyIntroPriceDisplay {
            Text("\(intro) your first month · new subscribers")
                .font(RFont.text(13))
                .foregroundStyle(theme.text2)
                .monospacedDigit()
        } else if plan == .yearly, let trial = subs.trialLabel {
            // Eligibility-gated like the intro: nil for an Apple ID that has
            // used its one introductory offer in this group.
            Text("\(trial) free, then billed yearly")
                .font(RFont.text(13))
                .foregroundStyle(theme.text2)
        }
    }

    /// Moved from the old `planRow` button action: only a REAL change counts.
    /// Re-tapping the selected row is not a decision, and counting it would
    /// inflate the one number this event exists to answer: how many buyers
    /// move off monthly.
    private func select(_ plan: LinePlan) {
        RHaptic.select()
        if subs.selectedPlan != plan {
            Analytics.shared.track("line_plan_selected", ["plan": .string(plan.rawValue)])
        }
        withAnimation(RMotion.unlessReduced(RMotion.standard, reduceMotion)) {
            subs.selectedPlan = plan
        }
    }

    /// 3.1.2(a): what happens after the intro, and the renewal terms, for the
    /// SELECTED plan. The figure comes from StoreKit only. When an intro or
    /// trial applies, 3.1.2(a) also requires saying what happens when it ends
    /// — the most common reason a subscription paywall is rejected.
    ///
    /// ONE `Text` whose key changes, not a branch per sentence: a branch swap
    /// is a view transition (a plain fade), and only a change inside the
    /// same `Text` gets the `numericText` roll (spec §3a).
    private var priceSentence: some View {
        Text(priceSentenceKey)
            .font(RFont.text(13))
            .foregroundStyle(theme.text2)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
            .contentTransition(.numericText())
            .animation(RMotion.unlessReduced(RMotion.standard, reduceMotion), value: subs.selectedPlan)
    }

    /// The four sentences, unchanged as catalog keys (`LocalizedStringKey`
    /// by declared type, so each literal is looked up, never shown raw).
    private var priceSentenceKey: LocalizedStringKey {
        if subs.selectedPlan == .yearly {
            if let trial = subs.trialLabel, let price = subs.yearlyPriceDisplay {
                return "\(trial) free, then \(price). Renews every year until you cancel. Cancel any time in Settings."
            }
            return "Renews every year until you cancel. Cancel any time in Settings."
        }
        if subs.selectedIntroPriceDisplay != nil, let price = subs.monthlyPriceDisplay {
            return "Then \(price) every month until you cancel. Cancel any time in Settings."
        }
        return "Renews every month until you cancel. Cancel any time in Settings."
    }

    /// True of the lapse machine: `reclaim_lapsed_lines` never releases a line
    /// before `current_period_end` (CLAUDE.md, "The lapse machine").
    private var rentalLine: some View {
        Text("Only need it for a month? Turn off renewal after buying — it stays yours until the end of the month you paid for.")
            .font(RFont.text(13))
            .foregroundStyle(theme.text2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Disclosed here as well as in the store and the manage screen —
    /// unmissably, never behind a Terms link. A reviewer will look for it, and
    /// so would a regulator.
    ///
    /// It gets a real container so it cannot be confused with the roadmap note
    /// on the store screen, which was rendered with identical weight and
    /// spacing: a safety warning and a "coming soon" should not look alike.
    private var emergency: some View {
        Card(radius: RRadius.group, elevation: .flat,
             fill: theme.warnSoft, border: theme.warn.opacity(0.28)) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.warn)
                    .padding(.top, 1)
                Text("This number can't call 911 or any emergency service. Always use your phone's own number for emergencies.")
                    .font(RFont.text(12, weight: .medium))
                    .foregroundStyle(theme.text)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    /// Guideline 3.1.2(c): the purchase flow must carry functional links to the
    /// Terms of Use (EULA) and the privacy policy. The 2.0(37) rejection taught
    /// two things: the labels must NAME the documents ("Terms" reads as our own
    /// terms, not the EULA the metadata declares), and links tinted like muted
    /// body text are links a reviewer does not see — so these are underlined
    /// and full-contrast. One row when it fits; stacked in long locales (the
    /// German labels don't fit side by side on a 375pt screen).
    private var links: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: RSpace.sm) {
                eulaLink
                Text(verbatim: "·").foregroundStyle(theme.text3)
                privacyLink
                Text(verbatim: "·").foregroundStyle(theme.text3)
                restoreButton.underline()
            }
            VStack(alignment: .leading, spacing: RSpace.sm) {
                eulaLink
                privacyLink
                restoreButton.underline()
            }
        }
        .font(RFont.text(13, weight: .medium))
        .foregroundStyle(theme.text)
        .tint(theme.text)
    }

    private var eulaLink: some View {
        Link(destination: LegalLinks.eula) { Text("Terms of Use (EULA)").underline() }
    }

    private var privacyLink: some View {
        Link(destination: LegalLinks.privacy) { Text("Privacy Policy").underline() }
    }

    // MARK: - Action

    private var cta: some View {
        VStack(spacing: RSpace.sm) {
            if unavailable {
                Text("The App Store isn't offering this subscription right now. Please try again in a moment.")
                    .font(RFont.text(12))
                    .foregroundStyle(theme.text2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // No typewriter price (spec §4.2): the price is stated in the plan
            // rows and the sentence above, and again on Apple's sheet. (The
            // old `sub` line was also where a Yearly pick once read "/mo" — a
            // third copy of the price is a third place for the period to lie.)
            PrimaryButton(label: ctaLabel,
                          disabled: busy || state.lineOffer == nil || !subs.hasMonthly,
                          action: buy)
            Text("Cancel any time in Settings")
                .font(RFont.text(12))
                .foregroundStyle(theme.text3)
        }
    }

    private var busy: Bool { isReserving || subs.isPurchasing }

    /// Distinguishes "still loading" from "the store has no such product" —
    /// collapsing the two would tell a user on a slow connection that the
    /// product does not exist.
    private var unavailable: Bool { !subs.hasMonthly && !subs.isLoadingProduct }

    /// Names the step in progress rather than showing a spinner on a button
    /// whose label still says "Get this number". Reserving involves a live
    /// Telnyx round trip, so the pause is real and unexplained silence there
    /// reads as a dead tap. It carries no price: the plan rows and the renewal
    /// sentence state it (spec §4.2).
    private var ctaLabel: String {
        if isReserving { return String(localized: "Checking availability…") }
        if subs.isPurchasing { return String(localized: "Confirming…") }
        if subs.isLoadingProduct { return String(localized: "Loading…") }
        if unavailable { return String(localized: "Temporarily unavailable") }
        return String(localized: "Subscribe")
    }

    /// Reserve → pay → provision, in that order.
    ///
    /// The reservation is what makes the whole flow safe: it is the last moment
    /// we can refuse. Once StoreKit takes the money the only remedy is an Apple
    /// refund, which is the one money path this app cannot drive — so the float
    /// check, the one-line-per-user check and the paused check all live in
    /// `reserve-line-number`, before the paywall rather than after it.
    private func buy() {
        guard let offer = state.lineOffer, let city = state.lineCity else { return }
        // Tapping Subscribe ends the "left without trying" question for this
        // visit, whatever happens next — `line_purchase_result` owns the rest.
        CheckoutVisit.purchaseStarted = true
        Task {
            isReserving = true
            let quote: LineReservationQuote?
            do {
                quote = try await LineAPI(client: api)
                    .reserve(city: city, phoneNumber: offer.phoneNumber,
                             country: state.lineCountry)
            } catch let err as APIError {
                isReserving = false
                RHaptic.warn()
                state.showError(err)
                // The number went between the picker and the tap. Re-search so
                // the screen never offers digits we can no longer deliver, and
                // make the user tap again — provisioning a DIFFERENT number
                // than the one on screen is the failure this avoids.
                await state.loadLineNumbers(using: LineAPI(client: api), city: city)
                state.flow = nil
                return
            } catch {
                isReserving = false
                RHaptic.warn()
                state.lastError = String(localized: "Couldn't reach the server. Check your connection and try again.")
                return
            }
            isReserving = false
            guard let quote else { return }

            state.lineReservation = quote.reservation
            // The quote is the most authoritative thing we will ever hold
            // about this specific number, and only its capability half
            // survives into `LineReservation`. Kept so the note above cannot
            // be contradicted by the number actually being bought.
            quoteSupportsSms = quote.supportsSms
            let ok = await subs.purchase(
                phoneNumber: quote.phoneNumber, city: city,
                monthlyCents: quote.monthlyCents,
                country: quote.country ?? state.lineCountry)

            if ok {
                RHaptic.success()
                state.flow = .lineProvisioning
            } else if let failure = subs.lastFailure {
                // WITH its code — see the Restore branch above. `line_exists`,
                // `line_limit_reached` and `number_taken` are all classified
                // informational, and arriving here as a bare sentence made
                // every one of them a dead-end blocking banner.
                state.showError(failure)
            }
        }
    }

    // MARK: - Exit measurement

    /// `line_checkout_exit` — the user left checkout WITHOUT tapping
    /// Subscribe. At most once per visit.
    ///
    /// Why it exists: 111 of the 205 users who reached this screen in the 14
    /// days to 2026-09-23 left without tapping buy, and the screen emitted only
    /// `line_checkout_view` and `line_plan_selected` — nothing said how long
    /// they read, what they saw, or how they went. `how` is `back` (the ✕),
    /// `background` (the app left the foreground) or `restore` (Restore found
    /// a live line and closed the screen — not an abandonment, and tagged so
    /// it is never read as one).
    private func logExit(how: String) {
        guard let started = CheckoutVisit.startedAt, !CheckoutVisit.purchaseStarted else { return }
        CheckoutVisit.startedAt = nil
        var props: [String: AnalyticsValue] = [
            "how": .string(how),
            "seconds": .int(max(0, Int(Date().timeIntervalSince(started)))),
            "plan": .string(subs.selectedPlan.rawValue),
            "intro": .bool(subs.selectedIntroPriceDisplay != nil),
            // The uncollapsed US/PR "texts often don't arrive" warning. It is
            // not collapsible, so what matters is whether it was on screen.
            "capability_note": .bool(sendingWarningShown),
            "good_to_know_expanded": .bool(limitsShown),
        ]
        if let country = state.lineCountry { props["country"] = .string(country) }
        Analytics.shared.track("line_checkout_exit", props)
    }
}

/// One checkout visit, held OUTSIDE the view on purpose.
///
/// `@State` belongs to one view instance, and this cover's content can be
/// built twice per visit (see the `onDisappear` note), so per-instance flags would
/// both double-fire and restart the clock. Main-actor only; there is one
/// checkout on screen at a time by construction (`state.flow` is single).
@MainActor
private enum CheckoutVisit {
    static var startedAt: Date?
    static var purchaseStarted = false
    /// Set by a path that closes the screen for a reason other than the ✕.
    static var exitVia: String?

    /// Idempotent: a rebuilt instance must not restart an open visit.
    static func begin() {
        guard startedAt == nil else { return }
        startedAt = Date()
        purchaseStarted = false
        exitVia = nil
    }

    static func end() {
        startedAt = nil
        purchaseStarted = false
        exitVia = nil
    }
}
