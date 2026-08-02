import SwiftUI

struct Metric: View {
    @Environment(\.theme) private var theme
    let label: String
    let value: String
    var accent: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Localize FIRST, then uppercase — Text(String) skips the catalog,
            // and .uppercased() on the key would also break the lookup.
            Text(String(localized: String.LocalizationValue(label)).uppercased())
                .font(RFont.text(11, weight: .medium))
                .tracking(0.2)
                .foregroundStyle(theme.text2)
            Text(LocalizedStringKey(value))
                .font(RFont.display(16, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(accent ?? theme.text)
        }
    }
}
