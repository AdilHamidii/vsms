import SwiftUI

enum CountrySort: String, Hashable, CaseIterable {
    case bestSuccess, cheapest, fastest, `default`

    var label: String {
        switch self {
        case .bestSuccess: "Best success"
        case .cheapest:    "Cheapest"
        case .fastest:     "Fastest"
        case .default:     "A–Z"
        }
    }
    var icon: String {
        switch self {
        case .bestSuccess: RIcon.shield
        case .cheapest:    RIcon.coin
        case .fastest:     RIcon.bolt
        case .default:     RIcon.filter
        }
    }
}

struct CountrySheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state
    var onPick: (Country) -> Void

    // Default to Best success — steer users onto the countries that actually
    // deliver for this service instead of the cheapest/first one.
    @State private var sort: CountrySort = .bestSuccess

    /// The service the user is currently configuring. While in checkout we
    /// use the draft service; otherwise the Home "Last used".
    private var currentService: Service {
        state.checkoutService ?? state.lastService
    }

    private var sorted: [Country] {
        var list = state.availableCountries
        switch sort {
        case .default:  break
        case .fastest:  list.sort { $0.avgSeconds < $1.avgSeconds }
        case .cheapest:
            // Unavailable routes (nil price) sink to the bottom of the list.
            let costFor: (Country) -> Int = {
                state.cost(for: currentService, country: $0) ?? .max
            }
            list.sort { costFor($0) < costFor($1) }
        case .bestSuccess:
            // Available first, then by EVIDENCE tier, then price — and among
            // untested routes the cheapest is deliberately NOT preferred: the
            // provider's cheapest pool is its worst inventory, and when every
            // route was tied at a placeholder rate this sort silently became
            // "cheapest first", steering users onto the numbers least likely
            // to deliver. Tiers: proven → untested → proven-bad.
            func key(_ c: Country) -> (Int, Int, Int) {
                let price = state.cost(for: currentService, country: c) ?? .max
                let avail = state.cost(for: currentService, country: c) != nil ? 0 : 1
                guard let rate = state.successRate(for: currentService, country: c) else {
                    return (avail, 1, -price)   // untested: pricier (better pool) first
                }
                return rate > 0 ? (avail, 0, -rate) : (avail, 2, price)
            }
            list.sort { key($0) < key($1) }
        }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Choose a country")
            sortRow
            ScrollView {
                Card {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(sorted.enumerated()), id: \.element.id) { idx, c in
                            CountryRow(country: c,
                                       price: state.cost(for: currentService, country: c),
                                       successRate: state.successRate(for: currentService, country: c),
                                       balance: state.balance,
                                       isLast: idx == sorted.count - 1) {
                                onPick(c)
                                dismiss()
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 24)
            }
        }
        .background(theme.bg)
    }

    private var sortRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(CountrySort.allCases, id: \.self) { option in
                    ChipButton(label: option.label,
                               icon: option.icon,
                               active: sort == option) {
                        sort = option
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 12)
    }
}

private struct CountryRow: View {
    @Environment(\.theme) private var theme
    let country: Country
    let price: Int?
    let successRate: Int?
    let balance: Int
    let isLast: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    FlagCircle(country: country, size: 36)
                        .opacity(price == nil ? 0.45 : 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(country.name)
                            .font(RFont.display(16, weight: .semibold))
                            .tracking(-0.3)
                            .foregroundStyle(price == nil ? theme.text2 : theme.text)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            MonoText(country.dialCode, size: 12, color: theme.text2)
                            Text("·").foregroundStyle(theme.text3)
                            Text("usually ~\(country.avgSeconds)s")
                                .font(RFont.text(12))
                                .foregroundStyle(theme.text2)
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 4) {
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
                        if let successRate {
                            SuccessBadge(rate: successRate, compact: true)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(.rect)
                if !isLast {
                    Rectangle().fill(theme.sep).frame(height: 0.5)
                        .padding(.leading, 62)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
