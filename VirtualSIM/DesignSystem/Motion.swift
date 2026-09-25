import SwiftUI

/// One animation vocabulary for the whole app.
///
/// Before this, curves were written inline at each call site — `.easeOut(0.15)`
/// next to `.spring(response: 0.28, dampingFraction: 0.85)` next to
/// `.easeOut(0.2)` — so two controls that do the same kind of thing moved at
/// visibly different speeds, and "make it feel smoother" had no single place to
/// change. Naming them by *what is moving* rather than by curve keeps call
/// sites honest about intent.
///
/// The durations are deliberately short. Anything past ~0.35s on a control the
/// user is tapping repeatedly stops reading as polish and starts reading as lag.
enum RMotion {
    /// Selection within a control the user is already looking at — segment
    /// changes, chips, filters. Snappy, barely-there overshoot.
    static let select = Animation.spring(response: 0.28, dampingFraction: 0.86)

    /// A card, sheet or panel entering or leaving. Slightly softer landing so a
    /// large moving surface settles rather than snaps.
    static let panel = Animation.spring(response: 0.38, dampingFraction: 0.82)

    /// Content swapping in place — list contents, empty→loaded. Pure fade
    /// timing; no spring, because nothing is travelling.
    static let content = Animation.easeOut(duration: 0.22)

    /// Numbers and bars settling to a new measured value (usage rings, balances).
    /// Longer on purpose: the motion IS the information here.
    static let value = Animation.spring(response: 0.65, dampingFraction: 0.9)

    /// Map camera moves. Matches MapKit's own feel closely enough that a
    /// programmatic fly-to is hard to tell from a gesture.
    static let camera = Animation.spring(response: 0.55, dampingFraction: 0.88)

    /// The overhaul's default spring for anything that moves and is not one
    /// of the cases above (response 0.35, damping 0.85 — spec §5).
    static let standard = Animation.spring(response: 0.35, dampingFraction: 0.85)

    /// Staggered entrance for a list. Capped so a long list does not make the
    /// last row wait — beyond ~8 rows the delay stops reading as sequence and
    /// starts reading as slowness.
    static func stagger(_ index: Int, step: Double = 0.035, cap: Int = 8) -> Animation {
        .spring(response: 0.42, dampingFraction: 0.85)
        .delay(Double(min(index, cap)) * step)
    }

    /// How long the splash takes to hand off to the first screen. The splash
    /// host unmounts after exactly this, so the two cannot disagree.
    static let handoffSeconds: Double = 0.5

    /// The splash handing off: the background fades while the wordmark glides
    /// up and out. Ease-OUT so the first screen is visibly arriving from the
    /// first frame of the handoff rather than after a slow start.
    static let handoff = Animation.easeOut(duration: handoffSeconds)

    /// nil under Reduce Motion, so `withAnimation(RMotion.unlessReduced(…))`
    /// and `.animation(RMotion.unlessReduced(…), value:)` change instantly.
    /// Every animation added by the My number overhaul goes through this
    /// (spec §3a: "every one is skipped under Reduce Motion").
    static func unlessReduced(_ animation: Animation, _ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

extension View {
    /// Fade + rise entrance, driven by an external "has appeared" flag.
    ///
    /// Takes the flag rather than owning `@State` so a parent can replay the
    /// entrance when its content changes identity. Under Reduce Motion the
    /// content simply appears: no offset, no animation.
    func riseIn(_ shown: Bool, index: Int = 0, distance: CGFloat = 10) -> some View {
        modifier(RiseIn(shown: shown, index: index, distance: distance))
    }
}

private struct RiseIn: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let shown: Bool
    let index: Int
    let distance: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : distance)
            .animation(reduceMotion ? nil : RMotion.stagger(index), value: shown)
    }
}
