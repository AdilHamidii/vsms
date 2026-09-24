import SwiftUI

/// The colored contact circle every phone app has — used on recents rows,
/// conversation rows, thread headers and the in-call screen so a peer looks
/// like the same person everywhere.
///
/// Deterministic: the color is a stable hash of the E.164, so a peer keeps
/// their color across launches and across screens. Named peers show their
/// initial; unnamed ones a person glyph — never a guessed letter from the
/// phone number.
struct PeerAvatar: View {
    @Environment(\.theme) private var theme
    let e164: String
    var name: String? = nil
    var size: CGFloat = 44
    /// The My number tab's lists (spec §4.3, one-green rule): a `chipBg` disc
    /// with a `text2` glyph instead of the hashed colour.
    var neutral: Bool = false

    /// A fixed palette, deliberately independent of the user's accent choice:
    /// avatars must not all turn green, and none of these are `live`/`warn`/
    /// `fail`, which stay semantic. Muted enough to hold white glyphs in both
    /// light and dark.
    private static let palette: [Color] = [
        Color(hex: 0x5B7DB1), // slate blue
        Color(hex: 0x8E6FB0), // violet
        Color(hex: 0xB1685B), // clay
        Color(hex: 0x5BA3A0), // teal
        Color(hex: 0xB08A4F), // ochre
        Color(hex: 0x7A8B5B), // olive
        Color(hex: 0xA05B7C), // plum
        Color(hex: 0x607886), // steel
    ]

    /// Stable across launches — `Hasher` is seeded per process, so it must
    /// not be used here. A simple FNV-1a over the digits is enough.
    private var color: Color {
        var h: UInt64 = 0xcbf29ce484222325
        for b in e164.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return Self.palette[Int(h % UInt64(Self.palette.count))]
    }

    private var initial: String? {
        guard let first = name?.trimmingCharacters(in: .whitespaces).first
        else { return nil }
        return String(first).uppercased()
    }

    var body: some View {
        ZStack {
            Circle().fill(neutral ? theme.chipBg : color)
            if let initial {
                Text(verbatim: initial)
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(neutral ? theme.text2 : .white)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(neutral ? theme.text2 : .white.opacity(0.92))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true) // decorative; the row's text carries the peer
    }
}
