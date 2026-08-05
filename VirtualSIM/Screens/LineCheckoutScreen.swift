import SwiftUI

/// The last screen before paying, and the FIRST one that mentions money.
///
/// Everything before it asks the user to choose — a city, then their actual
/// digits. By the time they land here the number on screen is already theirs in
/// every sense except the payment, which is the moment a price is worth
/// reading. Leading with "$9.99/month" asks someone to value a product they
/// have not seen.
///
/// It also carries the App Store **3.1.2(a)** disclosures — price, billing
/// period, renewal terms and links to Terms and Privacy, all in-app and all
/// before the purchase. That is the most common subscription rejection, and
/// this is the screen the requirement is actually about.
struct LineCheckoutScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    @Environment(SubscriptionStore.self) private var subs

    @State private var appeared = false
    @State private var now = Date()
    @State private var isReserving = false

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 0) {
                        numberCard.riseIn(appeared, index: 0)
                        included.padding(.top, 22).riseIn(appeared, index: 1)
                        priceBlock.padding(.top, 24).riseIn(appeared, index: 2)
                        emergency.padding(.top, 18).riseIn(appeared, index: 3)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
                cta
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

    private var header: some View {
        HStack {
            Button { state.flow = nil } label: {
                Image(systemName: RIcon.close)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.text2)
                    .frame(width: 34, height: 34)
                    .background(theme.chipBg, in: .circle)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    // MARK: - The number

    private var numberCard: some View {
        VStack(spacing: 10) {
            Text("Your new number")
                .font(RFont.text(12, weight: .medium))
                .tracking(0.2)
                .foregroundStyle(theme.text2)

            Text(PhoneFormat.national(state.lineOffer?.phoneNumber ?? ""))
                .font(RFont.mono(26, weight: .semibold))
                .foregroundStyle(theme.text)
                .minimumScaleFactor(0.7)
                .lineLimit(1)

            holdLine
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 18)
        .background(theme.elev, in: .rect(cornerRadius: 22))
        .padding(.top, 4)
    }

    /// The hold, or an honest absence of one.
    ///
    /// `heldUntil` is optional because Telnyx reservations have not been
    /// exercised live — only `reservable: true` from a search response is on
    /// record. With no hold this says **"Available now"** and shows no
    /// countdown, rather than claiming a reservation we did not place. Same
    /// rule as `DataRing`'s "no reading": say what is observable, never what
    /// would be reassuring.
    @ViewBuilder
    private var holdLine: some View {
        if let until = state.lineReservation?.heldUntil, until > now {
            Text("Held for you · \(PhoneFormat.duration(Int(until.timeIntervalSince(now))))")
                .font(RFont.text(12, weight: .medium))
                .foregroundStyle(theme.live)
                .contentTransition(.numericText())
        } else {
            Text("Available now")
                .font(RFont.text(12))
                .foregroundStyle(theme.text3)
        }
    }

    // MARK: - What you get

    private var included: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(label: "What you get")
            Bullet(text: "200 texts every month")
            Bullet(text: "100 minutes of calls every month")
            Bullet(text: "Keep this number for as long as you stay subscribed")
            Bullet(text: "Texts and calls happen inside vSMS — your own number stays private")
        }
    }

    // MARK: - Price
    //
    // App Store 3.1.2(a): price, period, renewal terms and the two legal links
    // must all appear in-app before the purchase.

    private var priceBlock: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                // StoreKit's own localized price, never a literal. This block
                // IS the 3.1.2(a) disclosure, so a hardcoded "$9.99" beside a
                // button reading "9,99 €/mo" discloses a price the user will
                // not be billed — the same drift that put $4.99 against €5.99
                // on the credit ladder's top product. Hidden entirely when the
                // real price is unknown, rather than guessed.
                if let price = subs.displayPrice {
                    Text(price)
                        .font(RFont.display(30, weight: .bold))
                        .tracking(-0.8)
                        .foregroundStyle(theme.text)
                    Text("per month")
                        .font(RFont.text(15))
                        .foregroundStyle(theme.text2)
                }
            }
            Text("Renews automatically each month until you cancel. Cancel anytime in your Apple ID settings.")
                .font(RFont.text(12))
                .foregroundStyle(theme.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Link("Terms", destination: LegalLinks.terms)
                Text("·").foregroundStyle(theme.text3)
                Link("Privacy", destination: LegalLinks.privacy)
            }
            .font(RFont.text(12))
            .tint(theme.text2)
        }
        .frame(maxWidth: .infinity)
    }

    /// Disclosed here as well as in the store and the manage screen —
    /// unmissably, never behind a Terms link. A reviewer will look for it, and
    /// so would a regulator.
    private var emergency: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.warn)
                .padding(.top, 2)
            Text("This number can't call 911 or any emergency service. Always use your phone's own number for emergencies.")
                .font(RFont.text(12))
                .foregroundStyle(theme.text2)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// Disabled WITH its reason showing, never failing on tap.
    ///
    /// When the App Store has not returned the product — it is unreleased,
    /// StoreKit is unreachable, or the storefront does not carry it — the
    /// purchase cannot succeed, and a live-looking button that throws an error
    /// is the worst version of that. Same rule as `ThreadScreen`'s composer.
    private var cta: some View {
        VStack(spacing: 8) {
            if unavailable {
                Text("The App Store isn't offering this subscription right now. Please try again in a moment.")
                    .font(RFont.text(12))
                    .foregroundStyle(theme.text2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PrimaryButton(
                label: ctaLabel,
                disabled: busy || state.lineOffer == nil || subs.product == nil,
                action: buy
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 28)
        .background(theme.bg)
    }

    private var busy: Bool { isReserving || subs.isPurchasing }

    /// Distinguishes "still loading" from "the store has no such product" —
    /// collapsing the two would tell a user on a slow connection that the
    /// product does not exist.
    private var unavailable: Bool { subs.product == nil && !subs.isLoadingProduct }

    /// Names the step in progress rather than showing a spinner on a button
    /// whose label still says "Get this number". Reserving involves a live
    /// Telnyx round trip, so the pause is real and unexplained silence there
    /// reads as a dead tap.
    private var ctaLabel: String {
        if isReserving { return String(localized: "Checking availability…") }
        if subs.isPurchasing { return String(localized: "Confirming…") }
        if subs.isLoadingProduct { return String(localized: "Loading…") }
        if unavailable { return String(localized: "Temporarily unavailable") }
        // StoreKit's own localized price, never a hardcoded "$9.99" — the
        // credit ladder drifted to $4.99-vs-€5.99 on its top product precisely
        // because prices were assumed instead of read.
        if let p = subs.displayPrice { return String(localized: "Get this number · \(p)/mo") }
        return String(localized: "Get this number")
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
                state.flow = .lineProvisioning
            } else if let msg = subs.lastError {
                state.lastError = msg
            }
        }
    }
}
