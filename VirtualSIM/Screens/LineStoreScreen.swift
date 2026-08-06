import SwiftUI

/// The rented-number store — and, since 2026-08-05, the app's front door.
///
/// ── Why this is a sequence and not one long page ──────────────────────────
///
/// It asks the user to CHOOSE twice before it ever mentions money: pick a city,
/// pick your actual number, and only then see the price. Two reasons, and the
/// second is the important one:
///
/// 1. Each step renders instantly. A single page had to wait on a Telnyx search
///    before it could show anything, and the whole screen sat blank meanwhile.
/// 2. By the time the price appears, the number on screen is *theirs* — they
///    picked the city and picked the digits. Leading with "$9.99/month" asks
///    someone to value a product they have not seen yet.
///
/// There is deliberately **no credit pill** anywhere here. This product is paid
/// entirely through a StoreKit subscription and never touches the wallet;
/// showing a balance would imply otherwise, and it removes the `PurchaseIntent`
/// read path that has already shipped three bugs elsewhere.
///
/// The price, period, renewal terms and Terms/Privacy links live on
/// `LineCheckoutScreen`, which is the screen immediately before the purchase —
/// which is what App Store 3.1.2(a) actually requires.
struct LineStoreScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    @Environment(SubscriptionStore.self) private var subs

    /// Jump to the temp-SMS product. Passed in rather than reaching for
    /// `state.tab` directly so the caller owns navigation, matching
    /// `HomeScreen(onOpenEsim:)`.
    var onOpenSms: () -> Void

    private enum Step: Hashable { case city, number }
    @State private var step: Step = .city
    @State private var appeared = false

    var body: some View {
        ZStack {
            switch step {
            case .city:   cityStep.transition(stepTransition(forward: true))
            case .number: numberStep.transition(stepTransition(forward: false))
            }
        }
        .background(theme.bg)
        // Set BEFORE any await. This flag drives `riseIn`, so awaiting a network
        // call first left the entire screen at opacity 0 until Telnyx answered —
        // which is exactly what "the rent number screen takes too long to show
        // up" was. Nothing on the city step needs the network at all.
        .task {
            withAnimation(RMotion.content) { appeared = true }
            // Prefetch ONLY — this screen no longer shows a price (see the
            // note above `cityList`). Kept because the store is the app's
            // first screen, so the product is warm by the time the paywall
            // opens; `LineCheckoutScreen` renders a redacted placeholder while
            // StoreKit is still answering, and this usually removes it.
            // Idempotent, so calling it in both places is free.
            await subs.loadProduct()
        }
    }

    private func stepTransition(forward: Bool) -> AnyTransition {
        .asymmetric(
            insertion: .move(edge: forward ? .leading : .trailing).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    // MARK: - Step 1 · city
    //
    // Renders with zero network dependency: the city list is seeded and only
    // replaced once a search has run. See `LineCity.seeded`.

    private var cityStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(kicker: "Second number", title: "Your own number")
                pitch.padding(.top, 16).riseIn(appeared, index: 0)

                SectionHeader(label: String(localized: "Where should it be?"))
                    .padding(.top, 24)
                    .riseIn(appeared, index: 1)

                cityList.riseIn(appeared, index: 2)

                usSoon.padding(.top, 16).riseIn(appeared, index: 3)
                smsEscape.padding(.top, 24).riseIn(appeared, index: 4)
            }
            .padding(.horizontal, 20)
            // Clears the floating tab bar + resume bar.
            .padding(.bottom, 120)
        }
    }

    /// ⚠️ **Only sell what ships.** Calling was absent from this card for as
    /// long as `flow = .dialer` was assigned nowhere, and was restored in the
    /// same commit that linked the SDK and wired the dialer. Keep that
    /// ordering for anything added here.
    private var pitch: some View {
        Card(elevation: .raised) {
            VStack(alignment: .leading, spacing: 0) {
                Text("A real Canadian phone number that stays yours.")
                    .font(RFont.display(17, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 14)

                RowRule()
                BenefitRow(icon: RIcon.message,
                           label: "Send and receive texts in the app")
                RowRule()
                BenefitRow(icon: RIcon.phone,
                           label: "Make and take calls in the app")
                RowRule()
                // The actual reason to buy, and it used to be the last clause
                // of a paragraph. It is the only line here that names a
                // problem rather than a feature.
                BenefitRow(icon: RIcon.shield,
                           label: "Keep your own number private",
                           tint: theme.live)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The cities, as ONE grouped object.
    ///
    /// They were seven separate `theme.elev` cards with 8pt gaps — the pattern
    /// every other list in this app avoids. `CountrySheet` and `ServiceSheet`
    /// both put their rows inside a single `Card` divided by `RowRule`, which
    /// is what makes a stack read as one list to choose from rather than seven
    /// unrelated objects competing for the same tap. Seven detached cards also
    /// cost ~8pt of dead space each and made a trivial choice fill the screen.
    ///
    /// The rows stay deliberately plain. There is nothing honest to put on
    /// them: `search-line-numbers` walks a city's area codes until one has
    /// stock (416, 647, 514, 613 and 403 are all exhausted), so printing "437"
    /// beside Toronto would promise digits the reservation may not deliver.
    private var cityList: some View {
        Card(elevation: .flat) {
            VStack(spacing: 0) {
                ForEach(Array(state.lineCities.enumerated()), id: \.element.id) { i, city in
                    cityRow(city)
                    if i < state.lineCities.count - 1 { RowRule(inset: 16) }
                }
            }
        }
    }

    // ⚠️ **THERE IS DELIBERATELY NO PRICE ON THIS SCREEN** (owner decision,
    // 2026-08-06). Read, pick a city, get a number, and meet the paywall once
    // — in that order. A `priceAnchor` capsule lived here and contradicted
    // this file's own header, which has always described the flow as "choose
    // twice before it ever mentions money".
    //
    // The counter-argument is on the record and was overruled: a user who has
    // invested two choices before meeting a recurring charge can feel walked
    // into it, where a price on step one lets people who will not pay leave
    // early. If refunds or 1-star reviews cite a surprise subscription, this
    // is the first thing to re-examine.
    //
    // What makes the removal SAFE is that App Store 3.1.2(a) asks for the
    // disclosure on the screen immediately before the purchase, not on every
    // screen — and `LineCheckoutScreen` carries all of it: price, billing
    // period, renewal terms, and the Terms and Privacy links. Do not add a
    // price back here without moving that reasoning with it.

    /// Cities, never area codes.
    ///
    /// Canada's prestige codes are exhausted — 416 and 647 (Toronto), 514
    /// (Montreal), 613 (Ottawa) and 403 (Calgary) all return zero stock — while
    /// their overlays are full. A raw area-code picker would offer "416 —
    /// Toronto" and then fail, so the server takes a CITY and walks its codes
    /// in order until one has stock.
    private func cityRow(_ city: LineCity) -> some View {
        Button {
            Task {
                // Move first, load second. The tap is the commitment, so the
                // next screen appears immediately and fills in — rather than
                // the user waiting on this one with nothing happening.
                withAnimation(RMotion.panel) { step = .number }
                await state.loadLineNumbers(using: LineAPI(client: api), city: city.id)
            }
        } label: {
            HStack(spacing: 12) {
                Text(city.label)
                    .font(RFont.display(16, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(theme.text)
                Spacer(minLength: 8)
                // The province is a disambiguator, not a second title — two
                // Ontario rows (Toronto, Ottawa) are the only reason it is on
                // screen at all. Trailing and secondary, so the column of city
                // names stays the thing the eye scans.
                Text(city.region)
                    .font(RFont.text(13))
                    .foregroundStyle(theme.text2)
                    .lineLimit(1)
                Image(systemName: RIcon.chev)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.text3)
            }
            .padding(.horizontal, 16)
            // 15 + 15 around a 20pt line clears the 44pt minimum target.
            .padding(.vertical, 15)
            .contentShape(.rect)
        }
        .buttonStyle(PressScaleStyle())
    }

    // MARK: - Step 2 · number

    private var numberStep: some View {
        VStack(spacing: 0) {
            backHeader
            if state.isLoadingLineNumbers, state.lineOffers.isEmpty {
                numberSkeleton
            } else if state.lineOffers.isEmpty {
                unavailable
            } else {
                numberList
            }
        }
    }

    private var backHeader: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(RMotion.panel) { step = .city }
            } label: {
                Image(systemName: RIcon.back)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.text2)
                    .frame(width: 34, height: 34)
                    .background(theme.chipBg, in: .circle)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text("Pick your number")
                    .font(RFont.display(19, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(theme.text)
                if let label = cityLabel {
                    Text(label)
                        .font(RFont.text(12))
                        .foregroundStyle(theme.text2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// Real rows at the real height, so the list does not jump when it fills.
    /// A spinner in the middle of an empty screen gives no sense of what is
    /// coming; these do.
    private var numberSkeleton: some View {
        VStack(spacing: 8) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 16)
                    .fill(theme.elev)
                    .frame(height: 58)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(theme.chipBg)
                            .frame(width: 150, height: 15)
                            .padding(.leading, 16)
                    }
                    .opacity(1 - Double(i) * 0.15)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .transition(.opacity)
    }

    private var numberList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(Array(state.lineOffers.enumerated()), id: \.element.id) { i, offer in
                    numberRow(offer, index: i)
                }

                Button {
                    Task { await state.loadLineNumbers(using: LineAPI(client: api)) }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: RIcon.refresh)
                            .font(.system(size: 12, weight: .semibold))
                        Text("Show different numbers")
                            .font(RFont.text(13, weight: .medium))
                    }
                    .foregroundStyle(theme.text2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                .disabled(state.isLoadingLineNumbers)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 120)
        }
    }

    private func numberRow(_ offer: LineNumberOffer, index: Int) -> some View {
        Button {
            state.lineOffer = offer
            state.intent = .line
            state.flow = .lineCheckout
        } label: {
            HStack(spacing: 12) {
                Text(PhoneFormat.national(offer.phoneNumber))
                    .font(RFont.mono(17, weight: .medium))
                    .foregroundStyle(theme.text)
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: RIcon.chev)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.text3)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 19)
            .background(theme.elev, in: .rect(cornerRadius: 16))
            .contentShape(.rect)
        }
        .buttonStyle(PressScaleStyle())
    }

    // MARK: - Nothing to sell

    /// Three causes, and we only ever know one of them.
    ///
    /// `paused` is something the server told us and can be stated outright. An
    /// empty search is an observation about ONE city and nothing more — and a
    /// failed fetch looks identical from here, which is why the third case
    /// claims no reason at all. Same discipline as
    /// `EsimStoreScreen.emptyCatalog`.
    private var unavailable: some View {
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
            GhostButton(label: "Try another city", fillsWidth: false) {
                withAnimation(RMotion.panel) { step = .city }
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
    }

    private var unavailableTitle: LocalizedStringKey {
        switch state.lineUnavailableReason {
        case .paused:  "Second numbers are unavailable"
        case .noStock: "No numbers here right now"
        default:       "We couldn't load any numbers"
        }
    }

    private var unavailableBody: LocalizedStringKey {
        switch state.lineUnavailableReason {
        case .paused:  "We've paused new numbers while we make some improvements. Check back soon."
        case .noStock: "Stock moves through the day. Another city will have some."
        default:       "Check your connection and try again."
        }
    }

    private var cityLabel: String? {
        state.lineCities.first { $0.id == state.lineCity }?.label
    }

    // MARK: - Chrome

    private func header(kicker: LocalizedStringKey, title: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(kicker).font(RFont.text(13)).foregroundStyle(theme.text2)
            Text(title)
                .font(RFont.display(28, weight: .bold))
                .tracking(-0.7).foregroundStyle(theme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }

    private var usSoon: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "flag")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.text2)
                .padding(.top, 2)
            Text("US numbers are coming soon. A Canadian number works with US and Canadian phones today.")
                .font(RFont.text(12))
                .foregroundStyle(theme.text2)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

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
