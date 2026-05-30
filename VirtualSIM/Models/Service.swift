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

    /// Logo URL via Clearbit's free logo API. Review terms at clearbit.com/logo
    /// before shipping at high volume.
    var logoURL: URL? {
        guard let domain, !domain.isEmpty else { return nil }
        return URL(string: "https://logo.clearbit.com/\(domain)?size=128")
    }
}
