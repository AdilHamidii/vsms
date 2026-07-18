import SwiftUI

struct ServiceSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state
    var onPick: (Service) -> Void

    @State private var query: String = ""
    @State private var category: String = "All"
    @State private var affordableOnly = false

    /// The country the user is currently configuring. While in checkout we use
    /// the draft country; otherwise the Home "Last used". Prices shown per
    /// service are the REAL synced route price for this country (mirrors
    /// CountrySheet, which fixes the service and varies the country).
    private var currentCountry: Country {
        state.checkoutCountry ?? state.lastCountry
    }

    private var filtered: [Service] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return state.services.filter { s in
            let matchesQuery = q.isEmpty
                || s.name.lowercased().contains(q)
                || s.category.lowercased().contains(q)
            let matchesCategory = (category == "All") || (s.category == category)
            return matchesQuery && matchesCategory && matchesAffordable(s)
        }
    }

    /// When the Affordable toggle is on, keep only services with a route in the
    /// current country the balance can actually buy.
    private func matchesAffordable(_ s: Service) -> Bool {
        guard affordableOnly else { return true }
        guard let c = state.cost(for: s, country: currentCountry) else { return false }
        return c <= state.balance
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Choose a service")
            searchField
            categoryRow
            list
        }
        .background(theme.bg)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: RIcon.search)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(theme.text2)
            TextField("Search service", text: $query)
                .font(RFont.text(16))
                .tracking(-0.3)
                .foregroundStyle(theme.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.chipBg, in: .rect(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var categoryRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ChipButton(label: "Affordable", icon: RIcon.coin,
                           active: affordableOnly, soft: true) {
                    affordableOnly.toggle()
                }
                Rectangle()
                    .fill(theme.sep)
                    .frame(width: 0.5, height: 20)
                    .padding(.horizontal, 2)
                ForEach(serviceCategories, id: \.self) { cat in
                    ChipButton(label: cat, active: category == cat, soft: true) {
                        category = cat
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 12)
    }

    private var list: some View {
        ScrollView {
            if filtered.isEmpty {
                Text("No services found")
                    .font(RFont.text(14))
                    .foregroundStyle(theme.text2)
                    .padding(.vertical, 24)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { service in
                        ServiceRow(service: service,
                                   price: state.cost(for: service, country: currentCountry),
                                   successRate: state.successRate(for: service, country: currentCountry),
                                   balance: state.balance) {
                            onPick(service)
                            dismiss()
                        }
                        if service.id != filtered.last?.id {
                            Rectangle().fill(theme.sep).frame(height: 0.5)
                                .padding(.leading, 66)
                        }
                    }
                }
                .background(theme.elev, in: .rect(cornerRadius: 22))
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }
}

private struct ServiceRow: View {
    @Environment(\.theme) private var theme
    let service: Service
    /// Real synced route price for the currently-selected country, or nil when
    /// the (service, country) pair has no confirmed price (unavailable to book).
    let price: Int?
    let successRate: Int?
    let balance: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ServiceLogo(service: service, size: 40)
                    .opacity(price == nil ? 0.45 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.name)
                        .font(RFont.display(16, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(price == nil ? theme.text2 : theme.text)
                    HStack(spacing: 8) {
                        Text(service.category)
                            .font(RFont.text(12))
                            .foregroundStyle(theme.text2)
                        Text("·").foregroundStyle(theme.text3)
                        Text("~\(service.etaSeconds)s typical")
                            .font(RFont.text(12))
                            .foregroundStyle(theme.text2)
                        if let successRate {
                            Text("·").foregroundStyle(theme.text3)
                            SuccessBadge(rate: successRate, compact: true)
                        }
                    }
                }
                Spacer(minLength: 0)
                if let price {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(price)")
                            .font(RFont.display(15, weight: .semibold))
                            .foregroundStyle(price <= balance ? theme.text : theme.text2)
                        Text("cr")
                            .font(RFont.text(12, weight: .medium))
                            .foregroundStyle(theme.text2)
                    }
                } else {
                    Text("Unavailable")
                        .font(RFont.text(12, weight: .medium))
                        .foregroundStyle(theme.text3)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
