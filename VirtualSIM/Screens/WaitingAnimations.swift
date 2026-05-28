import SwiftUI

struct WaitingAnimationView: View {
    @Environment(\.theme) private var theme
    let kind: WaitingAnimation

    var body: some View {
        switch kind {
        case .pulse:   PulseAnim()
        case .breathe: BreatheAnim()
        case .orbit:   OrbitAnim()
        }
    }
}

private struct PulseAnim: View {
    @Environment(\.theme) private var theme
    @State private var animate = false

    var body: some View {
        ZStack {
            Circle()
                .fill(theme.live.opacity(0.16))
                .frame(width: 96, height: 96)
                .scaleEffect(animate ? 1.05 : 0.92)
                .opacity(animate ? 1 : 0.55)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: animate)
            Circle()
                .fill(theme.live.opacity(0.22))
                .frame(width: 64, height: 64)
                .scaleEffect(animate ? 1.05 : 0.92)
                .opacity(animate ? 1 : 0.55)
                .animation(.easeInOut(duration: 0.8).delay(0.2).repeatForever(autoreverses: true), value: animate)
            Circle()
                .fill(theme.live)
                .frame(width: 18, height: 18)
                .shadow(color: theme.glow, radius: 9)
        }
        .frame(width: 120, height: 120)
        .onAppear { animate = true }
    }
}

private struct BreatheAnim: View {
    @Environment(\.theme) private var theme
    @State private var phase: CGFloat = 0

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let off = Double(i) * 0.5
                    let p = ((t - off).truncatingRemainder(dividingBy: 2.4)) / 2.4
                    let scale = 1.0 + p * 0.18
                    let opacity = 0.55 * (1.0 - p)
                    Circle()
                        .strokeBorder(theme.live, lineWidth: 1.5)
                        .frame(width: 60, height: 60)
                        .scaleEffect(scale)
                        .opacity(opacity)
                }
                Circle()
                    .fill(theme.live)
                    .frame(width: 28, height: 28)
            }
            .frame(width: 120, height: 120)
        }
    }
}

private struct OrbitAnim: View {
    @Environment(\.theme) private var theme
    @State private var angle: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(theme.sep, lineWidth: 1)
                .frame(width: 88, height: 88)
            ZStack {
                Circle()
                    .fill(theme.live)
                    .frame(width: 10, height: 10)
                    .shadow(color: theme.glow, radius: 7)
                    .offset(y: -44)
            }
            .frame(width: 88, height: 88)
            .rotationEffect(.degrees(angle))
            .animation(.linear(duration: 2.6).repeatForever(autoreverses: false), value: angle)
            MonoText("SMS", size: 13, color: theme.text2)
        }
        .frame(width: 120, height: 120)
        .onAppear { angle = 360 }
    }
}
