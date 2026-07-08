import SwiftUI

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

    static let light = Theme(
        bg:        Color(hex: 0xF2F2F7),
        elev:      Color(hex: 0xFFFFFF),
        elev2:     Color(hex: 0xF7F7F9),
        text:      Color(hex: 0x0A0A0B),
        text2:     Color(red: 60/255, green: 60/255, blue: 67/255, opacity: 0.62),
        text3:     Color(red: 60/255, green: 60/255, blue: 67/255, opacity: 0.38),
        sep:       Color(red: 60/255, green: 60/255, blue: 67/255, opacity: 0.12),
        sepStrong: Color(red: 60/255, green: 60/255, blue: 67/255, opacity: 0.22),
        ink:       Color(hex: 0x279400),
        inkSoft:   Color(red: 39/255, green: 148/255, blue: 0/255, opacity: 0.10),
        onInk:     .white,
        live:      Color(hex: 0x279400),
        liveSoft:  Color(red: 39/255, green: 148/255, blue: 0/255, opacity: 0.12),
        warn:      Color(hex: 0xB5751A),
        warnSoft:  Color(red: 181/255, green: 117/255, blue: 26/255, opacity: 0.10),
        fail:      Color(hex: 0xB8443A),
        failSoft:  Color(red: 184/255, green: 68/255, blue: 58/255, opacity: 0.10),
        glow:      Color(red: 39/255, green: 148/255, blue: 0/255, opacity: 0.22),
        chipBg:    Color(red: 60/255, green: 60/255, blue: 67/255, opacity: 0.06),
        isDark:    false
    )

    static let dark = Theme(
        bg:        Color(hex: 0x000000),
        elev:      Color(hex: 0x1C1C1E),
        elev2:     Color(hex: 0x2C2C2E),
        text:      Color(hex: 0xFFFFFF),
        text2:     Color(red: 235/255, green: 235/255, blue: 245/255, opacity: 0.62),
        text3:     Color(red: 235/255, green: 235/255, blue: 245/255, opacity: 0.32),
        sep:       Color(red: 84/255, green: 84/255, blue: 88/255, opacity: 0.45),
        sepStrong: Color(red: 84/255, green: 84/255, blue: 88/255, opacity: 0.85),
        ink:       Color(hex: 0x33B81F),
        inkSoft:   Color(red: 51/255, green: 184/255, blue: 31/255, opacity: 0.14),
        onInk:     .white,
        live:      Color(hex: 0x33B81F),
        liveSoft:  Color(red: 51/255, green: 184/255, blue: 31/255, opacity: 0.16),
        warn:      Color(hex: 0xD29545),
        warnSoft:  Color(red: 210/255, green: 149/255, blue: 69/255, opacity: 0.14),
        fail:      Color(hex: 0xD9645A),
        failSoft:  Color(red: 217/255, green: 100/255, blue: 90/255, opacity: 0.14),
        glow:      Color(red: 51/255, green: 184/255, blue: 31/255, opacity: 0.28),
        chipBg:    Color.white.opacity(0.06),
        isDark:    true
    )
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
    @Entry var theme: Theme = .light
}
