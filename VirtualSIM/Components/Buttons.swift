import SwiftUI

struct PrimaryButton: View {
    @Environment(\.theme) private var theme
    let label: String
    var sub: String? = nil
    var icon: String? = nil
    var disabled: Bool = false
    let action: () -> Void

    @State private var pressed = false

    var body: some View {
        Button(action: { if !disabled { action() } }) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                }
                Text(label)
                    .font(RFont.display(17, weight: .semibold))
                    .tracking(-0.3)
                if let sub {
                    Rectangle()
                        .fill(Color.white.opacity(disabled ? 0 : 0.2))
                        .frame(width: 1, height: 18)
                        .padding(.leading, 4)
                    Text(sub)
                        .font(RFont.mono(15, weight: .medium))
                        .opacity(0.9)
                }
            }
            .foregroundStyle(disabled ? theme.text3 : theme.onInk)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(disabled ? theme.chipBg : theme.ink, in: .rect(cornerRadius: 18))
            .scaleEffect(pressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.12), value: pressed)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded   { _ in pressed = false }
        )
    }
}

struct GhostButton: View {
    @Environment(\.theme) private var theme
    let label: String
    var icon: String? = nil
    var fillsWidth: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .medium))
                }
                Text(label)
                    .font(RFont.text(15, weight: .medium))
                    .tracking(-0.2)
            }
            .foregroundStyle(theme.text)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .frame(height: 48)
            .padding(.horizontal, 16)
            .background(theme.chipBg, in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}
