import SwiftUI

struct SectionHeader: View {
    @Environment(\.theme) private var theme
    let label: String
    var action: String? = nil
    var onAction: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            // Localize first, then uppercase — Text(String) skips the catalog.
            Text(String(localized: String.LocalizationValue(label)).uppercased())
                .font(RFont.display(13, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(theme.text2)
                // VoiceOver's rotor navigates by headers; without the trait
                // every section title read as body text.
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let action {
                Button(action: { onAction?() }) {
                    Text(LocalizedStringKey(action))
                        .font(RFont.text(14, weight: .medium))
                        .foregroundStyle(theme.text2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 10)
        .padding(.top, 4)
    }
}
