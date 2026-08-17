import StoreKit
import SwiftUI

/// The last screen before paying, and the FIRST one that mentions money.
///
/// ── Why it is shaped like this ────────────────────────────────────────────
///
/// Everything before it asks the user to choose — a city, then their actual
/// digits. By the time they land here the number on screen is already theirs in
/// every sense except the payment, which is the moment a price is worth
/// reading. Leading with "$9.99/month" asks someone to value a product they
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

    @State private var appeared = false
    @State private var now = Date()
    @State private var isReserving = false
    @State private var isRestoring = false

    /// Scroll anchor for the plan picker. Only the screenshot harness uses it,
    /// but it is a plain view id rather than DEBUG-only state so the scroll
    /// target cannot drift out of sync with the section it names.
    private static let planAnchor = "plan-picker"

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            intro.riseIn(appeared, index: 0)
                            numberCard.padding(.top, 20).riseIn(appeared, index: 1)
                            included.padding(.top, 26).riseIn(appeared, index: 2)
                            // Choice first, then the price block — which restates
                            // the selection in full with its renewal terms. Putting
                            // the picker after the price would mean the 3.1.2(a)
                            // disclosure is read before the thing it describes has
                            // been chosen.
                            planPicker.padding(.top, 20).riseIn(appeared, index: 3)
                                .id(Self.planAnchor)
                            priceBlock.padding(.top, 12).riseIn(appeared, index: 3)
                            // The safety disclosure sits ABOVE the action, not
                            // between the price and the button. Price -> CTA has to
                            // be adjacent: the last thing read before a purchase
                            // decision should not be a liability warning.
                            emergency.padding(.top, 18).riseIn(appeared, index: 4)
                            legal.padding(.top, 14).riseIn(appeared, index: 5)
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    }
                    .scrollIndicators(.hidden)
                    // A screenshot frame has to SHOW the plan choice and the
                    // 3.1.2(a) renewal sentence, and on a fresh open both sit
                    // below the fold — the first frame taken this way showed
                    // only the hero and the CTA. Scrolled deterministically
                    // rather than by a scripted swipe, which is the same reason
                    // `ScreenshotMode` addresses screens by launch argument
                    // instead of driving the UI: a frame has to come out
                    // identical every run.
                    //
                    // `isActive` is a stored `false` in Release, so this is
                    // folded away in a shipping build.
                    .task {
                        guard ScreenshotMode.isActive else { return }
                        try? await Task.sleep(for: .milliseconds(400))
                        proxy.scrollTo(Self.planAnchor, anchor: .top)
                    }
                }

                BottomBar { cta }
            }
        }
        .task {
            withAnimation(RMotion.content) { appeared = true }
            // Loads the localized price. Cheap and idempotent, and without it
            // the CTA falls back to a label with no price at all.
            await subs.loadProduct()
        }
        // ⚠️ Ticks ONLY while there is a countdown to tick.
        //
        // `now` drives exactly one thing: the "Held for you · 4:12" pill. It
        // used to be reassigned every second unconditionally, which invalidates
        // this whole body — number card, price block, legal text, the lot — at
        // 1 Hz on a screen that is usually showing "Available now" and has
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

    /// Restore lives here, not only in Account.
    ///
    /// A user who was charged and has no number is standing on this screen, not
    /// three taps deep in settings — and App Review 3.1.1 expects the control
    /// to be reachable wherever a purchase is offered.
    private var header: some View {
        HStack {
            Button { state.flow = nil } label: {
                Image(systemName: RIcon.close)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.text2)
                    .frame(width: 34, height: 34)
                    .background(theme.chipBg, in: .circle)
            }
            .pressable(0.92)

            Spacer()

            Button {
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
                        state.flow = nil
                    } else if let msg = subs.lastError {
                        // A restore that recovers nothing must SAY so. Silence
                        // reads as "it worked" — the worst possible answer for
                        // the only person who ever taps this button: someone
                        // who has been charged and has no number.
                        RHaptic.warn()
                        state.lastError = msg
                    }
                }
            } label: {
                Text(isRestoring ? "Restoring…" : "Restore")
                    .font(RFont.text(13, weight: .medium))
                    .foregroundStyle(theme.text2)
            }
            .pressable(0.94)
            .disabled(isRestoring)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: - What this screen is

    private var intro: some View {
        VStack(alignment: .leading, spacing: 0) {
            MicroLabel("Second number")

            // Names the city the user chose three taps ago. The old screen
            // never said the word, so the thing they had just picked did not
            // appear on the screen confirming it.
            Text(cityLabel.map { "Your \($0) number, ready now." }
                 ?? String(localized: "Your new number, ready now."))
                .displayType(29)
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            Text("Send and receive texts right here. Your real number stays private.")
                .font(RFont.text(15))
                .foregroundStyle(theme.text2)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
    }

    private var cityLabel: String? {
        guard let id = state.lineCity else { return nil }
        return state.lineCities.first { $0.id == id }?.label
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

    /// The one object this screen is about, and the only elevated thing on it.
    ///
    /// It used to be `theme.elev` on `theme.bg` with no shadow and no border —
    /// in light mode a ~1.5% luminance step — so the emotional centre of the
    /// purchase rendered as a flat white rectangle indistinguishable from a
    /// settings row.
    private var numberCard: some View {
        HeroCard {
            VStack(spacing: 12) {
                HStack(spacing: 7) {
                    Text(verbatim: "🇨🇦").font(.system(size: 15))
                    Text(placeLine)
                        .font(RFont.text(12, weight: .semibold))
                        .foregroundStyle(theme.text2)
                }

                Text(PhoneFormat.national(state.lineOffer?.phoneNumber ?? ""))
                    .font(RFont.mono(31, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)

                holdLine
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .padding(.horizontal, 18)
        }
    }

    private var placeLine: String {
        let city = cityLabel ?? String(localized: "Canada")
        if let areaCode { return "\(city) · \(areaCode)" }
        return city
    }

    /// The hold, or an honest absence of one.
    ///
    /// `heldUntil` is optional because Telnyx reservations have not been
    /// exercised live — only `reservable: true` from a search response is on
    /// record. With no hold this says **"Available now"** and shows no
    /// countdown, rather than claiming a reservation we did not place.
    ///
    /// It is a `StatusPill` rather than 12pt `text3`, which is the faintest ink
    /// on the screen: the one slot designed to carry presence was spending
    /// itself on the least visible thing available. Same words, actual weight.
    @ViewBuilder
    private var holdLine: some View {
        if let until = state.lineReservation?.heldUntil, until > now {
            StatusPill(
                text: "Held for you · \(PhoneFormat.duration(Int(until.timeIntervalSince(now))))")
                .contentTransition(.numericText())
        } else {
            StatusPill(text: "Available now")
        }
    }

    // MARK: - What you get

    /// ⚠️ **Only sell what ships.**
    ///
    /// Calling sat here as an explicitly unavailable "Coming soon" row for as
    /// long as `flow = .dialer` was assigned nowhere, and moved into the paid
    /// list in the same commit that linked the SDK and wired the dialer — the
    /// ordering this comment exists to preserve. Selling a capability the
    /// buyer cannot use after paying is a refund driver and an App Review
    /// 2.3.1 exposure.
    ///
    /// ⚠️ **Emergency calling is NOT included and is disclosed separately** —
    /// see the notice on `NumberDetailView`. Nothing in this list may imply
    /// the number can reach 911.
    private var included: some View {
        VStack(alignment: .leading, spacing: 0) {
            MicroLabel("What you get")
                .padding(.bottom, 10)

            Card(elevation: .raised) {
                VStack(spacing: 0) {
                    // Figures come from `LineProduct`, the single client-side
                    // mirror of the schema defaults — never inline literals.
                    // See the note there for why mirroring is safe for these
                    // two and was not for the signup grant.
                    BenefitRow(icon: RIcon.message,
                               figure: "\(LineProduct.smsAllowance)",
                               label: "texts a month, in and out")
                    RowRule()
                    BenefitRow(icon: RIcon.phone,
                               figure: "\(LineProduct.voiceAllowanceMinutes)",
                               label: "minutes of calls a month, in and out")
                    RowRule()
                    BenefitRow(icon: "infinity",
                               label: "Keep this number for as long as you subscribe")
                    RowRule()
                    BenefitRow(icon: "lock.fill",
                               label: "Your own number never leaves your phone")
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Price
    //
    // App Store 3.1.2(a): price, period, renewal terms and the two legal links
    // must all appear in-app before the purchase.

    /// Stated **once**, from StoreKit, in a bordered container.
    ///
    /// The old block printed the price at `display(30)` and then again inside
    /// the CTA label 200pt below, and it wrapped BOTH the figure and its "per
    /// month" label in `if let price` — so before StoreKit answered, the whole
    /// row collapsed and the renewal sentence slid up under the bullets and
    /// then jumped back down. A visible layout jump on the paywall's first
    /// paint. The height is now reserved, so nothing reflows.
    /// Monthly vs yearly.
    ///
    /// Rendered ONLY when StoreKit actually returned both products. If the
    /// yearly is missing — still `MISSING_METADATA` in App Store Connect, not
    /// yet available in this storefront, or simply not loaded — the screen
    /// falls back to exactly what it was before, a single monthly plan, rather
    /// than offering a choice one side of which cannot be bought.
    @ViewBuilder
    private var planPicker: some View {
        if subs.hasMonthly, subs.hasYearly {
            VStack(spacing: 8) {
                planRow(.monthly,
                        title: String(localized: "Monthly"),
                        price: subs.monthlyPriceDisplay,
                        badge: nil,
                        note: nil)
                planRow(.yearly,
                        title: String(localized: "Yearly"),
                        price: subs.yearlyPriceDisplay,
                        // Both derived from live StoreKit, so neither can promise
                        // something the store will not honour: the saving is
                        // computed from the two real prices, and the trial
                        // vanishes for an Apple ID that has already used one —
                        // Apple allows a single introductory offer per
                        // subscription GROUP per Apple ID.
                        //
                        // They are shown TOGETHER rather than one-or-the-other,
                        // and each disappears on its own. Either can be absent
                        // without the row losing its meaning.
                        badge: subs.yearlySavingsPercent.map { String(localized: "SAVE \($0)%") },
                        note: subs.trialLabel.map { String(localized: "\($0) free, then billed yearly") })
            }
        }
    }

    private func planRow(_ plan: LinePlan, title: String,
                         price: String?, badge: String?, note: String?) -> some View {
        let active = subs.selectedPlan == plan
        return Button {
            RHaptic.select()
            withAnimation(RMotion.select) { subs.selectedPlan = plan }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: active ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(active ? theme.ink : theme.text3)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(verbatim: title)
                            .font(RFont.text(15, weight: .semibold))
                            .foregroundStyle(theme.text)
                        // Same treatment as the credit ladder's MOST POPULAR /
                        // BEST VALUE chips, so it reads as this app's own
                        // marketing rather than a sticker bolted on. `accent2`
                        // deliberately, NOT `live` — green means "your code
                        // arrived" and "your credits came back" here, and
                        // spending a semantic colour on a sales badge is the
                        // collision the palette rules forbid.
                        if let badge {
                            Text(verbatim: badge)
                                .font(RFont.text(10, weight: .heavy))
                                .tracking(0.3)
                                .foregroundStyle(theme.accent2)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(theme.inkSoft, in: .capsule)
                        }
                    }
                    if let note {
                        Text(verbatim: note)
                            .font(RFont.text(12))
                            .foregroundStyle(theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Text(verbatim: price ?? "—")
                    .font(RFont.text(15, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: RRadius.md, style: .continuous)
                    .fill(active ? theme.inkSoft.opacity(0.5) : theme.elev)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RRadius.md, style: .continuous)
                    .stroke(active ? theme.ink.opacity(0.5) : theme.sep,
                            lineWidth: active ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        // 44pt minimum, and the whole row is the target rather than the radio.
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }

    private var priceBlock: some View {
        Card(radius: RRadius.md, elevation: .flat,
             fill: theme.inkSoft.opacity(0.5), border: theme.ink.opacity(0.28)) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let price = subs.displayPrice {
                        Text(price)
                            .displayType(30)
                            .foregroundStyle(theme.text)
                        // Follows the SELECTED plan. A price that says "per
                        // month" beside a yearly charge is both a lie and an
                        // App Store 3.1.2(a) violation.
                        Text(subs.selectedPlan == .yearly ? "per year" : "per month")
                            .font(RFont.text(15))
                            .foregroundStyle(theme.text2)
                    } else {
                        Text(verbatim: "—")
                            .displayType(30)
                            .foregroundStyle(theme.text3)
                            .redacted(reason: subs.isLoadingProduct ? .placeholder : [])
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 36)

                // 3.1.2(a) requires the ACTUAL billing period and renewal
                // terms. When a free trial applies, it also requires saying
                // what happens when it ends — the most common reason a
                // subscription paywall is rejected.
                Group {
                    if subs.selectedPlan == .yearly {
                        if let trial = subs.trialLabel {
                            Text("\(trial) free, then \(subs.displayPrice ?? "").  Renews every year until you cancel. Cancel any time in your Apple ID settings.")
                        } else {
                            Text("Renews every year until you cancel. Cancel any time in your Apple ID settings.")
                        }
                    } else {
                        Text("Renews every month until you cancel. Cancel any time in your Apple ID settings.")
                    }
                }
                .font(RFont.text(12))
                .foregroundStyle(theme.text2)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Disclosed here as well as in the store and the manage screen —
    /// unmissably, never behind a Terms link. A reviewer will look for it, and
    /// so would a regulator.
    ///
    /// It gets a real container so it cannot be confused with the roadmap note
    /// on the store screen, which was rendered with identical weight and
    /// spacing: a safety warning and a "coming soon" should not look alike.
    private var emergency: some View {
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
        .background(theme.warnSoft, in: .rect(cornerRadius: RRadius.sm))
    }

    /// Guideline 3.1.2(c): the purchase flow must carry functional links to the
    /// Terms of Use (EULA) and the privacy policy. The 2.0(37) rejection taught
    /// two things: the labels must NAME the documents ("Terms" reads as our own
    /// terms, not the EULA the metadata declares), and links tinted like muted
    /// body text are links a reviewer does not see. One link per line — the
    /// German labels don't fit side by side on a 375pt screen.
    private var legal: some View {
        VStack(alignment: .leading, spacing: 6) {
            Link("Terms of Use (EULA)", destination: LegalLinks.eula)
            Link("Privacy Policy", destination: LegalLinks.privacy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(RFont.text(12))
        .tint(theme.ink)
    }

    // MARK: - Action

    private var cta: some View {
        VStack(spacing: 10) {
            if unavailable {
                Text("The App Store isn't offering this subscription right now. Please try again in a moment.")
                    .font(RFont.text(12))
                    .foregroundStyle(theme.text2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // ⚠️ The period must FOLLOW the selected plan. This read
            // `"\($0)/mo"` unconditionally, so picking Yearly rendered
            // "$99.99/mo" directly under the button — a 10× misstatement of
            // the billing period, in the one place App Store 3.1.2(a) is
            // about. `priceBlock` had it right ("per year" / "per month") and
            // the CTA silently contradicted it 200pt below.
            PrimaryButton(
                label: ctaLabel,
                sub: busy ? nil : subs.displayPrice.map {
                    "\($0)\(subs.selectedPlan == .yearly ? "/yr" : "/mo")"
                },
                disabled: busy || state.lineOffer == nil || !subs.hasMonthly,
                action: buy
            )

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
    /// reads as a dead tap. The price rides in the `sub` slot, which
    /// `PrimaryButton` has for exactly this and which the old label crammed
    /// into its own text.
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
        Task {
            isReserving = true
            let quote: LineReservationQuote?
            do {
                quote = try await LineAPI(client: api)
                    .reserve(city: city, phoneNumber: offer.phoneNumber)
            } catch let err as APIError {
                isReserving = false
                RHaptic.warn()
                state.lastError = err.userMessage
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
            let ok = await subs.purchase(
                phoneNumber: quote.phoneNumber, city: city,
                monthlyCents: quote.monthlyCents)

            if ok {
                RHaptic.success()
                state.flow = .lineProvisioning
            } else if let msg = subs.lastError {
                state.lastError = msg
            }
        }
    }
}
