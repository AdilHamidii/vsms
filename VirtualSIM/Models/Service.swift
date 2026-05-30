import SwiftUI

struct Service: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let category: String
    let glyph: String
    let icon: String?           // SF Symbol fallback
    let domain: String?         // Used to fetch the brand logo at runtime
    let tintHex: String
    let smspvaCode: String
    let cost: Int
    let successRate: Int
    let etaSeconds: Int
    var sortOrder: Int = 100

    var tint: Color { Color(hexString: tintHex) }

    /// Cascading list of logo sources, in priority order.
    /// Source 1 (Clearbit): transparent-background brand logos, best for SaaS.
    /// Source 2 (Google FaviconV2): works for any domain with a favicon, up to 128px.
    /// If both 404, ServiceLogo falls back to an SF Symbol on tinted square.
    var logoURLs: [URL] {
        guard let domain, !domain.isEmpty else { return [] }
        let escaped = "https%3A%2F%2F\(domain)"
        return [
            URL(string: "https://logo.clearbit.com/\(domain)?size=128"),
            URL(string: "https://t2.gstatic.com/faviconV2?client=SOCIAL&type=FAVICON&fallback_opts=TYPE,SIZE,URL&url=\(escaped)&size=128"),
        ].compactMap { $0 }
    }
}
