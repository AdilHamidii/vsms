import SwiftUI

/// A pinned action area that content dissolves into, rather than hits.
///
/// Every purchase screen in the app needs this and only the eSIM checkout had
/// it — the subscription paywall, the more valuable screen, scrolled into a
/// hard edge under an opaque bar, which makes the page look truncated rather
/// than continued. The gradient is what tells the eye there is more above.
struct BottomBar<Content: View>: View {
    @Environment(\.theme) private var theme
    var scrimHeight: CGFloat = 56
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [theme.bg.opacity(0), theme.bg],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: scrimHeight)
                .allowsHitTesting(false)

            content
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
                .background(theme.bg)
        }
    }
}

/// A tracked, uppercase micro-label — the app's only section-header device.
///
/// Small, quiet and editorial, at 42% ink. It is the counterweight that lets
/// display type be genuinely large without the screen feeling shouty: hierarchy
/// comes from the RANGE between the biggest and smallest thing on screen, and
/// the app previously had almost none — 176 uses under 14pt against a handful
/// of display sizes.
struct MicroLabel: View {
    @Environment(\.theme) private var theme
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(RFont.text(11, weight: .heavy))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(theme.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small status pill — "Available now", "In stock", "Best value".
///
/// Reads as a live signal rather than as body text, which is what the paywall's
/// availability line was doing at 38% opacity: spending the one slot designed
/// for presence on the faintest ink on the screen.
struct StatusPill: View {
    @Environment(\.theme) private var theme
    var text: LocalizedStringKey
    var tint: Color? = nil
    var soft: Color? = nil
    var dot: Bool = true

    var body: some View {
        HStack(spacing: 6) {
            if dot {
                Circle()
                    .fill(tint ?? theme.live)
                    .frame(width: 6, height: 6)
            }
            Text(text)
                .font(RFont.text(12, weight: .semibold))
                .foregroundStyle(tint ?? theme.live)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(soft ?? theme.liveSoft, in: Capsule())
    }
}
