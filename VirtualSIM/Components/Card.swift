import SwiftUI

/// The app's one surface primitive.
///
/// It used to be a bare `.background(theme.elev, in: .rect(cornerRadius: 22))`
/// — no shadow, no border, one radius. On light mode that is `#FFFFFF` on
/// `#F6F5F2`, a ~1.5% luminance step, so nothing on any screen read as raised
/// and the eye had no way to rank what mattered. Depth now comes from ONE
/// place, so a screen can say "this is the important object" without every call
/// site inventing its own shadow.
///
/// `border` is off by default and exists only to carry a SEMANTIC tint — an
/// amber caution surface, the accent on a selected plan. A hairline used as
/// decoration competes with the elevation and flattens it again.
struct Card<Content: View>: View {
    @Environment(\.theme) private var theme
    var radius: CGFloat = RRadius.lg
    var elevation: RElevation = .raised
    var fill: Color? = nil
    var border: Color? = nil
    @ViewBuilder var content: Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    var body: some View {
        content
            .background(fill ?? theme.elev, in: shape)
            .overlay {
                if let border {
                    shape.strokeBorder(border, lineWidth: 1)
                }
            }
            .clipShape(shape)
            .shadow(color: theme.shadow(elevation),
                    radius: elevation.radius, x: 0, y: elevation.y)
    }
}

/// The one object a screen is about — the number being bought, a delivered
/// code. Distinguished by its wash and a slightly stronger neutral shadow —
/// the accent glow it used to carry was removed app-wide with every other
/// colored halo (owner request, 2026-08-27).
struct HeroCard<Content: View>: View {
    @Environment(\.theme) private var theme
    var radius: CGFloat = RRadius.xl
    @ViewBuilder var content: Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    var body: some View {
        content
            .background {
                shape
                    .fill(theme.elev)
                    // A barely-there wash so the hero is a different MATERIAL
                    // from an ordinary card, not merely a bigger one.
                    .overlay(shape.fill(theme.inkSoft.opacity(0.35)))
            }
            .overlay(shape.strokeBorder(theme.sep, lineWidth: 1))
            .clipShape(shape)
            .shadow(color: theme.shadow(.lifted), radius: RElevation.lifted.radius,
                    x: 0, y: RElevation.lifted.y)
    }
}
