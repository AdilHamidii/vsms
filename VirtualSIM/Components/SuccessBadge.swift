import SwiftUI

/// A small colored delivery-success badge (green ≥70, amber ≥40, muted below).
/// Shown wherever a per-route success rate is available. Only a MEASURED rate
/// may read as fact ("delivered"); seeded estimates carry a tilde + "est." so
/// a provider prior is never presented as our own delivery record.
struct SuccessBadge: View {
    @Environment(\.theme) private var theme
    let rate: Int
    var measured: Bool = false   // conservative default: estimate
    var compact: Bool = false

    private var color: Color {
        if rate >= 70 { theme.live } else if rate >= 40 { theme.warn } else { theme.text3 }
    }

    private var label: String {
        if measured { return compact ? "\(rate)%" : String(localized: "\(rate)% delivered") }
        return compact ? "~\(rate)%" : String(localized: "~\(rate)% est.")
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label)
                .font(RFont.text(11, weight: .semibold))
                .foregroundStyle(color)
        }
    }
}
