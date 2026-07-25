import SwiftUI

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
        case .blue:   0x0A6CD6
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
        case .blue:   0x3B9EFF
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
    let glow: Color
    let chipBg: Color
    let isDark: Bool

    /// `live`/`liveSoft` stay the semantic success green at every accent — see
    /// the note on `AccentColor`.
    static func light(_ accent: AccentColor = .green) -> Theme {
        let a = accent.lightHex
        return Theme(
            bg:        Color(hex: 0xF2F2F7),
            elev:      Color(hex: 0xFFFFFF),
            elev2:     Color(hex: 0xF7F7F9),
            text:      Color(hex: 0x0A0A0B),
            text2:     Color(red: 60/255, green: 60/255, blue: 67/255, opacity: 0.62),
            text3:     Color(red: 60/255, green: 60/255, blue: 67/255, opacity: 0.38),
            sep:       Color(red: 60/255, green: 60/255, blue: 67/255, opacity: 0.12),
            sepStrong: Color(red: 60/255, green: 60/255, blue: 67/255, opacity: 0.22),
            ink:       Color(hex: a),
            inkSoft:   Color(hex: a, opacity: 0.10),
            onInk:     .white,
            live:      Color(hex: 0x279400),
            liveSoft:  Color(red: 39/255, green: 148/255, blue: 0/255, opacity: 0.12),
            warn:      Color(hex: 0xB5751A),
            warnSoft:  Color(red: 181/255, green: 117/255, blue: 26/255, opacity: 0.10),
            fail:      Color(hex: 0xB8443A),
            failSoft:  Color(red: 184/255, green: 68/255, blue: 58/255, opacity: 0.10),
            glow:      Color(hex: a, opacity: 0.22),
            chipBg:    Color(red: 60/255, green: 60/255, blue: 67/255, opacity: 0.06),
            isDark:    false
        )
    }

    static func dark(_ accent: AccentColor = .green) -> Theme {
        let a = accent.darkHex
        return Theme(
            bg:        Color(hex: 0x000000),
            elev:      Color(hex: 0x1C1C1E),
            elev2:     Color(hex: 0x2C2C2E),
            text:      Color(hex: 0xFFFFFF),
            text2:     Color(red: 235/255, green: 235/255, blue: 245/255, opacity: 0.62),
            text3:     Color(red: 235/255, green: 235/255, blue: 245/255, opacity: 0.32),
            sep:       Color(red: 84/255, green: 84/255, blue: 88/255, opacity: 0.45),
            sepStrong: Color(red: 84/255, green: 84/255, blue: 88/255, opacity: 0.85),
            ink:       Color(hex: a),
            inkSoft:   Color(hex: a, opacity: 0.14),
            onInk:     .white,
            live:      Color(hex: 0x33B81F),
            liveSoft:  Color(red: 51/255, green: 184/255, blue: 31/255, opacity: 0.16),
            warn:      Color(hex: 0xD29545),
            warnSoft:  Color(red: 210/255, green: 149/255, blue: 69/255, opacity: 0.14),
            fail:      Color(hex: 0xD9645A),
            failSoft:  Color(red: 217/255, green: 100/255, blue: 90/255, opacity: 0.14),
            glow:      Color(hex: a, opacity: 0.28),
            chipBg:    Color.white.opacity(0.06),
            isDark:    true
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
