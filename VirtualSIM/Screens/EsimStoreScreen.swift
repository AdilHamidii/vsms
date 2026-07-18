import SwiftUI

/// cc "AT" -> 🇦🇹
func flagEmoji(_ cc: String) -> String {
    let base: UInt32 = 127397
    var s = ""
    for u in cc.uppercased().unicodeScalars where u.value >= 65 && u.value <= 90 {
        if let sc = Unicode.Scalar(base + u.value) { s.unicodeScalars.append(sc) }
    }
    return s.isEmpty ? "🌐" : s
}

struct EsimStoreScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    var openCredits: () -> Void

    private enum Seg: String, CaseIterable { case store = "Store", mine = "My eSIMs" }
    @State private var seg: Seg = .store
    @State private var query = ""

    private var countries: [(code: String, name: String, from: Int)] {
        let all = state.esimCountries
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                segmented
                if seg == .store { storeList } else { myEsims }
            }
            .background(theme.bg)
            .navigationBarHidden(true)
        }
        .task {
            await state.loadEsimCatalog(using: EsimPlansAPI(client: api))
            await state.loadEsimOrders(using: EsimOrdersAPI(client: api))
        }
    }

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

    private var segmented: some View {
        HStack(spacing: 6) {
            ForEach(Seg.allCases, id: \.self) { s in
                Button { withAnimation(.easeOut(duration: 0.15)) { seg = s } } label: {
                    Text(s.rawValue)
                        .font(RFont.display(14, weight: .semibold)).tracking(-0.2)
                        .foregroundStyle(seg == s ? theme.onInk : theme.text2)
                        .padding(.vertical, 8).frame(maxWidth: .infinity)
                        .background(seg == s ? theme.ink : theme.chipBg, in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
    }

    private var storeList: some View {
        ScrollView {
            if !state.esimPlans.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: RIcon.search).font(.system(size: 14)).foregroundStyle(theme.text3)
                    TextField("Search countries", text: $query)
                        .font(RFont.text(15)).foregroundStyle(theme.text)
                }
                .padding(.horizontal, 14).frame(height: 44)
                .background(theme.chipBg, in: .rect(cornerRadius: 12))
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
            Card {
                LazyVStack(spacing: 0) {
                    ForEach(Array(countries.enumerated()), id: \.element.code) { idx, c in
                        NavigationLink { EsimCountryPlans(code: c.code, name: c.name) } label: {
                            HStack(spacing: 12) {
                                Text(flagEmoji(c.code)).font(.system(size: 26))
                                Text(c.name).font(RFont.display(16, weight: .semibold)).tracking(-0.3).foregroundStyle(theme.text)
                                Spacer(minLength: 0)
                                Text("from \(c.from) cr").font(RFont.text(13, weight: .medium)).foregroundStyle(theme.text2)
                                Image(systemName: RIcon.chev).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text3)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 12).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        if idx != countries.count - 1 {
                            Rectangle().fill(theme.sep).frame(height: 0.5).padding(.leading, 52)
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 140)
        }
        .scrollIndicators(.hidden)
    }

    private var myEsims: some View {
        ScrollView {
            if state.esimOrders.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "simcard").font(.system(size: 34)).foregroundStyle(theme.text3)
                    Text("No eSIMs yet").font(RFont.display(17, weight: .semibold)).foregroundStyle(theme.text)
                    Text("Buy a data plan to get an eSIM you can install in seconds.")
                        .font(RFont.text(13)).foregroundStyle(theme.text2).multilineTextAlignment(.center)
                }
                .padding(.top, 60).padding(.horizontal, 40)
            } else {
                Card {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(state.esimOrders.enumerated()), id: \.element.id) { idx, o in
                            Button { state.openEsimDetail(o) } label: { EsimOrderRow(order: o) }
                                .buttonStyle(.plain)
                            if idx != state.esimOrders.count - 1 {
                                Rectangle().fill(theme.sep).frame(height: 0.5).padding(.leading, 52)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 140)
            }
        }
        .scrollIndicators(.hidden)
    }
}

private struct EsimOrderRow: View {
    @Environment(\.theme) private var theme
    let order: EsimOrder
    var body: some View {
        HStack(spacing: 12) {
            Text(flagEmoji(order.plan?.countryCode ?? "")).font(.system(size: 24))
            VStack(alignment: .leading, spacing: 2) {
                Text(order.name).font(RFont.display(15, weight: .semibold)).foregroundStyle(theme.text)
                Text("\(order.plan?.dataLabel ?? "") · \(order.status.label)")
                    .font(RFont.text(12)).foregroundStyle(theme.text2)
            }
            Spacer(minLength: 0)
            if order.dataTotalMb != nil {
                Text(order.dataRemainingLabel).font(RFont.mono(12, weight: .medium)).foregroundStyle(theme.text2)
            }
            Image(systemName: RIcon.chev).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text3)
        }
        .padding(.horizontal, 14).padding(.vertical, 12).contentShape(.rect)
    }
}

/// Drill-down: the data-plan tiers for one country.
private struct EsimCountryPlans: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    let code: String
    let name: String

    var body: some View {
        ScrollView {
            Card {
                LazyVStack(spacing: 0) {
                    let plans = state.esimPlans(forCountry: code)
                    ForEach(Array(plans.enumerated()), id: \.element.id) { idx, p in
                        Button { state.startEsimCheckout(p) } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.dataLabel).font(RFont.display(16, weight: .semibold)).foregroundStyle(theme.text)
                                    Text("\(p.validityLabel) · \(p.speed ?? "")").font(RFont.text(12)).foregroundStyle(theme.text2)
                                }
                                Spacer(minLength: 0)
                                if let cr = p.retailCredits {
                                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                                        Text("\(cr)").font(RFont.display(16, weight: .semibold)).foregroundStyle(theme.text)
                                        Text("cr").font(RFont.text(12, weight: .medium)).foregroundStyle(theme.text2)
                                    }
                                }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 14).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        if idx != plans.count - 1 {
                            Rectangle().fill(theme.sep).frame(height: 0.5)
                        }
                    }
                }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .background(theme.bg)
        .navigationTitle("\(flagEmoji(code)) \(name)")
        .navigationBarTitleDisplayMode(.inline)
    }
}
