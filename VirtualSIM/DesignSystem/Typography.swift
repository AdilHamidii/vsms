import SwiftUI

enum RFont {
    /// Headline face. Same family as `text` — the difference is WEIGHT and
    /// optical tracking, applied by `.displayType()` below.
    ///
    /// ⚠️ `display` and `text` were byte-identical functions, so "display"
    /// was a naming convention with no rendering consequence and the app had
    /// no headline voice at all. The default weight is now `.bold`: a
    /// semibold 28pt headline over 13pt regular body is not enough contrast to
    /// establish a hierarchy, and hierarchy is what the eye uses to decide
    /// where to start reading.
    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Optical tracking: large type needs to be tightened, small type loosened.
    ///
    /// Call sites were hand-writing `-0.8`, `-0.7`, `-0.4`, `-0.3`, `-0.2`
    /// with no rule, so two 28pt headlines on different screens were spaced
    /// differently. This is the rule, in one place.
    static func tracking(for size: CGFloat) -> CGFloat {
        switch size {
        case ..<13:  0.1
        case ..<20:  0
        case ..<28:  -0.4
        default:     -0.8
        }
    }
}

extension View {
    /// Display type with its tracking already correct for the size.
    func displayType(_ size: CGFloat, weight: Font.Weight = .bold) -> some View {
        font(RFont.display(size, weight: weight))
            .tracking(RFont.tracking(for: size))
    }
}

struct MonoText: View {
    let text: String
    var size: CGFloat = 17
    var weight: Font.Weight = .regular
    var color: Color? = nil

    init(_ text: String, size: CGFloat = 17, weight: Font.Weight = .regular, color: Color? = nil) {
        self.text = text
        self.size = size
        self.weight = weight
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(RFont.mono(size, weight: weight))
            .foregroundStyle(color ?? .primary)
    }
}
