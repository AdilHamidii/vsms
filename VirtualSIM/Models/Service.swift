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
    /// Source 1 (DuckDuckGo ip3): apple-touch-icon quality, no API key, reliable.
    /// Source 2 (Google FaviconV2): any domain with a favicon, up to 128px.
    /// If both fail, ServiceLogo falls back to an SF Symbol on a tinted square.
    ///
    /// NOTE: Clearbit's free Logo API (logo.clearbit.com) was shut down by HubSpot
    /// on 2025-12-01 — its host no longer resolves, so it was removed. Leaving it
    /// in the cascade made every logo eat a DNS failure (often a long hang) before
    /// falling through, which read as "logos not loading."
    var logoURLs: [URL] {
        guard let domain, !domain.isEmpty else { return [] }
        let escaped = "https%3A%2F%2F\(domain)"
        return [
            URL(string: "https://icons.duckduckgo.com/ip3/\(domain).ico"),
            URL(string: "https://t2.gstatic.com/faviconV2?client=SOCIAL&type=FAVICON&fallback_opts=TYPE,SIZE,URL&url=\(escaped)&size=128"),
        ].compactMap { $0 }
    }
}
