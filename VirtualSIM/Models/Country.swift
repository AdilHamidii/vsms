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

    /// MEASURED delivery for this country across every service, over 30 days,
    /// scoped to the ACTIVE provider (`refresh_country_delivery`). Nil until
    /// there is traffic.
    ///
    /// Steering input only — deliberately never rendered. It is not a claim
    /// about the specific route on screen, and the badge must keep saying
    /// exactly what was measured for that pair and nothing else.
    ///
    /// This exists because route-level evidence is far too sparse to steer
    /// with (7 of ~17,800 routes have ever delivered), so every untested route
    /// fell through to a tie-break on price — which is how a new user landed on
    /// the cheapest country in the catalog on almost every service.
    var observedAttempts: Int?
    var observedCodes: Int?

    /// Measured delivery ratio, or nil when we have never had a conclusive
    /// order here. A country with attempts but no codes returns 0, which is a
    /// real signal and must not be conflated with "unknown".
    var deliveryRatio: Double? {
        guard let a = observedAttempts, a > 0, let c = observedCodes else { return nil }
        return Double(c) / Double(a)
    }

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
