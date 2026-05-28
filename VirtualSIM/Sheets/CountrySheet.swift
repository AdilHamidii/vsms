import SwiftUI

struct CountrySheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    var filter: SortFilter
    var onPick: (Country) -> Void

    private var sorted: [Country] {
        var list = SeedData.countries
        if filter == .fastest {
            list.sort { $0.avgSeconds < $1.avgSeconds }
        }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Choose a country")
            ScrollView {
                Card {
                    VStack(spacing: 0) {
                        ForEach(Array(sorted.enumerated()), id: \.element.id) { idx, c in
                            CountryRow(country: c, isLast: idx == sorted.count - 1) {
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
}

private struct CountryRow: View {
    @Environment(\.theme) private var theme
    let country: Country
    let isLast: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(country.flag)
                        .font(.system(size: 20))
                        .frame(width: 36, height: 36)
                        .background(theme.chipBg, in: .circle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(country.name)
                            .font(RFont.display(16, weight: .semibold))
                            .tracking(-0.3)
                            .foregroundStyle(theme.text)
                        HStack(spacing: 8) {
                            MonoText(country.code, size: 12, color: theme.text2)
                            Text("·").foregroundStyle(theme.text3)
                            Text("usually ~\(country.avgSeconds)s")
                                .font(RFont.text(12))
                                .foregroundStyle(theme.text2)
                        }
                    }
                    Spacer(minLength: 0)
                    StockPill(level: country.stock)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                if !isLast {
                    Rectangle().fill(theme.sep).frame(height: 0.5)
                        .padding(.leading, 62)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
