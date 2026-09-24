import SwiftUI

/// Non-generic so callers can read it without naming `VerifyTile`'s `Icon`.
enum VerifyTileStyle {
    /// The logo plate's corner radius. The caller draws the logo at this
    /// radius so the tile's hairline traces the plate exactly.
    static let plateRadius: CGFloat = 11
}

/// One app tile on Verify. Kept as the only tile body so every cell in the
/// grid is the same height.
struct VerifyTile<Icon: View>: View {
    @Environment(\.theme) private var theme
    let label: Text
    let action: () -> Void
    @ViewBuilder let icon: Icon

    var body: some View {
        Button(action: action) {
            VStack(spacing: RSpace.sm) {
                icon
                    // Logos sit on a white plate; on a white light-mode tile
                    // the plate otherwise reads as a faint, edgeless square.
                    .overlay {
                        RoundedRectangle(cornerRadius: VerifyTileStyle.plateRadius, style: .continuous)
                            .strokeBorder(theme.sep, lineWidth: 1)
                    }
                label
                    .font(RFont.text(12, weight: .semibold))
                    .foregroundStyle(theme.text2)
                    // Backstop only: the caller hands over one product word
                    // (`VerifyScreen.tileLabel`). The inset keeps an ellipsis
                    // off the tile's hairline.
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
            .padding(.bottom, RSpace.md)
            .background(theme.elev, in: .rect(cornerRadius: RRadius.group, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: RRadius.group, style: .continuous)
                    .strokeBorder(theme.sep, lineWidth: 1)
            }
            .contentShape(.rect(cornerRadius: RRadius.group))
        }
        .pressable()
    }
}
