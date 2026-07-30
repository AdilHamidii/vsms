import Foundation

enum EsimStatus: String, Codable, Hashable {
    case provisioning, installed, active, depleted, expired, refunded, failed

    /// Whether this state can still change — i.e. whether it is worth spending
    /// a provider round-trip on. Terminal states never move again.
    var keepsPolling: Bool {
        switch self {
        case .provisioning, .installed, .active: true
        case .depleted, .expired, .refunded, .failed: false
        }
    }

    var label: String {
        switch self {
        case .provisioning: String(localized: "Preparing")
        case .installed:    String(localized: "Ready to install")
        case .active:       String(localized: "Active")
        case .depleted:     String(localized: "Data used up")
        case .expired:      String(localized: "Expired")
        case .refunded:     String(localized: "Refunded")
        case .failed:       String(localized: "Failed")
        }
    }
    var isLive: Bool { self == .installed || self == .active || self == .provisioning }
}

/// Catalog row from `esim_plans` (decoded via .convertFromSnakeCase).
struct EsimPlan: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let countryCode: String?
    let region: String?
    let dataMb: Int?
    let validityDays: Int?
    let speed: String?
    let extendable: Bool?
    let retailCredits: Int?
    let status: String

    var dataLabel: String {
        guard let mb = dataMb else { return "—" }
        return EsimFormat.data(mb)
    }
    var validityLabel: String {
        guard let d = validityDays else { return "—" }
        // String(localized:) — a plain String return is NOT auto-localized
        // the way a `Text("literal")` is, so these never reached the catalog.
        return d == 1 ? String(localized: "1 day") : String(localized: "\(d) days")
    }
    /// 2-letter code for flag lookup, lowercased to match our Country ids.
    var flagCode: String { (countryCode ?? "").lowercased() }
}

/// One destination in the eSIM store: a country plus what it costs to enter.
///
/// Replaces the `(code:name:from:)` tuple `esimCountries` used to return. A
/// tuple cannot be `Identifiable`, so every `ForEach` over it had to key on
/// `\.element.code` through an `enumerated()` wrapper, and the map needs to
/// pass one of these through a selection binding — which a tuple also cannot do.
struct EsimCountryEntry: Identifiable, Hashable {
    /// ISO 3166-1 alpha-2, exactly as `esim_plans.country_code` stores it.
    let code: String
    let name: String
    let fromCredits: Int
    let planCount: Int

    var id: String { code }
}

/// Server row from `esim_orders`.
struct ServerEsimOrder: Codable, Hashable, Identifiable {
    let id: String
    let planId: String?
    let smspoolTx: String?
    let costCredits: Int
    let status: EsimStatus
    let activationCode: String?
    let smdpAddress: String?
    let matchingId: String?
    let apn: String?
    // iOS prompts for the SIM PIN while the line activates. The backend has
    // stored these since 2026-07-21, but they were absent here — so
    // .convertFromSnakeCase silently dropped sim_pin/sim_puk on decode and the
    // value never reached the screen. The user cannot bring the eSIM up and it
    // reads to them as "the data plan doesn't work".
    let simPin: String?
    let simPuk: String?
    let dataTotalMb: Int?
    let dataUsedMb: Int?
    let activated: Bool
    let activatedAt: Date?
    let expiresAt: Date?
    let createdAt: Date
}

/// UI-facing eSIM order: the server row + its resolved catalog plan.
struct EsimOrder: Identifiable, Hashable {
    let server: ServerEsimOrder
    let plan: EsimPlan?

    var id: String { server.id }
    var status: EsimStatus { server.status }
    var name: String { plan?.name ?? "eSIM" }
    var activationCode: String? { server.activationCode }
    var smdp: String? { server.smdpAddress }
    var manualCode: String? { server.matchingId }
    var apn: String? { server.apn }
    var simPin: String? { server.simPin }
    var simPuk: String? { server.simPuk }
    var createdAt: Date { server.createdAt }
    var expiresAt: Date? { server.expiresAt }

    var dataTotalMb: Int? { server.dataTotalMb ?? plan?.dataMb }
    var dataUsedMb: Int { server.dataUsedMb ?? 0 }
    var dataUsedFraction: Double {
        guard let total = dataTotalMb, total > 0 else { return 0 }
        return min(1, Double(dataUsedMb) / Double(total))
    }
    var dataRemainingLabel: String {
        guard let total = dataTotalMb else { return "—" }
        return String(localized: "\(EsimFormat.data(max(0, total - dataUsedMb))) left")
    }
}


/// One MB→GB formatter for the whole eSIM flow.
///
/// There were two, and they disagreed: the store truncated (`1500 MB` → "1 GB")
/// while the detail screen used one decimal ("1.5 GB left"), so the same plan
/// advertised a different size depending on which screen you were looking at.
/// Trailing ".0" is dropped so a clean 2 GB plan doesn't read "2.0 GB".
enum EsimFormat {
    static func data(_ mb: Int) -> String {
        guard mb >= 1000 else { return "\(mb) MB" }
        let gb = Double(mb) / 1000
        return gb == gb.rounded()
            ? "\(Int(gb)) GB"
            : String(format: "%.1f GB", gb)
    }
}
