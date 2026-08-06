import SwiftUI

struct EsimStoreScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    var openCredits: () -> Void

    private enum Seg: Hashable { case store, mine, activity }
    private enum Browse: Hashable { case map, list }

    @State private var seg: Seg = .store
    @State private var browse: Browse = .map
    @State private var query = ""
    @State private var appeared = false
    @State private var destination: EsimCountryEntry?

    private var countries: [EsimCountryEntry] {
        let all = state.esimCountries
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                SegmentedTabs(selection: $seg, items: [
                    (.store, String(localized: "Store"), nil),
                    (.mine, String(localized: "My eSIMs"),
                     state.liveEsimOrders.isEmpty ? nil : state.liveEsimOrders.count),
                    (.activity, String(localized: "Activity"), nil),
                ])
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)

                // A plain if/else swaps content with no motion at all, which on
                // a segmented control reads as a screen flash. The asymmetric
                // slide follows the direction the segment moved.
                // No blanket `.animation` here either — `SegmentedTabs` already
                // wraps its selection change in `withAnimation`, which the
                // transitions below pick up. Adding one would additionally
                // animate the MapKit view nested inside `store`.
                ZStack {
                    switch seg {
                    case .store:    store.transition(.opacity)
                    case .mine:     mine.transition(.opacity)
                    case .activity: EsimActivityScreen().transition(.opacity)
                    }
                }
            }
            .background(theme.bg)
            .navigationBarHidden(true)
            .navigationDestination(item: $destination) { entry in
                EsimCountryPlansScreen(entry: entry, openCredits: openCredits)
            }
        }
        .task {
            // Switching tabs destroys and rebuilds this view, so this `.task`
            // runs on EVERY visit — and cold start already fetched the catalog.
            // Refetching 1,081 plans each time the user taps the eSIM tab is
            // pure latency on a screen that then has to lay out a map. Orders
            // are a handful of rows and DO refresh, since the user may have
            // bought one since they last looked.
            if state.esimPlans.isEmpty {
                await state.loadEsimCatalog(using: EsimPlansAPI(client: api))
            }
            await state.loadEsimOrders(using: EsimOrdersAPI(client: api))
            withAnimation(RMotion.content) { appeared = true }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Data plans")
                    .font(RFont.text(13)).foregroundStyle(theme.text2)
                Text("Travel eSIMs")
                    .font(RFont.display(28, weight: .bold)).tracking(-0.7).foregroundStyle(theme.text)
            }
            Spacer()
            CreditPill(value: state.balance, action: openCredits)
        }
        .padding(.horizontal, 20).padding(.top, 6)
    }

    // MARK: - Store

    /// An empty catalog must SAY it is empty. A search field, a map/list toggle
    /// and an empty country list render as a near-blank screen, and blankness
    /// reads as "this app is broken" rather than "there is nothing on sale" —
    /// the same silence-reads-as-fine failure the delivery badges were rebuilt
    /// to avoid.
    private var store: some View {
        Group {
            if state.esimPlans.isEmpty { emptyCatalog } else { catalogBrowser }
        }
    }

    /// Two different messages, because an empty catalog has two very different
    /// causes and only ONE of them is something we know.
    ///
    /// When the server says the line is paused (`app_config.esim_paused`, set by
    /// `set_esim_paused()`), we can state it outright. When the catalog is
    /// merely empty — a failed fetch looks identical — we say only what is
    /// observable and claim no reason. Asserting "we're switching providers"
    /// off an empty array would be a guess presented as fact, which is the same
    /// error as rendering a seeded success rate as a measurement.
    ///
    /// Both branches can honestly say bought eSIMs are unaffected: they are
    /// provisioned on the device and their usage is read from the order row,
    /// not from this catalog.
    private var emptyCatalog: some View {
        VStack(spacing: 8) {
            Image(systemName: state.esimPaused ? "pause.circle" : "globe")
                .font(.system(size: 34)).foregroundStyle(theme.text3)
            Text(state.esimPaused
                 ? "eSIMs are unavailable right now"
                 : "No data plans right now")
                .font(RFont.display(17, weight: .semibold)).foregroundStyle(theme.text)
                .multilineTextAlignment(.center)
            Text(state.esimPaused
                 ? "We've paused data plans while we make some improvements. Any eSIM you already bought keeps working. Find it under My eSIMs."
                 : "Travel eSIMs are temporarily off sale. Any eSIM you already bought keeps working. Find it under My eSIMs.")
                .font(RFont.text(13)).foregroundStyle(theme.text2)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var catalogBrowser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: RIcon.search)
                        .font(.system(size: 14)).foregroundStyle(theme.text3)
                    TextField("Search countries", text: $query)
                        .font(RFont.text(15)).foregroundStyle(theme.text)
                        .submitLabel(.search)
                    if !query.isEmpty {
                        Button { withAnimation(RMotion.content) { query = "" } } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14)).foregroundStyle(theme.text3)
                        }
                        .buttonStyle(.plain)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 12).frame(height: 40)
                .background(theme.chipBg, in: .rect(cornerRadius: 12))

                browseToggle
            }
            .padding(.horizontal, 16).padding(.bottom, 10)

            // A search query is a list action — the user typed a name, so show
            // named rows. Staying on the map would answer a text search with a
            // silent camera move the user cannot see the result of.
            // NOTE: no `.animation(_:value:)` on this container.
            //
            // A blanket animation modifier here applies to every descendant —
            // including the MapKit view — so an unrelated state change made
            // SwiftUI animate the map's own layout. The crossfade is expressed
            // by the transitions instead, scoped to the two branches that
            // actually swap.
            if browse == .map && query.isEmpty {
                EsimMapView(countries: countries) { entry in destination = entry }
                    .transition(.opacity)
            } else {
                countryList.transition(.opacity)
            }
        }
    }

    private var browseToggle: some View {
        HStack(spacing: 0) {
            ForEach([Browse.map, Browse.list], id: \.self) { b in
                let active = browse == b
                Button {
                    withAnimation(RMotion.select) { browse = b }
                } label: {
                    Image(systemName: b == .map ? "map" : "list.bullet")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(active ? theme.text : theme.text3)
                        .frame(width: 38, height: 34)
                        .background(active ? theme.elev : .clear, in: .rect(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(b == .map ? "Map view" : "List view")
            }
        }
        .padding(3)
        .background(theme.chipBg, in: .rect(cornerRadius: 12))
    }

    private var countryList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(Array(countries.enumerated()), id: \.element.id) { idx, c in
                    Button { destination = c } label: { countryRow(c) }
                        .pressableCard()
                        .riseIn(appeared, index: idx)
                }
                if countries.isEmpty && !query.isEmpty {
                    Text("No country matches “\(query)”.")
                        .font(RFont.text(13)).foregroundStyle(theme.text2)
                        .padding(.top, 50)
                }
                Color.clear.frame(height: 130)
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }

    private func countryRow(_ c: EsimCountryEntry) -> some View {
        HStack(spacing: 12) {
            CodeFlag(code: c.code, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.name)
                    .font(RFont.display(16, weight: .semibold)).tracking(-0.3)
                    .foregroundStyle(theme.text)
                Text(c.planCount == 1 ? "1 plan" : "\(c.planCount) plans")
                    .font(RFont.text(11)).foregroundStyle(theme.text3)
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("from").font(RFont.text(11)).foregroundStyle(theme.text3)
                Text("\(c.fromCredits)")
                    .font(RFont.display(16, weight: .semibold)).foregroundStyle(theme.text)
                Text("cr").font(RFont.text(11, weight: .medium)).foregroundStyle(theme.text2)
            }
            Image(systemName: RIcon.chev)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text3)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(theme.elev, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.sep, lineWidth: 0.5))
        .contentShape(.rect)
    }

    // MARK: - My eSIMs

    private var mine: some View {
        ScrollView {
            if state.liveEsimOrders.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "simcard")
                        .font(.system(size: 34)).foregroundStyle(theme.text3)
                    Text("No active eSIMs")
                        .font(RFont.display(17, weight: .semibold)).foregroundStyle(theme.text)
                    Text("Buy a data plan to get an eSIM you can install in seconds.")
                        .font(RFont.text(13)).foregroundStyle(theme.text2)
                        .multilineTextAlignment(.center)
                    Button { withAnimation(RMotion.select) { seg = .store } } label: {
                        Text("Browse plans")
                            .font(RFont.display(14, weight: .semibold))
                            .foregroundStyle(theme.onInk)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(theme.ink, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                }
                .padding(.top, 60).padding(.horizontal, 40)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(state.liveEsimOrders.enumerated()), id: \.element.id) { idx, o in
                        Button { state.openEsimDetail(o) } label: { liveCard(o) }
                            .pressableCard()
                            .riseIn(appeared, index: idx)
                    }
                    Color.clear.frame(height: 130)
                }
                .padding(.horizontal, 16).padding(.top, 4)
            }
        }
        .scrollIndicators(.hidden)
    }

    private func liveCard(_ o: EsimOrder) -> some View {
        HStack(spacing: 14) {
            DataRing(usedMb: o.dataUsedMb, totalMb: o.dataTotalMb, size: 74, lineWidth: 7)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    CodeFlag(code: o.plan?.countryCode ?? "", size: 20)
                    Text(o.name)
                        .font(RFont.display(16, weight: .semibold)).tracking(-0.3)
                        .foregroundStyle(theme.text)
                }
                Text("\(o.plan?.dataLabel ?? "—") · \(o.plan?.validityLabel ?? "—")")
                    .font(RFont.text(12)).foregroundStyle(theme.text2)
                StatusChip(status: o.status)
            }
            Spacer(minLength: 0)
            Image(systemName: RIcon.chev)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text3)
        }
        .padding(14)
        .background(theme.elev, in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(theme.sep, lineWidth: 0.5))
        .contentShape(.rect)
    }
}

/// Small status pill for an eSIM. Colour matches the semantics used everywhere
/// else — `theme.live` is success, never decoration.
private struct StatusChip: View {
    @Environment(\.theme) private var theme
    let status: EsimStatus

    private var tint: Color {
        switch status {
        case .active, .installed: theme.live
        case .provisioning:       theme.text2
        case .depleted, .expired: theme.warn
        case .failed:             theme.fail
        case .refunded:           theme.text2
        }
    }

    var body: some View {
        Text(status.label)
            .font(RFont.text(10, weight: .semibold)).tracking(0.2)
            .foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(tint.opacity(0.12), in: .capsule)
    }
}
