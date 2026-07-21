import Foundation

enum EsimStatus: String, Codable, Hashable {
    case provisioning, installed, active, depleted, expired, refunded, failed

    var label: String {
        switch self {
        case .provisioning: "Preparing"
        case .installed:    "Ready to install"
        case .active:       "Active"
        case .depleted:     "Data used up"
        case .expired:      "Expired"
        case .refunded:     "Refunded"
        case .failed:       "Failed"
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
        return mb >= 1000 ? "\(mb / 1000) GB" : "\(mb) MB"
    }
    var validityLabel: String {
        guard let d = validityDays else { return "—" }
        return d == 1 ? "1 day" : "\(d) days"
    }
    /// 2-letter code for flag lookup, lowercased to match our Country ids.
    var flagCode: String { (countryCode ?? "").lowercased() }
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
        let rem = max(0, total - dataUsedMb)
        return rem >= 1000 ? String(format: "%.1f GB left", Double(rem) / 1000) : "\(rem) MB left"
    }
}
