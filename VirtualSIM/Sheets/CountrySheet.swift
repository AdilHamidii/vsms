import SwiftUI

enum CountrySort: String, Hashable, CaseIterable {
    case `default`, cheapest, fastest

    var label: String {
        switch self {
        case .default:  "Default"
        case .cheapest: "Cheapest"
        case .fastest:  "Fastest"
        }
    }
    var icon: String {
        switch self {
        case .default:  RIcon.filter
        case .cheapest: RIcon.coin
        case .fastest:  RIcon.bolt
        }
    }
}

struct CountrySheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state
    var onPick: (Country) -> Void

    @State private var sort: CountrySort = .default

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
            let costFor: (Country) -> Int = { state.cost(for: currentService, country: $0) }
            list.sort { costFor($0) < costFor($1) }
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
    let price: Int
    let isLast: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    FlagCircle(country: country, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(country.name)
                            .font(RFont.display(16, weight: .semibold))
                            .tracking(-0.3)
                            .foregroundStyle(theme.text)
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
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("\(price)")
                                .font(RFont.display(15, weight: .semibold))
                                .foregroundStyle(theme.text)
                            Text("cr")
                                .font(RFont.text(12, weight: .medium))
                                .foregroundStyle(theme.text2)
                        }
                        StockPill(level: country.stock)
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
