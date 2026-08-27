import SwiftUI
import UIKit

/// The app's brand colour, user-selectable in Account → Appearance.
///
/// Drives `ink` / `inkSoft` / `glow` only — the primary button, the hero CTA,
/// selected tabs, focus rings. It deliberately does NOT touch `live`, `warn`
/// or `fail`, which are SEMANTIC: green means "your code arrived" and "your
/// credits came back", amber and red mean a route is doubtful or dead. Letting
/// an accent recolour those would undo the delivery-honesty work — a refund
/// receipt rendered in the user's favourite red reads as an error, and a
/// measured-good badge in grey reads as no data. Same separation iOS itself
/// draws between the accent colour and its semantic system colours.
enum AccentColor: String, CaseIterable, Identifiable, Codable {
    case green, blue, indigo, purple, pink, orange

    var id: String { rawValue }

    var label: String {
        switch self {
        case .green:  String(localized: "Green")
        case .blue:   String(localized: "Blue")
        case .indigo: String(localized: "Indigo")
        case .purple: String(localized: "Purple")
        case .pink:   String(localized: "Pink")
        case .orange: String(localized: "Orange")
        }
    }

    /// Darker on light backgrounds: `onInk` is white, so the button fill has
    /// to stay dark enough to carry white text.
    var lightHex: UInt32 {
        switch self {
        case .green:  0x279400
        // Brand blue. White on this measures **5.52:1**, where white on the old
        // brand green (`0x279400`) measured **3.95:1** — i.e. every primary
        // button in the app failed WCAG AA for normal text, and this fixes it.
        case .blue:   0x0057FF
        case .indigo: 0x4B3FCF
        case .purple: 0x8A3FBF
        case .pink:   0xC2306B
        case .orange: 0xC2611A
        }
    }

    /// Brighter on black, matching the existing dark-theme green's lift.
    var darkHex: UInt32 {
        switch self {
        case .green:  0x33B81F
        // Lightened for dark mode. The light-mode `0x0057FF` measures only
        // **3.81:1** on black, which is below AA even for large text; this
        // measures 6.56:1 at the same hue.
        case .blue:   0x4C8DFF
        case .indigo: 0x7C6BFF
        case .purple: 0xB57BEA
        case .pink:   0xF06496
        case .orange: 0xE8933D
        }
    }

    func hex(isDark: Bool) -> UInt32 { isDark ? darkHex : lightHex }

    /// Swatch for the picker — always shown on the surface it will be used on.
    func swatch(isDark: Bool) -> Color { Color(hex: hex(isDark: isDark)) }
}

/// Light / dark preference, including the option to follow the device.
///
/// This replaces a plain `isDark` Bool that defaulted to **false**, so the app
/// — and the splash, which is the very first thing anyone sees — rendered LIGHT
/// on a dark-mode phone until the user found the toggle in Account. There was
/// no way to say "follow my device" at all, which is the setting most people
/// assume they already have.
///
/// `.system` is the default, so the static launch screen (an adaptive colour
/// set), the splash and the app all resolve to the same appearance and the
/// launch has no flash.
enum AppearanceMode: String, CaseIterable, Identifiable, Codable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: String(localized: "System")
        case .light:  String(localized: "Light")
        case .dark:   String(localized: "Dark")
        }
    }

    /// What to hand `.preferredColorScheme`. **nil means "don't override"** —
    /// that is what actually lets the device decide, and is why this is
    /// `ColorScheme?` rather than a Bool.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light:  .light
        case .dark:   .dark
        }
    }

    /// Resolve to a concrete appearance. `system` is the only case that needs
    /// the ambient value, so callers pass the environment's `colorScheme`.
    func isDark(system: ColorScheme) -> Bool {
        switch self {
        case .system: system == .dark
        case .light:  false
        case .dark:   true
        }
    }
}

/// Corner radii, as a scale rather than a per-call-site guess.
///
/// The app had eight radii in circulation (22, 18, 17, 16, 15, 14, 12, 10)
/// chosen independently at each call site, which is most of why surfaces read
/// as unrelated. Nested shapes must differ by their padding, never by taste.
enum RRadius {
    static let xs: CGFloat = 10   // inline tiles, tags
    static let sm: CGFloat = 14   // icon tiles, small chips
    static let md: CGFloat = 18   // rows, buttons, bubbles
    static let lg: CGFloat = 22   // standard card
    static let xl: CGFloat = 28   // hero surfaces
}

/// How far a surface sits off the canvas.
///
/// The app had **twelve** `.shadow(` calls and not one of them was a content
/// card, so every surface was flat and the eye had nothing to rank. This is the
/// missing axis. `Card(elevation:)` applies it; call sites never hand-roll a
/// shadow again.
enum RElevation {
    case flat    // e0 — sits in the canvas (inline groups, list rows)
    case raised  // e1 — an ordinary card
    case lifted  // e2 — a card that matters on this screen
    case hero    // e3 — the one object the screen is about, carries accent glow

    var radius: CGFloat {
        switch self {
        case .flat:   0
        case .raised: 12
        case .lifted: 20
        case .hero:   30
        }
    }

    var y: CGFloat {
        switch self {
        case .flat:   0
        case .raised: 5
        case .lifted: 9
        case .hero:   14
        }
    }
}

struct Theme: Equatable {
    let bg: Color
    let elev: Color
    let elev2: Color
    let text: Color
    let text2: Color
    let text3: Color
    let sep: Color
    let sepStrong: Color
    let ink: Color
    let inkSoft: Color
    let onInk: Color
    let live: Color
    let liveSoft: Color
    let warn: Color
    let warnSoft: Color
    let fail: Color
    let failSoft: Color
    let chipBg: Color
    let isDark: Bool

    /// The accent, shifted toward the ink so it is legible as TEXT on a card.
    ///
    /// Raw `ink` is tuned to carry white on a filled button and is too saturated
    /// for small type on a surface. Three-step law, and it is worth stating
    /// because breaking it is what makes an accent look cheap:
    ///   `ink`      — solid fills only, content is `onInk`
    ///   `accent2`  — accent-tinted TEXT and ICONS on a card or the canvas
    ///   `inkSoft`  — washes behind icon tiles and chips
    let accent2: Color

    /// A track/groove for meters, and the fill of an unselected segment. One
    /// step above `chipBg`, so a bar reads as recessed rather than as a chip.
    let track: Color

    /// The colour a shadow is drawn in. One value for both modes on purpose:
    /// in dark it is nearly invisible and the LAYERS value-ladder
    /// (`bg` → `elev` → `elev2` → `track`) does the lifting instead.
    let shadowTint: Color

    /// `live`/`liveSoft` stay the semantic success green at every accent — see
    /// the note on `AccentColor`.
    /// Light mode — warm paper, pure-white cards, near-black WARM ink.
    ///
    /// The ink moved from `0x0A0A0B` (a cold near-black) to `0x17181A`, and
    /// `text2`/`text3` are now alpha steps of that same ink rather than iOS's
    /// blue-grey `60,60,67`. Deriving the secondary tones from the primary is
    /// what makes a greyscale read as one family instead of three unrelated
    /// greys, and it is most of the difference between "system default" and
    /// "someone chose this".
    static func light(_ accent: AccentColor = .green) -> Theme {
        let a = accent.lightHex
        let ink = Color(hex: 0x17181A)
        return Theme(
            bg:        Color(hex: 0xF6F5F2),
            elev:      Color(hex: 0xFFFFFF),
            elev2:     Color(hex: 0xECEBE7),
            text:      ink,
            text2:     Color(hex: 0x17181A, opacity: 0.58),
            text3:     Color(hex: 0x17181A, opacity: 0.42),
            sep:       Color(hex: 0x17181A, opacity: 0.08),
            sepStrong: Color(hex: 0x17181A, opacity: 0.16),
            ink:       Color(hex: a),
            inkSoft:   Color(hex: a, opacity: 0.12),
            onInk:     .white,
            live:      Color(hex: 0x0E9F6E),
            liveSoft:  Color(hex: 0x0E9F6E, opacity: 0.13),
            warn:      Color(hex: 0xC7911B),
            warnSoft:  Color(hex: 0xC7911B, opacity: 0.13),
            fail:      Color(hex: 0xDC5050),
            failSoft:  Color(hex: 0xDC5050, opacity: 0.12),
            chipBg:    Color(hex: 0x17181A, opacity: 0.055),
            isDark:    false,
            accent2:   Color(hex: a).mixed(with: ink, amount: 0.22),
            track:     Color(hex: 0xE3E2DE),
            shadowTint: Color(hex: 0x17181A)
        )
    }

    /// Dark mode — a LAYERED near-black, not pure black.
    ///
    /// `bg` was `0x000000` with a single `0x1C1C1E` card on top, so dark mode
    /// had exactly one step of depth and everything below a card was the same
    /// void. The ladder is now `0x0A0A0C` → `0x151518` → `0x1F1F24` → `0x2A2A31`,
    /// roughly +8–14 luminance per step, and **that ladder is the elevation
    /// system in dark** — the shadows below are almost invisible here by design.
    ///
    /// Ink is a warm off-white `0xF8F7F4`, never pure white: pure white on
    /// near-black is the highest-glare pairing available and is what makes a
    /// dark theme feel harsh.
    static func dark(_ accent: AccentColor = .green) -> Theme {
        let a = accent.darkHex
        let ink = Color(hex: 0xF8F7F4)
        return Theme(
            bg:        Color(hex: 0x0A0A0C),
            elev:      Color(hex: 0x151518),
            elev2:     Color(hex: 0x1F1F24),
            text:      ink,
            text2:     Color(hex: 0xF8F7F4, opacity: 0.56),
            text3:     Color(hex: 0xF8F7F4, opacity: 0.40),
            sep:       Color(hex: 0xF8F7F4, opacity: 0.07),
            sepStrong: Color(hex: 0xF8F7F4, opacity: 0.15),
            ink:       Color(hex: a),
            inkSoft:   Color(hex: a, opacity: 0.16),
            onInk:     .white,
            live:      Color(hex: 0x34D399),
            liveSoft:  Color(hex: 0x34D399, opacity: 0.15),
            warn:      Color(hex: 0xFFC53D),
            warnSoft:  Color(hex: 0xFFC53D, opacity: 0.14),
            fail:      Color(hex: 0xF87171),
            failSoft:  Color(hex: 0xF87171, opacity: 0.14),
            chipBg:    Color(hex: 0xF8F7F4, opacity: 0.07),
            isDark:    true,
            accent2:   Color(hex: a).mixed(with: ink, amount: 0.30),
            track:     Color(hex: 0x2A2A31),
            shadowTint: Color(hex: 0x000000)
        )
    }

    /// The shadow for an elevation step, already carrying the right opacity for
    /// this appearance. In dark it is nearly nothing — the value ladder lifts
    /// surfaces there, and a heavy shadow on near-black only muddies it.
    func shadow(_ e: RElevation) -> Color {
        guard e != .flat else { return .clear }
        let alpha: Double
        switch e {
        case .flat:   alpha = 0
        case .raised: alpha = isDark ? 0.22 : 0.05
        case .lifted: alpha = isDark ? 0.30 : 0.08
        case .hero:   alpha = isDark ? 0.40 : 0.11
        }
        return shadowTint.opacity(alpha)
    }
}

extension Color {
    /// Linear blend toward another colour, used to derive the accent's text
    /// variant from its fill variant so the two can never drift apart.
    func mixed(with other: Color, amount: Double) -> Color {
        let t = max(0, min(1, amount))
        let a = UIColor(self), b = UIColor(other)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1c: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2c: CGFloat = 0, a2: CGFloat = 0
        a.getRed(&r1, green: &g1, blue: &b1c, alpha: &a1)
        b.getRed(&r2, green: &g2, blue: &b2c, alpha: &a2)
        return Color(
            .sRGB,
            red:     Double(r1 + (r2 - r1) * t),
            green:   Double(g1 + (g2 - g1) * t),
            blue:    Double(b1c + (b2c - b1c) * t),
            opacity: Double(a1 + (a2 - a1) * t)
        )
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        self.init(
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >>  8) & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255,
            opacity: opacity
        )
    }

    init(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            self = .gray
            return
        }
        self.init(hex: v)
    }
}

extension EnvironmentValues {
    @Entry var theme: Theme = .light()
}
