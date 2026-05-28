import SwiftUI

struct Service: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let category: String
    let glyph: String
    let tintHex: String
    let smspvaCode: String
    let cost: Int
    let successRate: Int
    let etaSeconds: Int
    var sortOrder: Int = 100

    var tint: Color { Color(hexString: tintHex) }
}
