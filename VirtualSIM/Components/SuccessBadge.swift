import SwiftUI

/// A small colored delivery-success badge (green ≥70, amber ≥40, muted below).
/// Shown wherever a per-route success rate is available.
struct SuccessBadge: View {
    @Environment(\.theme) private var theme
    let rate: Int
    var compact: Bool = false

    private var color: Color {
        if rate >= 70 { theme.live } else if rate >= 40 { theme.warn } else { theme.text3 }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(compact ? "\(rate)%" : "\(rate)% delivered")
                .font(RFont.text(11, weight: .semibold))
                .foregroundStyle(color)
        }
    }
}
