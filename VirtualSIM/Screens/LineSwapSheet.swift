import SwiftUI

/// "Change number" — pick a new place and number for a line you already rent,
/// then pay for it in credits. Presented from `LineSwitchNumberButton`.
///
/// ── Choose first, pay last (owner decision 2026-09-05) ─────────────────────
///
/// The button used to read "Switch number · 8 credits" and, on confirm, bought
/// the first free number in the old area code. That put the price before the
/// product, made the swap a blind reroll, and — because the button never read
/// the wallet — invited a tap the server then refused: the first real
/// complaint was a 402 `insufficient_credits` on a 6-credit wallet, which the
/// user reported as "changing my number doesn't work".
///
/// Now the order is country → city → number, in the same rows the store uses,
/// and only the LAST page names the price, shows the balance, and either
/// switches or sends the user to top up. Nothing is offered that the server
/// would refuse for money.
///
/// ── State ─────────────────────────────────────────────────────────────────
///
/// The search runs through the Number tab's own state (`lineCountries`,
/// `lineCities`, `lineOffers`, `lineCountry`, `lineCity`) via the same
/// `AppState` loaders the store calls, so "search here" has one definition.
/// The picked offer is LOCAL: `state.lineOffer` feeds the store's checkout and
/// must not be left pointing at a swap candidate. The presenter clears the
/// whole draft on dismiss (`clearLineDraft`).
///
/// ── Country changes ───────────────────────────────────────────────────────
///
/// A different country is allowed; the server treats it as a new sale and
/// gates it on sellability, so the picker only ever lists what the catalogue
/// marks available. The ONE thing this screen must say either way is that the
/// old number is gone for good — `warning`, on the confirm page, above the
/// button.
struct LineSwapSheet: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    @Environment(IAPStore.self) private var iap
    @Environment(\.dismiss) private var dismiss

    let line: Line
    /// `app_config.line_swap_credits`, read live by the presenter. Never a
    /// client default — the presenter hides the button when it is nil, so this
    /// screen is never shown without a real price.
    let cost: Int
    /// Called with the new number once the cutover has landed and the user
    /// taps Done, so the presenter can confirm it under the button.
    var onSwapped: (String) -> Void

    private enum Page: Equatable {
        case numbers, countries, cities
        case confirm(LineNumberOffer)
        case done(String)
    }

    @State private var page: Page = .numbers
    @State private var swapping = false
    @State private var showCredits = false
    /// Rendered INLINE. `state.showError` drives the root banner, which draws
    /// underneath a sheet — the same trap `InCallOverlay` hit under the dialer
    /// cover — so an error raised from here would be invisible until dismiss.
    @State private var errorText: String?

    private var shortfall: Int { max(0, cost - state.balance) }
    private var affordable: Bool { shortfall == 0 }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: title)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let errorText {
                        inlineError(errorText)
                    }
                    content
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
        }
        .background(theme.bg)
        .task { await loadInitial() }
        .sheet(isPresented: $showCredits) {
            CreditsSheet(balance: state.balance, needed: shortfall) {
                await state.refreshWallet(using: WalletAPI(client: api))
                if let n = iap.lastGrantedCredits, n > 0 {
                    state.creditPurchaseBanner = n
                }
            }
            // Sheet content does not inherit `@Observable` environment
            // objects from its presenter — `IAPStore` in particular is a
            // crash on presentation, not a blank screen.
            .environment(\.theme, theme)
            .environment(state)
            .environment(api)
            .environment(iap)
            .presentationDragIndicator(.visible)
            .presentationBackground(theme.bg)
        }
    }

    private var title: String {
        switch page {
        case .numbers:   String(localized: "Choose your new number")
        case .countries: String(localized: "Where should it be?")
        case .cities:    String(localized: "Which city?")
        case .confirm:   String(localized: "Confirm your new number")
        case .done:      String(localized: "Number changed")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .numbers:              numbersPage
        case .countries:            countriesPage
        case .cities:               citiesPage
        case .confirm(let offer):   confirmPage(offer)
        case .done(let number):     donePage(number)
        }
    }

    // MARK: - Numbers

    private var numbersPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            // What is being replaced, so the list below is read as
            // alternatives to something rather than a store.
            Text("Replacing \(PhoneFormat.national(line.e164))")
                .font(RFont.text(13))
                .foregroundStyle(theme.text2)
                .padding(.bottom, 2)

            HStack(spacing: 12) {
                if let place = state.linePlaceLabel {
                    MicroLabel("Available now in \(place)")
                } else {
                    MicroLabel("Available now")
                }
                Spacer(minLength: 0)
                GhostButton(label: "Change", fillsWidth: false) {
                    page = state.lineCountries.offersCountryChoice ? .countries : .cities
                }
            }

            if state.isLoadingLineNumbers, state.lineOffers.isEmpty {
                LineOfferSkeleton(rows: 4)
            } else if state.lineOffers.isEmpty {
                unavailable
            } else {
                VStack(spacing: 8) {
                    ForEach(state.lineOffers, id: \.id) { offer in
                        LineOfferRow(offer: offer) { pick(offer) }
                    }
                    GhostButton(label: "Show different numbers",
                                icon: RIcon.refresh,
                                fillsWidth: false) {
                        Task { await reload() }
                    }
                    .disabled(state.isLoadingLineNumbers)
                    .opacity(state.isLoadingLineNumbers ? 0.5 : 1)
                    .padding(.top, 6)
                }
            }
        }
    }

    private var unavailable: some View {
        EmptyState(
            icon: state.lineUnavailableReason == .paused
                  ? "pause.circle" : "phone.badge.waveform",
            title: LineUnavailableCopy.title(for: state.lineUnavailableReason),
            message: LineUnavailableCopy.body(for: state.lineUnavailableReason),
            tint: state.lineUnavailableReason == nil ? theme.fail : nil,
            // A refused COUNTRY cannot be fixed by another city.
            secondary: (label: state.lineUnavailableReason == .countryNotSellable
                        ? String(localized: "Try another country")
                        : String(localized: "Try another city"),
                        action: {
                            let wantsCountries =
                                state.lineUnavailableReason == .countryNotSellable
                                && state.lineCountries.offersCountryChoice
                            page = wantsCountries ? .countries : .cities
                        }))
        .padding(.top, 12)
    }

    // MARK: - Place

    private var countriesPage: some View {
        let rows = state.lineCountries.pickerOrder
        return Card(elevation: .flat) {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, country in
                    LineCountryRow(country: country) { select(country) }
                    if i < rows.count - 1 { RowRule(inset: 16) }
                }
            }
        }
    }

    @ViewBuilder
    private var citiesPage: some View {
        if state.lineCities.isEmpty {
            // A country with no curated localities sells country-wide, and an
            // empty list mid-load must not render as "nowhere".
            if state.isLoadingLineNumbers {
                LinePickerRowSkeleton()
            } else {
                LineCountryWideRow(countryLabel: state.linePlaceCountryLabel) {
                    page = .numbers
                    Task { await reload() }
                }
            }
        } else {
            Card(elevation: .flat) {
                VStack(spacing: 0) {
                    ForEach(Array(state.lineCities.enumerated()), id: \.element.id) { i, city in
                        LineCityRow(city: city) {
                            page = .numbers
                            Task { await reload(city: city.id) }
                        }
                        if i < state.lineCities.count - 1 { RowRule(inset: 16) }
                    }
                }
            }
        }
    }

    /// Picking a country invalidates everything downstream — the city list,
    /// the offers — all describe the PREVIOUS country. Cleared first, loaded
    /// second; the page moves to that country's cities meanwhile.
    private func select(_ country: LineCountry) {
        state.lineCountry = country.countryCode
        state.lineCity = nil
        state.lineCities = []
        state.lineOffers = []
        state.lineOffer = nil
        state.lineReservation = nil
        state.lineUnavailableReason = nil
        page = .cities
        Task { await reload(country: country.countryCode) }
    }

    // MARK: - Confirm

    private func confirmPage(_ offer: LineNumberOffer) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(elevation: .raised) {
                VStack(spacing: 0) {
                    numberLine(label: String(localized: "Current"),
                               e164: line.e164, muted: true)
                    RowRule(inset: 16)
                    numberLine(label: String(localized: "New"),
                               e164: offer.phoneNumber, muted: false)
                }
            }

            // The paywall, last. Both figures come from the server: the price
            // is `app_config.line_swap_credits` and the balance is the wallet.
            Card(radius: RRadius.md, elevation: .flat) {
                VStack(spacing: 0) {
                    figureRow(label: String(localized: "Price"),
                              value: String(localized: "\(cost) credits"))
                    RowRule(inset: 16)
                    figureRow(label: String(localized: "Your balance"),
                              value: String(localized: "\(state.balance) credits"),
                              tint: affordable ? nil : theme.warn)
                }
            }

            warning

            if affordable {
                PrimaryButton(label: swapping
                              ? String(localized: "Getting your new number…")
                              : String(localized: "Switch to \(PhoneFormat.national(offer.phoneNumber))"),
                              icon: "arrow.triangle.2.circlepath",
                              disabled: swapping) {
                    RHaptic.select()
                    Task { await perform(offer) }
                }
            } else {
                Text("You need \(shortfall) more credits to switch.")
                    .font(RFont.text(13))
                    .foregroundStyle(theme.text2)
                PrimaryButton(label: String(localized: "Top up · \(shortfall) more credits"),
                              icon: "plus.circle") {
                    RHaptic.select()
                    Analytics.shared.track("line_swap_topup_shown",
                                           ["shortfall": .int(shortfall)])
                    showCredits = true
                }
            }

            GhostButton(label: "Pick a different number") {
                errorText = nil
                page = .numbers
            }
            .disabled(swapping)
        }
        .padding(.top, 4)
        .task(id: page) {
            Analytics.shared.track("line_swap_confirm_view", [
                "affordable": .bool(affordable),
                "changed_country": .bool((state.lineCountry ?? line.countryCode) != line.countryCode),
            ])
        }
    }

    private func numberLine(label: String, e164: String, muted: Bool) -> some View {
        HStack(spacing: 13) {
            PeerAvatar(e164: e164, size: 42)
                .opacity(muted ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: label)
                    .font(RFont.text(11, weight: .semibold))
                    .foregroundStyle(theme.text3)
                    .textCase(.uppercase)
                Text(PhoneFormat.national(e164))
                    .font(RFont.mono(18, weight: .medium))
                    .foregroundStyle(muted ? theme.text2 : theme.text)
                    .strikethrough(muted, color: theme.text3)
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func figureRow(label: String, value: String, tint: Color? = nil) -> some View {
        HStack {
            Text(verbatim: label)
                .font(RFont.text(14))
                .foregroundStyle(theme.text2)
            Spacer(minLength: 8)
            Text(verbatim: value)
                .font(RFont.display(15, weight: .semibold))
                .foregroundStyle(tint ?? theme.text)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// The one fact that has to survive being skim-read: the current number is
    /// gone for good. A released number goes into a hold-then-aging path nobody
    /// can pull it back from. Anyone still receiving codes on it must be told
    /// BEFORE they tap, not after. Same amber caution surface as the store's
    /// voice-only notice and checkout's emergency block.
    private var warning: some View {
        Card(radius: RRadius.md, elevation: .flat,
             fill: theme.warnSoft, border: theme.warn.opacity(0.28)) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.warn)
                    .padding(.top, 1)
                Text("\(PhoneFormat.national(line.e164)) is given up for good — you can't get it back, and anything still sending codes to it won't reach you.")
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

    private func inlineError(_ text: String) -> some View {
        Card(radius: RRadius.md, elevation: .flat,
             fill: theme.failSoft, border: theme.fail.opacity(0.28)) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.fail)
                    .padding(.top, 1)
                Text(verbatim: text)
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

    // MARK: - Done

    private func donePage(_ number: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(elevation: .raised) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 13) {
                        PeerAvatar(e164: number, size: 42)
                        Text(PhoneFormat.national(number))
                            .font(RFont.mono(20, weight: .medium))
                            .foregroundStyle(theme.text)
                            .minimumScaleFactor(0.8)
                            .lineLimit(1)
                    }
                    Text("This is your number now. Share it wherever you used the old one — codes sent to the old number won't reach you.")
                        .font(RFont.text(13))
                        .foregroundStyle(theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            PrimaryButton(label: String(localized: "Done"), icon: "checkmark") {
                onSwapped(number)
                dismiss()
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Data

    private func loadInitial() async {
        Analytics.shared.track("line_swap_open")
        // The country catalogue first: whether a country list is worth showing
        // is a question only it can answer. Swallows its own failure and keeps
        // the seeded set — see `AppState.loadLineCountries`.
        await state.loadLineCountries(using: LineAPI(client: api))
        // Start where the line already is. The user changes it from here if
        // they want to; a swap that silently opened on another country would
        // be the country change nobody asked for.
        state.lineCountry = line.countryCode
        state.lineCity = nil
        state.lineOffers = []
        state.lineOffer = nil
        state.lineUnavailableReason = nil
        await reload(country: line.countryCode)
    }

    /// Every search this sheet runs goes through here, so the funnel event
    /// cannot drift away from the thing it claims to measure.
    private func reload(city: String? = nil, country: String? = nil) async {
        await state.loadLineNumbers(using: LineAPI(client: api),
                                    city: city, country: country)
        Analytics.shared.track("line_swap_numbers_shown", [
            "country": .string(state.lineCountry ?? "unknown"),
            "city": .string(state.lineCity ?? "any"),
            "count": .int(state.lineOffers.count)])
    }

    private func pick(_ offer: LineNumberOffer) {
        RHaptic.select()
        errorText = nil
        Analytics.shared.track("line_swap_number_picked", [
            "country": .string(offer.countryCode ?? state.lineCountry ?? "unknown")])
        page = .confirm(offer)
    }

    /// Buy the chosen number for this line.
    ///
    /// `swapping` is the re-entrancy guard as well as the button's busy state.
    /// Reloading the line afterwards is not cosmetic: every other surface —
    /// the header, the share sheet, the thread list — reads `state.line`, so
    /// skipping it leaves the whole tab showing a number we just gave away.
    @MainActor
    private func perform(_ offer: LineNumberOffer) async {
        guard !swapping else { return }
        swapping = true
        errorText = nil
        defer { swapping = false }

        let country = state.lineCountry ?? line.countryCode
        do {
            let result = try await LineAPI(client: api).swapNumber(
                lineId: line.id, phoneNumber: offer.phoneNumber,
                country: country, city: state.lineCity)
            await state.loadLine(using: LineAPI(client: api))
            // The wallet moved, and the credits pill reads AppState.
            await state.refreshWallet(using: WalletAPI(client: api))
            RHaptic.success()
            Analytics.shared.track("line_swap_result", [
                "outcome": .string("success"),
                "changed_country": .bool(country != line.countryCode)])
            page = .done(result.phoneNumber)
        } catch let error as APIError {
            // Every failure path server-side refunds before returning, so the
            // message is the whole story — there is no "and you were charged"
            // case to explain.
            errorText = error.userMessage
            Analytics.shared.track("line_swap_result", [
                "outcome": .string("failed"),
                "changed_country": .bool(country != line.countryCode)])
            // Somebody else took it between the search and the tap. The list
            // is stale by definition, so go back to it with fresh stock rather
            // than leaving a dead number on the confirm page.
            if case .http(_, let body) = error,
               (body ?? "").contains("\"number_taken\"") {
                page = .numbers
                await reload()
            }
        } catch {
            errorText = APIError.badResponse.userMessage
        }
    }
}
