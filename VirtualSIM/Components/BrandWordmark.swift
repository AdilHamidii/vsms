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
/// flag holds (`BreathingMark`). (Until 2026-09-24 the letters typed on and the `v` then spun.
/// The splash was two instances then, so the type-on replayed mid-launch when
/// the second took over; the owner chose a calm, always-drawn mark instead.)
/// Every other caller — onboarding, the sign-in fields — uses the static mark.
struct BrandWordmark: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var size: CGFloat = 30
    /// Pulse the opacity 1 ↔ 0.72 over 1.6 s each way. Ignored under Reduce
    /// Motion, where the mark stays still.
    var breathes: Bool = false

    private var shouldBreathe: Bool { breathes && !reduceMotion }

    /// (glyph, isTheV). One `Text` per letter, as it has always been drawn:
    /// merging "SMS" into one run would apply the font's kerning and subtly
    /// change the static mark onboarding and sign-in show.
    private let letters: [(String, Bool)] = [
        ("v", true), ("S", false), ("M", false), ("S", false),
    ]

    var body: some View {
        // 🔴 The breath is a FUNCTION OF TIME inside its own child view, not
        // a `repeatForever` animation. A running `repeatForever` can only be
        // stopped by a second animation on the same property overriding it,
        // and timing-curve animations do not reliably replace one another
        // (the first version relied on exactly that). Here, stopping means
        // the `BreathingMark` branch is removed: its timeline goes with it
        // and the static branch draws opacity 1, exactly — in the failure
        // state, in a pinned fixture, and the moment Reduce Motion turns on.
        if shouldBreathe {
            BreathingMark { mark }
        } else {
            mark
        }
    }

    private var mark: some View {
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
    }
}

/// The splash's breathing wordmark: opacity as a pure function of the time
/// since THIS view appeared, so its first frame is always 1 (fully drawn)
/// whenever breathing (re)starts, and it has no animation state to stop.
private struct BreathingMark<Content: View>: View {
    @ViewBuilder var content: Content

    /// Captured when the view is created, i.e. when breathing starts.
    @State private var start = Date()

    /// 1.6 s down, 1.6 s up.
    private static var period: Double { 3.2 }
    private static var depth: Double { 0.28 }   // 1 → 0.72

    var body: some View {
        TimelineView(.animation) { context in
            content.opacity(Self.opacity(at: context.date.timeIntervalSince(start)))
        }
    }

    /// Cosine ease-in-out: 1 at t = 0, 0.72 at half a period, back to 1.
    static func opacity(at t: TimeInterval) -> Double {
        1 - depth * (1 - cos(2 * .pi * max(0, t) / period)) / 2
    }
}
