import SwiftUI

struct ChipButton: View {
    @Environment(\.theme) private var theme
    let label: String
    var icon: String? = nil
    var active: Bool = false
    var soft: Bool = false
    var onTap: () -> Void

    var body: some View {
        Button {
            RHaptic.select()
            onTap()
        } label: {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                }
                // LocalizedStringKey: chip labels ("Affordable", the sort
                // names) have translations that Text(String) never used. DB
                // data (category names) misses the lookup and renders as-is.
                Text(LocalizedStringKey(label))
                    .font(RFont.text(13, weight: .medium))
                    .tracking(-0.2)
            }
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(backgroundColor, in: .capsule)
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(.capsule)
        }
        .pressable(0.94)
    }

    private var foregroundColor: Color {
        if active && !soft { return theme.onInk }
        if active && soft  { return theme.text }
        return theme.text2
    }
    private var backgroundColor: Color {
        if active && !soft { return theme.ink }
        if active && soft  { return theme.inkSoft }
        return soft ? Color.clear : theme.chipBg
    }
}
