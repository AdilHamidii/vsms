import SwiftUI

/// Press feedback that does NOT eat the scroll gesture.
///
/// PrimaryButton used to drive its scale with
/// `.simultaneousGesture(DragGesture(minimumDistance: 0))`. That gesture claims
/// the touch, so an enclosing ScrollView never receives it — putting a thumb on
/// the big CTA and swiping did nothing at all. Measured A/B in the simulator
/// with identical 150pt drags: plain button scrolled 243 → 593, the
/// simultaneousGesture one 243 → 243. It hit the Home hero, the credits sheet
/// and the OTP screen — i.e. the three biggest buttons in the app.
/// `ButtonStyle.configuration.isPressed` gives the same visual for free, and it
/// also can't get stuck: the old `pressed` flag was never reset if the gesture
/// was interrupted.
struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.985
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct PrimaryButton: View {
    @Environment(\.theme) private var theme
    /// Kept as `String` (not LocalizedStringKey) because callers such as
    /// RecoveryScreen pass an already-localized `String(localized:)` value with
    /// a country name interpolated in. `Text(LocalizedStringKey(label))` gets
    /// the best of both: a literal like "Get number" resolves against the
    /// catalog, while an already-translated string misses the lookup and
    /// renders verbatim. Before this the app shipped six translations that
    /// never reached any button.
    let label: String
    var sub: String? = nil
    var icon: String? = nil
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: { if !disabled { action() } }) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                }
                Text(LocalizedStringKey(label))
                    .font(RFont.display(17, weight: .semibold))
                    .tracking(-0.3)
                if let sub {
                    Rectangle()
                        .fill(Color.white.opacity(disabled ? 0 : 0.2))
                        .frame(width: 1, height: 18)
                        .padding(.leading, 4)
                    Text(LocalizedStringKey(sub))
                        .font(RFont.mono(15, weight: .medium))
                        .opacity(0.9)
                }
            }
            .foregroundStyle(disabled ? theme.text3 : theme.onInk)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background {
                if disabled {
                    Capsule().fill(theme.chipBg)
                } else {
                    // A shallow vertical gradient plus the accent's own glow.
                    // A flat fill is the single most "system default" thing a
                    // primary button can do; the app owned a `glow` token and
                    // used it in exactly one file.
                    Capsule()
                        .fill(LinearGradient(
                            colors: [theme.ink.mixed(with: .white, amount: 0.10), theme.ink],
                            startPoint: .top, endPoint: .bottom))
                        .shadow(color: theme.glow, radius: 18, x: 0, y: 8)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle(scale: 0.97))
        .disabled(disabled)
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
                Text(LocalizedStringKey(label))
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
