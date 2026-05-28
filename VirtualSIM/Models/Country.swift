import Foundation

enum StockLevel: String, Hashable {
    case high, medium, low
}

struct Country: Identifiable, Hashable {
    let id: String
    let name: String
    let flag: String
    let code: String
    let stock: StockLevel
    let avgSeconds: Int
}
