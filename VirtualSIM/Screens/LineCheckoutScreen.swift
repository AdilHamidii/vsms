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

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        intro.riseIn(appeared, index: 0)
                        numberCard.padding(.top, 20).riseIn(appeared, index: 1)
                        included.padding(.top, 26).riseIn(appeared, index: 2)
                        priceBlock.padding(.top, 22).riseIn(appeared, index: 3)
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

                BottomBar { cta }
            }
        }
        .task {
            withAnimation(RMotion.content) { appeared = true }
            // Loads the localized price. Cheap and idempotent, and without it
            // the CTA falls back to a label with no price at all.
            await subs.loadProduct()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                now = Date()
            }
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
                    _ = await iap.restorePurchases()
                    await state.loadLine(using: LineAPI(client: api))
                    if state.line != nil {
                        RHaptic.success()
                        state.flow = nil
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

    /// ⚠️ **This must never advertise calling.**
    ///
    /// It previously read "100 minutes of calls every month" and the store
    /// screen said texts and calls "happen right here". There is no dialer:
    /// `flow = .dialer` is assigned nowhere in the app, and `ContentView`
    /// renders "Calling from your number is coming very soon" for that case.
    /// Selling a capability the buyer cannot use after paying is a refund
    /// driver and an App Review 2.3.1 exposure. Calling appears here only as an
    /// explicitly unavailable line, and moves into the paid list on the day the
    /// dialer ships — not before.
    private var included: some View {
        VStack(alignment: .leading, spacing: 0) {
            MicroLabel("What you get")
                .padding(.bottom, 10)

            Card(elevation: .raised) {
                VStack(spacing: 0) {
                    BenefitRow(icon: RIcon.message, figure: "200",
                               label: "texts a month, in and out")
                    RowRule()
                    BenefitRow(icon: "infinity",
                               label: "Keep this number for as long as you subscribe")
                    RowRule()
                    BenefitRow(icon: "lock.fill",
                               label: "Your own number never leaves your phone")
                    RowRule()
                    BenefitRow(icon: RIcon.phone,
                               label: "Calling", hint: "Coming soon",
                               tint: theme.text3)
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
    private var priceBlock: some View {
        Card(radius: RRadius.md, elevation: .flat,
             fill: theme.inkSoft.opacity(0.5), border: theme.ink.opacity(0.28)) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let price = subs.displayPrice {
                        Text(price)
                            .displayType(30)
                            .foregroundStyle(theme.text)
                        Text("per month")
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

                Text("Renews every month until you cancel. Cancel any time in your Apple ID settings.")
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

    private var legal: some View {
        HStack(spacing: 12) {
            Link("Terms", destination: LegalLinks.terms)
            Text(verbatim: "·").foregroundStyle(theme.text3)
            Link("Privacy", destination: LegalLinks.privacy)
            Spacer(minLength: 0)
        }
        .font(RFont.text(12))
        .tint(theme.text2)
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

            PrimaryButton(
                label: ctaLabel,
                sub: busy ? nil : subs.displayPrice.map { "\($0)/mo" },
                disabled: busy || state.lineOffer == nil || subs.product == nil,
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
    private var unavailable: Bool { subs.product == nil && !subs.isLoadingProduct }

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
