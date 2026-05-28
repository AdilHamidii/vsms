import SwiftUI

struct Service: Identifiable, Hashable {
    let id: String
    let name: String
    let category: String
    let glyph: String
    let tint: Color
    let cost: Int
    let successRate: Int
    let etaSeconds: Int
}
