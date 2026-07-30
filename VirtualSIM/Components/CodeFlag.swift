import SwiftUI

/// cc "AT" -> 🇦🇹
///
/// Lives here rather than in `EsimStoreScreen` (its original home) because the
/// checkout and detail screens call it too, and a global helper defined inside
/// a screen file disappears the moment that screen is restructured.
func flagEmoji(_ cc: String) -> String {
    let base: UInt32 = 127397
    var s = ""
    for u in cc.uppercased().unicodeScalars where u.value >= 65 && u.value <= 90 {
        if let sc = Unicode.Scalar(base + u.value) { s.unicodeScalars.append(sc) }
    }
    return s.isEmpty ? "🌐" : s
}

/// A flag identified by a bare ISO 3166-1 alpha-2 code.
///
/// `FlagCircle`/`FlagImage` both take a `Country`, which the eSIM catalog does
/// not have: `esim_plans` carries `country_code` and the SMS `countries` table
/// is a different, only-overlapping set (66 eSIM countries vs 69 SMS ones). The
/// old store worked around this with a bare `flagEmoji()` call, which renders as
/// a tofu box on any device whose font lacks the pair and gives the map nothing
/// to draw.
///
/// Same three-step cascade as `FlagCircle` so a code that IS bundled looks
/// identical on both screens: bundled PNG → flagcdn → emoji.
struct CodeFlag: View {
    @Environment(\.theme) private var theme
    let code: String
    var size: CGFloat = 36
    var style: FlagShape = .circle

    /// Named `FlagShape`, not `Shape`: a nested type called `Shape` inside a
    /// `View` shadows SwiftUI's own `Shape` protocol and breaks every
    /// `RoundedRectangle`/`clipShape` call in the same file.
    enum FlagShape { case circle, rounded }

    /// flagcdn and our bundled assets are both keyed lowercase.
    private var key: String { code.lowercased() }
    private var radius: CGFloat { style == .circle ? size / 2 : size * 0.28 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(theme.chipBg)

            if let bundled = BundledImageStore.shared.flag(forCode: key) {
                Image(uiImage: bundled)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            } else if let url = URL(string: "https://flagcdn.com/w160/\(key).png") {
                AsyncImage(url: url, transaction: Transaction(animation: RMotion.content)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                            .frame(width: size, height: size)
                            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    case .empty, .failure: emoji
                    @unknown default:      emoji
                    }
                }
            } else {
                emoji
            }
        }
        .frame(width: size, height: size)
    }

    private var emoji: some View {
        Text(flagEmoji(code))
            .font(.system(size: size * 0.58))
            .frame(width: size, height: size)
    }
}
