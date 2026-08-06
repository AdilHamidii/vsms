import SwiftUI

/// The waiting indicator — and the only thing on that screen that encodes
/// PROGRESS.
///
/// It used to be three ambient loops picked from a preference (pulse, breathe,
/// orbit), none of which said anything about how far through the wait the user
/// was. The screen answered that question with two 20pt monospaced clocks
/// instead — ELAPSED counting up next to EXPIRES IN counting down, next to a
/// Cancel button. Measured: first-time users bail at a median of **104s**
/// precisely because a stated deadline reads as *overdue*, while codes arrive
/// at a median of **58s**. A running deadline beside a destructive button is
/// the worst pairing this product can put on screen.
///
/// So the clocks are gone and the ring carries the state:
///  - the ACCENT segment fills to the service's MEASURED p90 arrival — the
///    point by which ~9 of every 10 codes that ever arrive have arrived,
///  - past it the ring keeps going in a MUTED tone to the end of the
///    reservation: honest that the wait is now longer than typical, without
///    dramatising it into a countdown,
///  - a numeric countdown appears only in the final minute, in `theme.warn`,
///    where it is genuinely actionable rather than merely alarming.
///
/// **No p90 means no milestone.** `expectedFraction` is nil for a service we
/// have never measured, and the ring then draws one plain accent arc with no
/// notch. Inventing a milestone would be the seeded-`etaSeconds` mistake — a
/// promise the data does not support — one layer down in the geometry.
///
/// `kind` survives so the Account preference still means something: it chooses
/// how the CORE breathes. It deliberately no longer decides whether progress is
/// shown at all — that is not a matter of taste.
struct WaitingAnimationView: View {
    @Environment(\.theme) private var theme

    var kind: WaitingAnimation = .pulse
    /// 0...1 through the whole reservation window.
    var progress: Double = 0
    /// Where the measured p90 sits on that same 0...1 scale, or nil when we
    /// have measured nothing for this service.
    var expectedFraction: Double? = nil
    /// Rendered inside the ring for the final minute only.
    var countdown: String? = nil
    /// The window closed and the server has not confirmed the outcome yet.
    var isFinalizing: Bool = false

    private let size: CGFloat = 132
    private let lineWidth: CGFloat = 6

    private var clamped: Double { min(max(progress, 0), 1) }

    /// Only a milestone strictly inside the window is drawable — a p90 at or
    /// past expiry is not a milestone, it is the end of the ring.
    private var expected: Double? {
        guard let f = expectedFraction, f > 0.02, f < 0.98 else { return nil }
        return f
    }

    private var accentEnd: Double { min(clamped, expected ?? 1) }
    private var ringRadius: CGFloat { size / 2 - lineWidth / 2 }

    var body: some View {
        ZStack {
            Circle().stroke(theme.track, lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: accentEnd)
                .stroke(theme.ink,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))

            // Past p90 the wait is longer than typical. It keeps moving —
            // a frozen ring reads as a stalled app — but it stops spending the
            // accent, which is the app's "this is going well" colour.
            if let expected, clamped > expected {
                Circle()
                    .trim(from: expected, to: clamped)
                    .stroke(theme.text3,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }

            if let expected { milestone(at: expected) }

            core
        }
        .frame(width: size, height: size)
        // One second per tick, linear: the ring must not overshoot or bounce,
        // because its position is a claim about time.
        .animation(.linear(duration: 1), value: clamped)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Waiting for your code"))
    }

    /// A notch cut through the ring at the measured p90, in the card's own
    /// fill — so it reads as a graduation on the track rather than as another
    /// coloured thing competing with the arc.
    private func milestone(at fraction: Double) -> some View {
        // Placed at 12 o'clock and rotated into position, so it stays RADIAL
        // (perpendicular to the track) at any fraction. Doing it with x/y trig
        // instead needs a second, easy-to-get-wrong rotation to keep it square
        // to the ring.
        Capsule()
            .fill(theme.elev)
            .frame(width: 2.5, height: lineWidth + 2)
            .offset(y: -ringRadius)
            .rotationEffect(.degrees(fraction * 360))
    }

    @ViewBuilder
    private var core: some View {
        if let countdown {
            VStack(spacing: 1) {
                MonoText(countdown, size: 22, weight: .semibold, color: theme.warn)
                Text("LEFT")
                    .font(RFont.text(10, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(theme.text3)
            }
        } else {
            WaitingCore(kind: kind, muted: isFinalizing)
        }
    }
}

/// The small mark at the centre of the ring.
///
/// Purely ambient by design: the ring already carries the information, so this
/// only has to say "still alive". That is also why the Account preference can
/// keep driving it without any of the three options being able to mislead.
private struct WaitingCore: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let kind: WaitingAnimation
    var muted: Bool = false

    @State private var animate = false

    private var tint: Color { muted ? theme.text3 : theme.ink }

    var body: some View {
        ZStack {
            if reduceMotion {
                // Reduce Motion still needs a "we are working" mark; a bare
                // static dot is that mark, not an absence.
                Circle().fill(tint).frame(width: 14, height: 14)
            } else {
                switch kind {
                case .pulse:   pulse
                case .breathe: breathe
                case .orbit:   orbit
                }
            }
        }
        .frame(width: 68, height: 68)
        .onAppear { animate = true }
    }

    private var pulse: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.14))
                .frame(width: 54, height: 54)
                .scaleEffect(animate ? 1.06 : 0.86)
                .opacity(animate ? 1 : 0.5)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                           value: animate)
            Circle()
                .fill(tint.opacity(0.22))
                .frame(width: 34, height: 34)
                .scaleEffect(animate ? 1.06 : 0.86)
                .opacity(animate ? 1 : 0.5)
                .animation(.easeInOut(duration: 0.9).delay(0.18).repeatForever(autoreverses: true),
                           value: animate)
            Circle().fill(tint).frame(width: 13, height: 13)
        }
    }

    private var breathe: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .strokeBorder(tint, lineWidth: 1.5)
                    .frame(width: 30, height: 30)
                    .scaleEffect(animate ? 2.0 : 0.9)
                    .opacity(animate ? 0 : 0.55)
                    .animation(.easeOut(duration: 2.2)
                                .delay(Double(i) * 0.73)
                                .repeatForever(autoreverses: false),
                               value: animate)
            }
            Circle().fill(tint).frame(width: 20, height: 20)
        }
    }

    private var orbit: some View {
        ZStack {
            Circle().strokeBorder(theme.sep, lineWidth: 1)
                .frame(width: 52, height: 52)
            Circle()
                .fill(tint)
                .frame(width: 9, height: 9)
                .offset(y: -26)
                .rotationEffect(.degrees(animate ? 360 : 0))
                .animation(.linear(duration: 2.6).repeatForever(autoreverses: false),
                           value: animate)
        }
    }
}
