import SwiftUI

struct ServiceSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state
    var onPick: (Service) -> Void

    @State private var query: String = ""
    @State private var category: String = "All"
    @State private var affordableOnly = false

    /// The country the user is currently configuring. Prices shown per service
    /// are the REAL synced route price for this country (mirrors CountrySheet,
    /// which fixes the service and varies the country). Goes through
    /// `configuringCountry` for the same reason CountrySheet does — the raw
    /// `checkoutCountry ?? lastCountry` priced the list for a stale draft.
    private var currentCountry: Country { state.configuringCountry }

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

    /// When the Affordable toggle is on, keep only services the balance can
    /// actually buy — judged against the price the row SHOWS.
    ///
    /// This used to test `cost(for:country:)` alone, so every service without a
    /// route in the current country failed the `guard` and was dropped, even
    /// when it was cheaply bookable one tap away. The filter and the list have
    /// to agree on what a row costs, or "Affordable" hides affordable things.
    private func matchesAffordable(_ s: Service) -> Bool {
        guard affordableOnly else { return true }
        guard let c = state.cost(for: s, country: currentCountry)
                ?? state.pickDestination(for: s)?.credits else { return false }
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
                        let here = state.cost(for: service, country: currentCountry)
                        // Only resolved when there is no route here, so the
                        // 69-country scan never runs for the common case.
                        let elsewhere = here == nil
                            ? state.pickDestination(for: service) : nil
                        ServiceRow(service: service,
                                   price: here,
                                   elsewhere: elsewhere,
                                   // The badge must describe the route the tap
                                   // actually buys. Scored against the current
                                   // country it would read "Not tested" for a
                                   // destination route we HAVE measured.
                                   record: state.deliveryRecord(
                                       for: service,
                                       country: elsewhere?.country ?? currentCountry),
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
    /// Set only when `price` is nil: where this service IS bookable, and what
    /// it costs there. Exactly where tapping the row will land the user.
    let elsewhere: (country: Country, credits: Int)?
    let record: DeliveryRecord
    let balance: Int
    let onTap: () -> Void

    /// Bookable nowhere in the catalog — the one case that is genuinely
    /// unavailable, and so the only one that may say so or look disabled.
    private var isDeadEnd: Bool { price == nil && elsewhere == nil }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ServiceLogo(service: service, size: 40)
                    .opacity(isDeadEnd ? 0.45 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.name)
                        .font(RFont.display(16, weight: .semibold))
                        .tracking(-0.3)
                        .lineLimit(1)
                        .foregroundStyle(isDeadEnd ? theme.text2 : theme.text)
                    HStack(spacing: 8) {
                        Text(service.category)
                            .font(RFont.text(12))
                            .foregroundStyle(theme.text2)
                        // MEASURED arrival only — the seed etaSeconds was the
                        // last surface still stating it as fact. Nothing shows
                        // when there is no measurement.
                        if let wait = service.typicalWaitShort {
                            Text("·").foregroundStyle(theme.text3)
                            Text("\(wait) typical")
                                .font(RFont.text(12))
                                .foregroundStyle(theme.text2)
                        }
                        Text("·").foregroundStyle(theme.text3)
                        SuccessBadge(record: record, compact: true)
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
                } else if let elsewhere {
                    // "Not here, but here's where" — never a bare "Unavailable".
                    // The country name is what makes the price legible: without
                    // it this is a number for a route the user did not select.
                    VStack(alignment: .trailing, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("\(elsewhere.credits)")
                                .font(RFont.display(15, weight: .semibold))
                                .foregroundStyle(elsewhere.credits <= balance
                                                 ? theme.text : theme.text2)
                            Text("cr")
                                .font(RFont.text(12, weight: .medium))
                                .foregroundStyle(theme.text2)
                        }
                        // Flag + name, no preposition, and `verbatim` so it is
                        // never extracted for translation. "in %@" would need
                        // six translations for a country name that stays
                        // English anyway, and the article is gendered in
                        // pt-BR ("na Romênia" vs "no Brasil") and fr ("en
                        // Roumanie" vs "au Portugal") — unresolvable from a
                        // format string. The flag carries "this is a country"
                        // in every language.
                        Text(verbatim: "\(elsewhere.country.flag) \(elsewhere.country.name)")
                            .font(RFont.text(11, weight: .medium))
                            .foregroundStyle(theme.text3)
                            .lineLimit(1)
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
        // A dead end must not be tappable: bestCountry returns nil, so the tap
        // would set the service without moving the country and strand the user
        // on a Home screen whose only button is a disabled "Unavailable".
        .disabled(isDeadEnd)
    }
}
