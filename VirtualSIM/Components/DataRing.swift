import SwiftUI

/// Circular data-usage gauge for an eSIM.
///
/// Shows **remaining**, not used. The provider reports `data_used_mb`, so used
/// is the number we hold — but the question a traveller actually has is "how
/// much is left before I'm offline", and making them subtract is a small tax
/// paid every single time they open the screen.
///
/// Colour is a genuine warning channel, not decoration: it only leaves the
/// accent tint once the plan is nearly gone. A ring that is amber at 50% has
/// taught the user to ignore amber by the time it matters.
struct DataRing: View {
    @Environment(\.theme) private var theme

    let usedMb: Int
    let totalMb: Int?
    var size: CGFloat = 132
    var lineWidth: CGFloat = 12

    @State private var animated = false

    private var fraction: Double {
        guard let t = totalMb, t > 0 else { return 0 }
        return min(1, max(0, Double(usedMb) / Double(t)))
    }
    private var remainingMb: Int { max(0, (totalMb ?? 0) - usedMb) }

    /// Amber under 20% left, red under 5%. Both thresholds are about "can I
    /// still do something useful with this", not round numbers.
    private var tint: Color {
        guard totalMb != nil else { return theme.text3 }
        let left = 1 - fraction
        if left <= 0.05 { return theme.fail }
        if left <= 0.20 { return theme.warn }
        return theme.ink
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(theme.chipBg, lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: animated ? max(0.004, 1 - fraction) : 0)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))

            VStack(spacing: 1) {
                if totalMb != nil {
                    Text(EsimFormat.data(remainingMb))
                        .font(RFont.display(size * 0.21, weight: .bold))
                        .tracking(-0.6)
                        .foregroundStyle(theme.text)
                        .contentTransition(.numericText())
                    Text("left")
                        .font(RFont.text(size * 0.093))
                        .foregroundStyle(theme.text2)
                } else {
                    // No allowance reported yet. Say so — a ring drawn at 0%
                    // would read as "nothing used", which is a claim we cannot
                    // make before the provider has told us the size.
                    Text("—")
                        .font(RFont.display(size * 0.21, weight: .bold))
                        .foregroundStyle(theme.text3)
                    Text("no reading")
                        .font(RFont.text(size * 0.085))
                        .foregroundStyle(theme.text3)
                }
            }
        }
        .frame(width: size, height: size)
        .onAppear { withAnimation(RMotion.value) { animated = true } }
        .onChange(of: fraction) { _, _ in withAnimation(RMotion.value) { animated = true } }
        .accessibilityElement()
        .accessibilityLabel(totalMb == nil
            ? Text("Data remaining unknown")
            : Text("\(EsimFormat.data(remainingMb)) of \(EsimFormat.data(totalMb ?? 0)) remaining"))
    }
}

/// Slim horizontal variant for list rows, where a full ring is too heavy.
struct DataBar: View {
    @Environment(\.theme) private var theme
    let usedMb: Int
    let totalMb: Int?
    @State private var animated = false

    private var fraction: Double {
        guard let t = totalMb, t > 0 else { return 0 }
        return min(1, max(0, Double(usedMb) / Double(t)))
    }
    private var tint: Color {
        let left = 1 - fraction
        if left <= 0.05 { return theme.fail }
        if left <= 0.20 { return theme.warn }
        return theme.ink
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.chipBg)
                Capsule().fill(tint)
                    .frame(width: animated ? geo.size.width * (1 - fraction) : 0)
            }
        }
        .frame(height: 5)
        .onAppear { withAnimation(RMotion.value) { animated = true } }
        .onChange(of: fraction) { _, _ in withAnimation(RMotion.value) { animated = true } }
    }
}
