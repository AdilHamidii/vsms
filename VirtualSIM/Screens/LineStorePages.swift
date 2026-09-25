import SwiftUI

/// The store's two search entry points, shared by the store root and the
/// pushed place pages so `line_numbers_shown` / `line_place_changed` cannot
/// drift from what they measure.
@MainActor
enum LineStoreSearch {
    /// Every search the store runs. `line_numbers_shown` fires on the RESULT.
    ///
    /// ⚠️ SEMANTICS CHANGED with the inline list (2026-09-24): on `main` this
    /// event meant "the reader opened the picker"; here it fires whenever the
    /// store renders a fresh search (every visit that searches). `source`
    /// marks the new series; do not compare it with main's.
    ///
    /// 🔴 THE ONE SESSION GUARD. `search-line-numbers` needs a user, and every
    /// path into a search — the visit, the country control, the Cities page,
    /// "Show different numbers", Try again — ends here, so a guest (a later
    /// plan) never searches and never sees a 401 rendered as "We couldn't load
    /// any numbers". No event fires for a search that did not run.
    static func reload(_ state: AppState, api: APIClient,
                       city: String? = nil, country: String? = nil) async {
        guard api.hasSession else { return }
        await state.loadLineNumbers(using: LineAPI(client: api), city: city, country: country)
        Analytics.shared.track("line_numbers_shown", [
            "country": .string(state.lineCountry ?? "unknown"),
            // "any" is a real answer — a country with no curated localities
            // sells country-wide — and must not read as a missing one.
            "city": .string(state.lineCity ?? "any"),
            "count": .int(state.lineOffers.count),
            "source": .string("store_inline")])
    }

    /// Once per VISIT to the store: `line_store_view`, the price, the country
    /// catalogue, the default country and the first search.
    ///
    /// A visit is an appearance of the store's HOST, never of the store view:
    /// the My number tab's `NavigationStack` while its root is the store
    /// (`LineScreen`, keyed on that root), or one presentation of
    /// `LineStoreCover`. Pushing a place page does not make the host
    /// disappear, so a push and its pop are not visits. (The store root's own
    /// `.task` DID re-run on every pop, and a push cancelled a search in
    /// flight, which rendered as the fail-tinted "We couldn't load any
    /// numbers".)
    ///
    /// The work runs in UNSTRUCTURED tasks, so nothing on screen can cancel
    /// it. A visit that ended before the catalogue answered (the tab was left)
    /// does not go on to search.
    static func beginVisit(_ state: AppState, api: APIClient, subs: SubscriptionStore) {
        Analytics.shared.track("line_store_view")
        Task { await subs.loadProduct() }   // warms the paywall's price; idempotent
        Task {
            await state.loadLineCountries(using: LineAPI(client: api))
            guard state.tab == .line else { return }   // the visit is over
            if state.lineCountry == nil,
               let iso = LineStoreScreen.defaultCountry(in: state.lineCountries.sellable) {
                state.lineCountry = iso
            }
            // Screenshot frames seed the offers themselves; a live search from
            // `simctl` would wipe them. Leaving the tab clears the draft, so
            // the next visit searches again.
            guard !ScreenshotMode.isActive,
                  state.lineOffers.isEmpty, !state.isLoadingLineNumbers else { return }
            await reload(state, api: api)
        }
    }

    /// One definition of "the user chose somewhere else".
    static func changePlace(_ state: AppState, api: APIClient,
                            city: String? = nil, country: String? = nil) {
        Analytics.shared.track("line_place_changed", [
            "country": .string(country ?? state.lineCountry ?? "unknown"),
            "city": .string(city ?? "any")])
        Task { await reload(state, api: api, city: city, country: country) }
    }

    /// A different country invalidates everything downstream: cleared first,
    /// loaded second, so Toronto never shows under a Polish flag.
    static func selectCountry(_ country: LineCountry, state: AppState, api: APIClient) {
        state.lineCountry = country.countryCode
        state.lineCity = nil
        state.lineCities = []
        state.lineOffers = []
        state.lineOffer = nil
        state.lineReservation = nil
        state.lineUnavailableReason = nil
        changePlace(state, api: api, country: country.countryCode)
    }
}

/// Every catalog country, pushed from the store's "Try another country".
/// Unsellable rows stay visible and gray ("Not available yet").
struct LineCountriesPage: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let rows = state.lineCountries.pickerOrder
        ScrollView {
            VStack(spacing: 0) {
                ForEach(rows) { country in
                    if country.id != rows.first?.id { RowRule(inset: RSpace.lg) }
                    LineCountryRow(country: country) {
                        RHaptic.select()
                        LineStoreSearch.selectCountry(country, state: state, api: api)
                        dismiss()
                    }
                }
            }
            .background(theme.elev, in: .rect(cornerRadius: RRadius.group, style: .continuous))
            .padding(.horizontal, RSpace.gutter)
            .padding(.vertical, RSpace.lg)
        }
        .background(theme.bg.ignoresSafeArea())
        .containerBackground(theme.bg, for: .navigation)
        .navigationTitle(Text("Where should it be?"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The current country's localities ("Other city ›"). A country with no
/// curated localities sells country-wide, and an empty list mid-load must
/// not render as "nowhere".
struct LineCitiesPage: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            Group {
                if state.lineCities.isEmpty {
                    if state.isLoadingLineNumbers {
                        LinePickerRowSkeleton()
                    } else {
                        LineCountryWideRow(countryLabel: state.linePlaceCountryLabel) {
                            choose(city: nil)
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(state.lineCities) { city in
                            if city.id != state.lineCities.first?.id { RowRule(inset: RSpace.lg) }
                            LineCityRow(city: city) { choose(city: city.id) }
                        }
                    }
                    .background(theme.elev, in: .rect(cornerRadius: RRadius.group, style: .continuous))
                }
            }
            .padding(.horizontal, RSpace.gutter)
            .padding(.vertical, RSpace.lg)
        }
        .background(theme.bg.ignoresSafeArea())
        .containerBackground(theme.bg, for: .navigation)
        .navigationTitle(Text("Which city?"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Back to the numbers, which reload behind the pop.
    private func choose(city: String?) {
        RHaptic.select()
        LineStoreSearch.changePlace(state, api: api, city: city)
        dismiss()
    }
}

/// "Rent another number" (`flow == .lineStoreMore`): the same store, as a
/// cover with its own stack so its place pages push inside the cover.
struct LineStoreCover: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    @Environment(SubscriptionStore.self) private var subs
    @State private var path: [LineRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            LineStoreScreen(onClose: { state.flow = nil },
                            push: { path.append($0) })
                .containerBackground(theme.bg, for: .navigation)
                .toolbar(.hidden, for: .navigationBar)
                .navigationTitle(Text("Your own number"))
                .lineRouteDestinations()
        }
        // One presentation of the cover is one visit; see `beginVisit`.
        .task { LineStoreSearch.beginVisit(state, api: api, subs: subs) }
    }
}
