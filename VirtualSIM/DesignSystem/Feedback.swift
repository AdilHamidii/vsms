import SwiftUI
import UIKit

/// Haptics, as a named vocabulary rather than call-site guesses.
///
/// The app had **none** — no `.sensoryFeedback`, no feedback generator
/// anywhere. Copying your new number, a code arriving, a purchase completing,
/// a message delivering: all silent. Each of those is the moment the product
/// works, and on iOS a silent success reads as a screen that did not respond.
///
/// Kept deliberately small. A haptic on everything is the same mistake as a
/// shadow on everything — it stops meaning anything.
enum RHaptic {
    /// Picking one of several things: a city, a country, a segment, a plan.
    static func select() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
    }

    /// The thing the screen exists for happened: a code arrived, a number was
    /// provisioned, credits landed.
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// A refusal the user should feel — an order refused, a send blocked.
    static func warn() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    /// A value was copied to the clipboard. Distinct from `select` because
    /// nothing moves on screen, so touch is the only confirmation there is.
    static func copied() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }
}

/// A travelling highlight for skeleton placeholders.
///
/// The loading list faked depth with static `.opacity(1 - i * 0.15)`, which
/// reads as a broken list rather than a loading one. Motion is the entire
/// signal that a placeholder is a placeholder.
struct Shimmer: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear,
                                     theme.text.opacity(theme.isDark ? 0.09 : 0.06),
                                     .clear],
                            startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.55)
                            .offset(x: phase * geo.size.width * 1.6)
                    }
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) {
                    phase = 1.2
                }
            }
    }
}

extension View {
    func shimmer() -> some View { modifier(Shimmer()) }

    /// Press feedback for any tappable surface that is not a `PrimaryButton`.
    ///
    /// Half the tappable surfaces in the app used `.buttonStyle(.plain)` and so
    /// responded to touch not at all, while the other half scaled — which reads
    /// as parts of the interface being broken rather than as a style choice.
    func pressable(_ scale: CGFloat = 0.97) -> some View {
        buttonStyle(PressScaleStyle(scale: scale))
    }

    /// Press feedback for a whole CARD — a large target where a scale alone is
    /// too subtle to register, so it dims slightly as well.
    ///
    /// This exists so there is exactly ONE press vocabulary. A second
    /// `PressableStyle` had grown inside `EsimCountryPlansScreen` with its own
    /// spring and its own numbers, used on four eSIM surfaces — so identical
    /// card taps felt different depending on which screen you were on, which
    /// reads as parts of the app being broken rather than as a style choice.
    func pressableCard() -> some View {
        buttonStyle(PressScaleStyle(scale: 0.975, dim: true))
    }
}
