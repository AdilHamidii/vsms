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
/// `breathes` makes the mark the splash's loading indicator: it is fully drawn
/// on the first frame and then pulses its opacity slowly for as long as the
/// flag holds. (Until 2026-09-24 the letters typed on and the `v` then spun.
/// The splash was two instances then, so the type-on replayed mid-launch when
/// the second took over; the owner chose a calm, always-drawn mark instead.)
/// Every other caller — onboarding, the sign-in fields — uses the static mark.
struct BrandWordmark: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var size: CGFloat = 30
    /// Pulse the opacity 1 ↔ 0.72 (`RMotion.breathe`). Ignored under Reduce
    /// Motion, where the mark stays still.
    var breathes: Bool = false

    @State private var exhaled = false

    private var shouldBreathe: Bool { breathes && !reduceMotion }

    /// (glyph, isTheV). One `Text` per letter, as it has always been drawn:
    /// merging "SMS" into one run would apply the font's kerning and subtly
    /// change the static mark onboarding and sign-in show.
    private let letters: [(String, Bool)] = [
        ("v", true), ("S", false), ("M", false), ("S", false),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(letters.enumerated()), id: \.offset) { _, letter in
                // `verbatim` throughout: this is a brand name. As a
                // LocalizedStringKey each letter would become its own catalog
                // entry AND become translatable, and a translated logo is not
                // a logo.
                Text(verbatim: letter.0)
                    .font(RFont.display(size, weight: .bold))
                    .foregroundStyle(letter.1 ? theme.ink : theme.text)
            }
        }
        .opacity(exhaled ? 0.72 : 1)
        // Starts at full opacity, so the first frame is the whole mark. A new
        // non-repeating animation back to 1 replaces the loop when breathing
        // stops (failure state, Reduce Motion switched on mid-launch).
        .onChange(of: shouldBreathe, initial: true) { _, breathe in
            if breathe {
                withAnimation(RMotion.breathe) { exhaled = true }
            } else if exhaled {
                withAnimation(RMotion.content) { exhaled = false }
            }
        }
    }
}
