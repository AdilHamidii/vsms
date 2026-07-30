import SwiftUI

/// Liquid Glass for floating chrome, with a working iOS 18 path.
///
/// **The availability check lives here and nowhere else.** The deployment
/// target is 18.0 — deliberately, since the old 26.2 floor excluded almost the
/// entire install base — so every glass surface needs an `#available` guard and
/// a fallback that still looks finished. Scattering that check across the tab
/// bar, the resume bar and the map overlays is exactly how one of them ends up
/// with a subtly different fallback nobody notices, because the majority of
/// devices only ever render the fallback.
///
/// The iOS 18 path is the treatment the tab bar already shipped: a
/// near-opaque fill over `.ultraThinMaterial` with a hairline border. That
/// reads as frosted rather than as a failed glass effect.
///
/// Applied only to surfaces that genuinely FLOAT over content — tab bar, resume
/// bar, map overlays. Apple's own guidance is that glass is for the navigation
/// layer, and putting it on inline cards makes text sit on unpredictable
/// backgrounds while destroying the elevation hierarchy that `theme.elev`
/// already expresses.
struct GlassPanel<S: Shape>: ViewModifier {
    @Environment(\.theme) private var theme

    let shape: S
    /// `interactive` gives the glass Apple's touch-reactive highlight. Use it on
    /// things that are tapped (buttons), not on passive containers.
    var interactive: Bool = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular,
                                in: shape)
        } else {
            content.background {
                shape
                    .fill(theme.isDark ? Color(hex: 0x1C1C1E).opacity(0.78)
                                       : Color.white.opacity(0.78))
                    .background(.ultraThinMaterial, in: shape)
                    .overlay(shape.stroke(theme.sep, lineWidth: 0.5))
            }
        }
    }
}

extension View {
    /// Frosted floating surface. See `GlassPanel` for why the guard is central.
    func glassPanel<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        modifier(GlassPanel(shape: shape, interactive: interactive))
    }
}
