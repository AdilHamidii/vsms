import SwiftUI

/// The vSMS wordmark: a green **v** followed by **SMS** in the foreground
/// colour — white on dark, near-black on light.
///
/// This replaces the previous lockup, a `bolt.fill` glyph in a rounded-rect
/// tile. A generic lightning bolt is not a mark: it says nothing about the
/// product and is the same badge a hundred other apps use. The name IS the
/// logo, so the type carries it.
///
/// The `v` takes `theme.ink` — the user-selectable accent, green by default —
/// rather than a hardcoded green. That is the same colour the primary button
/// and selected tabs use, so the mark stays part of the app rather than
/// fighting a chosen accent. It deliberately does NOT use `theme.live`, which
/// is the SEMANTIC success green ("your code arrived", "your credits came
/// back"); spending that colour on branding is exactly the conflation
/// `AccentColor` documents as forbidden.
///
/// `spins` makes the mark the app's loading indicator: the letters type on one
/// at a time, then the `v` rotates for as long as the screen is up. That is why
/// the splash needs no separate spinner — the logo is doing the work.
struct BrandWordmark: View {
    @Environment(\.theme) private var theme

    var size: CGFloat = 30
    /// Type the letters on, then rotate the `v` continuously.
    var spins: Bool = false

    @State private var revealed = 0
    @State private var spinning = false

    /// (glyph, isTheV)
    private let letters: [(String, Bool)] = [
        ("v", true), ("S", false), ("M", false), ("S", false),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(letters.enumerated()), id: \.offset) { index, letter in
                // `verbatim` throughout: this is a brand name. As a
                // LocalizedStringKey each letter would become its own catalog
                // entry AND become translatable, and a translated logo is not
                // a logo.
                Text(verbatim: letter.0)
                    .font(RFont.display(size, weight: .bold))
                    .foregroundStyle(letter.1 ? theme.ink : theme.text)
                    // Rotation only ever applies to the `v`.
                    .rotationEffect(letter.1 && spinning ? .degrees(360) : .zero)
                    // Opacity, not conditional insertion — the glyphs must all
                    // hold their place or the mark would reflow as it types.
                    .opacity(spins ? (revealed > index ? 1 : 0) : 1)
                    .offset(y: spins && revealed <= index ? size * 0.14 : 0)
            }
        }
        .task {
            guard spins else { return }
            for i in 1...letters.count {
                try? await Task.sleep(nanoseconds: 150_000_000)
                withAnimation(.easeOut(duration: 0.28)) { revealed = i }
            }
            // A beat after the name lands, so the spin reads as "now loading"
            // rather than as part of the write-on.
            try? await Task.sleep(nanoseconds: 200_000_000)
            withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                spinning = true
            }
        }
    }
}
