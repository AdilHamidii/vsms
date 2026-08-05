import SwiftUI

/// The rented-number store — and, since 2026-08-05, the app's front door.
///
/// The line is the primary product, so this is the first screen most people
/// ever see. Two consequences shape it:
///
/// 1. It carries the full pitch, the price, and the App Store 3.1.2(a)
///    disclosures, because there is no earlier surface to put them on.
/// 2. It keeps an explicit route across to the SMS product. Temp SMS is the
///    second-ranked line, not a retired one, and burying it behind a $9.99
///    paywall would quietly delete the funnel that currently works.
///
/// There is deliberately **no credit pill** in the header. This product is paid
/// entirely through a StoreKit subscription and never touches the wallet;
/// showing a credit balance here would imply otherwise, and it removes the
/// `PurchaseIntent` read path that has already shipped three bugs elsewhere.
struct LineStoreScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api

    /// Jump to the temp-SMS product. Passed in rather than reaching for
    /// `state.tab` directly so the caller owns navigation, matching
    /// `HomeScreen(onOpenEsim:)`.
    var onOpenSms: () -> Void

    @State private var appeared = false
    @State private var now = Date()

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                hero.padding(.top, 18).riseIn(appeared, index: 0)
                cityPicker.padding(.top, 22).riseIn(appeared, index: 1)
                numberSection.padding(.top, 14).riseIn(appeared, index: 2)
                included.padding(.top, 22).riseIn(appeared, index: 3)
                purchase.padding(.top, 20).riseIn(appeared, index: 4)
                disclosures.padding(.top, 18).riseIn(appeared, index: 5)
                smsEscape.padding(.top, 24).riseIn(appeared, index: 6)
            }
            .padding(.horizontal, 20)
            // Clears the floating tab bar + resume bar.
            .padding(.bottom, 120)
        }
        .background(theme.bg)
        .task {
            // Only quote if we have nothing. Switching tabs destroys and
            // rebuilds this view, so an unconditional fetch would re-search on
            // every visit and replace the number the user is looking at.
            if state.lineOffer == nil, state.lineUnavailableReason == nil {
                await state.loadLineNumbers(using: LineAPI(client: api))
            }
            withAnimation(RMotion.content) { appeared = true }
        }
        // Drives the hold countdown. One second is the right granularity for a
        // number that is ticking down in front of someone.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                now = Date()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Second number")
                    .font(RFont.text(13)).foregroundStyle(theme.text2)
                Text("Your own number")
                    .font(RFont.display(28, weight: .bold))
                    .tracking(-0.7).foregroundStyle(theme.text)
            }
            Spacer()
        }
        .padding(.top, 6)
    }

    private var hero: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 22) {
                    capability(icon: RIcon.message, title: "Texts")
                    capability(icon: RIcon.phone, title: "Calls")
                }
                Text("A real Canadian phone number that stays yours. Send and receive texts and calls without leaving vSMS.")
                    .font(RFont.text(14))
                    .foregroundStyle(theme.text2)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func capability(icon: String, title: LocalizedStringKey) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.ink)
            Text(title)
                .font(RFont.display(15, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(theme.text)
        }
    }

    // MARK: - City

    /// Cities, never area codes.
    ///
    /// Canada's prestige codes are exhausted — 416 and 647 (Toronto), 514
    /// (Montreal), 613 (Ottawa) and 403 (Calgary) all return zero stock — while
    /// their overlays are full. A raw area-code picker would offer "416 —
    /// Toronto" and then fail, so the server takes a city and walks its codes
    /// in order. The list comes from the server for the same reason: an area
    /// code running dry is its decision, and a hardcoded client list would
    /// offer somewhere we can no longer fill.
    private var cityPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(label: "Choose a city")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(state.lineCities) { city in
                        ChipButton(
                            label: city.label,
                            active: city.id == state.lineCity
                        ) {
                            guard city.id != state.lineCity else { return }
                            Task {
                                await state.loadLineNumbers(
                                    using: LineAPI(client: api), city: city.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            // Negative inset so the chips can bleed to the screen edge while
            // the section header stays aligned with everything else.
            .padding(.horizontal, -4)
        }
    }

    // MARK: - The number

    @ViewBuilder
    private var numberSection: some View {
        if state.isLoadingLineNumbers, state.lineOffer == nil {
            loadingCard
        } else if let offer = state.lineOffer {
            numberCard(offer)
        } else {
            unavailableCard
        }
    }

    private var loadingCard: some View {
        Card {
            HStack(spacing: 12) {
                ProgressView()
                Text("Finding you a number…")
                    .font(RFont.text(14)).foregroundStyle(theme.text2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 34)
        }
    }

    private func numberCard(_ offer: LineNumberOffer) -> some View {
        Card {
            VStack(spacing: 10) {
                Text(cityLabel.map { String(localized: "Your \($0) number") }
                     ?? String(localized: "Your number"))
                    .font(RFont.text(12, weight: .medium))
                    .tracking(0.2)
                    .foregroundStyle(theme.text2)

                Text(PhoneFormat.national(offer.phoneNumber))
                    .font(RFont.mono(24, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)

                holdLine

                Button {
                    Task { await state.loadLineNumbers(using: LineAPI(client: api)) }
                } label: {
                    Text("Try another number")
                        .font(RFont.text(13, weight: .medium))
                        .foregroundStyle(theme.text2)
                }
                .buttonStyle(.plain)
                .disabled(state.isLoadingLineNumbers)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .padding(.horizontal, 18)
        }
    }

    /// The hold, or an honest absence of one.
    ///
    /// `heldUntil` is optional because Telnyx reservations have not been
    /// exercised live — only `reservable: true` from a search response is on
    /// record. So when there is no hold this says **"Available now"** and shows
    /// no countdown, rather than claiming a reservation we did not place. Same
    /// rule as `DataRing`'s "no reading": say what is observable, never what
    /// would be reassuring.
    @ViewBuilder
    private var holdLine: some View {
        if let until = state.lineReservation?.heldUntil, until > now {
            let remaining = Int(until.timeIntervalSince(now))
            Text("Held for you · \(PhoneFormat.duration(remaining))")
                .font(RFont.text(12, weight: .medium))
                .foregroundStyle(theme.live)
                .contentTransition(.numericText())
        } else {
            Text("Available now")
                .font(RFont.text(12))
                .foregroundStyle(theme.text3)
        }
    }

    /// Two causes, and we only ever know one of them.
    ///
    /// `paused` is something the server told us and can be stated. An empty
    /// search result is an observation about one city and nothing more — and a
    /// failed fetch looks identical from here, which is why `unknown` claims no
    /// reason at all. Same discipline as `EsimStoreScreen.emptyCatalog`.
    private var unavailableCard: some View {
        Card {
            VStack(spacing: 8) {
                Image(systemName: state.lineUnavailableReason == .paused
                      ? "pause.circle" : RIcon.phone)
                    .font(.system(size: 30))
                    .foregroundStyle(theme.text3)
                Text(unavailableTitle)
                    .font(RFont.display(16, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .multilineTextAlignment(.center)
                Text(unavailableBody)
                    .font(RFont.text(13))
                    .foregroundStyle(theme.text2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .padding(.horizontal, 24)
        }
    }

    private var unavailableTitle: LocalizedStringKey {
        switch state.lineUnavailableReason {
        case .paused:  "Second numbers are unavailable"
        case .noStock: "No numbers in this city right now"
        default:       "We couldn't load a number"
        }
    }

    private var unavailableBody: LocalizedStringKey {
        switch state.lineUnavailableReason {
        case .paused:  "We've paused new numbers while we make some improvements. Check back soon."
        case .noStock: "Try another city — stock moves through the day."
        default:       "Check your connection and try another city."
        }
    }

    private var cityLabel: String? {
        state.lineCities.first { $0.id == state.lineCity }?.label
    }

    // MARK: - What you get

    private var included: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(label: "What's included")
            Bullet(text: "200 texts every month")
            Bullet(text: "100 minutes of calls every month")
            Bullet(text: "Keep the same number for as long as you stay subscribed")
            Bullet(text: "Texts and calls happen inside vSMS — your real number stays private")
        }
    }

    // MARK: - Purchase

    /// App Store 3.1.2(a): price, period, renewal terms and links to Terms and
    /// Privacy must all appear IN-APP before the purchase. This is the most
    /// common subscription rejection, and there is no earlier screen to put
    /// them on.
    private var purchase: some View {
        VStack(spacing: 10) {
            VStack(spacing: 3) {
                Text("$9.99 per month")
                    .font(RFont.display(17, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(theme.text)
                Text("Renews automatically each month until you cancel. Cancel anytime in your Apple ID settings.")
                    .font(RFont.text(12))
                    .foregroundStyle(theme.text2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PrimaryButton(
                label: "Get this number",
                disabled: state.lineOffer == nil
            ) {
                // Purchase lands with the subscription step. Saying so beats a
                // dead button: an unexplained disabled CTA reads as breakage.
                state.lastError = String(
                    localized: "Second numbers open for purchase very soon — the number above is real and available today.")
            }

            HStack(spacing: 14) {
                Link("Terms", destination: LegalLinks.terms)
                Text("·").foregroundStyle(theme.text3)
                Link("Privacy", destination: LegalLinks.privacy)
            }
            .font(RFont.text(12))
            .tint(theme.text2)
        }
    }

    // MARK: - Disclosures

    private var disclosures: some View {
        VStack(spacing: 10) {
            notice(icon: "flag", tint: theme.text2,
                   text: "US numbers are coming soon. Canadian numbers work with US and Canadian phones today.")
            // E911 is disclosed here, at activation, and in the manage screen —
            // unmissably, never behind a Terms link. A reviewer will look for
            // it, and so would a regulator.
            notice(icon: "exclamationmark.triangle", tint: theme.warn,
                   text: "This number can't call 911 or any emergency service. Always use your phone's own number for emergencies.")
        }
    }

    private func notice(icon: String, tint: Color, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 2)
            Text(text)
                .font(RFont.text(12))
                .foregroundStyle(theme.text2)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - The other product

    /// Temp SMS is second in the business, not retired. Now that this screen is
    /// the launch surface, it is the only thing standing between a user who
    /// wants a one-off code and a monthly subscription pitch.
    private var smsEscape: some View {
        Button(action: onOpenSms) {
            HStack(spacing: 8) {
                Text("Just need a one-off verification code?")
                    .font(RFont.text(13))
                    .foregroundStyle(theme.text2)
                Image(systemName: RIcon.arrow)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.ink)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(theme.chipBg, in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}
