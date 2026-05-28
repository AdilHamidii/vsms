import Foundation

enum StockLevel: String, Hashable, Codable {
    case high, medium, low
}

struct Country: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let flag: String
    let dialCode: String
    let smspvaCode: String
    let stock: StockLevel
    let avgSeconds: Int
    var sortOrder: Int = 100
}
