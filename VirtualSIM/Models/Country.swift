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

    /// flagcdn.com uses ISO 3166-1 alpha-2 lowercase. Our `uk` id maps to `gb`.
    var flagImageCode: String {
        switch id {
        case "uk": return "gb"
        default:   return id
        }
    }

    /// Wide flag PNG suitable for square / rounded-square chips.
    func flagImageURL(width: Int = 160) -> URL? {
        URL(string: "https://flagcdn.com/w\(width)/\(flagImageCode).png")
    }
}
