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

    /// Minimum conclusive orders before a country's rate is worth steering on.
    /// Matches `p_min_sample` in `refresh_route_observed_success`.
    static let minDeliverySample = 3

    /// Measured delivery ratio, or nil when we have too little to say. A
    /// country with attempts but no codes returns 0, which is a real signal and
    /// must not be conflated with "unknown".
    ///
    /// The sample floor is load-bearing, not defensive tidiness. Without it
    /// three countries sitting at **1 of 1** (se, mx, at) scored a perfect
    /// 1.0 and outranked Netherlands at 7 of 10 and Romania at 10 of 18 — so
    /// the steering would have sent every new user to whichever country
    /// happened to have exactly one lucky order. Same failure the badge rules
    /// already guard against: a ratio off a tiny sample wears the confidence of
    /// a large one.
    var deliveryRatio: Double? {
        guard let a = observedAttempts, a >= Self.minDeliverySample,
              let c = observedCodes else { return nil }
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
