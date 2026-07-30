import Foundation

/// Mirrors the `email_status` PG enum exactly.
///
/// Ours, not the provider's: HeroSMS's vocabulary is undocumented and only ever
/// returned `WAIT` and `CANCEL` under probing, and `CANCEL` is overloaded
/// between a user cancel and its own ~20-minute timeout. The server resolves
/// all of that before it reaches here.
enum EmailStatus: String, Hashable, Codable {
    case waiting, received, canceled, expired, failed

    /// Keep polling while the activation can still change. Same role as
    /// `EsimStatus.keepsPolling` — one predicate, so no screen invents its own.
    var keepsPolling: Bool { self == .waiting }

    var isTerminal: Bool { !keepsPolling }

    var label: String {
        switch self {
        case .waiting:  String(localized: "Waiting")
        case .received: String(localized: "Code received")
        case .canceled: String(localized: "Canceled")
        case .expired:  String(localized: "Expired")
        case .failed:   String(localized: "Failed")
        }
    }
}

/// One sellable mail domain for a given service, as `email-domains` returns it.
struct EmailDomainOption: Codable, Hashable, Identifiable {
    let domain: String
    /// What WE charge. 0 = free.
    let credits: Int
    /// Live provider stock for this (service, domain). 0 = cannot be bought.
    let available: Int

    var id: String { domain }
    var isFree: Bool { credits == 0 }
    var inStock: Bool { available > 0 }

    /// Brand label. The domain IS the product here, so it is shown verbatim —
    /// never localized, and never prettified into "Google Mail".
    var displayName: String { domain }
}

struct EmailDomainsResponse: Codable {
    let site: String
    let domains: [EmailDomainOption]
}

/// A row of `email_orders`, decoded with `.convertFromSnakeCase`.
///
/// A field missing from this struct is dropped SILENTLY rather than raising —
/// that is how the eSIM SIM PIN sat in the database for a day without ever
/// reaching the screen. Add fields here when the table grows.
struct ServerEmailOrder: Codable, Hashable, Identifiable {
    let id: String
    let serviceId: String?
    let site: String
    let domain: String
    let email: String?
    let costCredits: Int
    let status: EmailStatus
    let code: String?
    let createdAt: String?
    let expiresAt: String?

    /// **The authority for "a code arrived" — never `status == .received`.**
    /// Same rule the SMS side had to learn when a rescued code living on a
    /// canceled row was scored as a delivery failure.
    var hasCode: Bool { !(code ?? "").isEmpty }

    /// Paid orders that ended without a code are refunded server-side. Free
    /// ones have nothing to give back, so claiming a refund would be a lie.
    var wasRefunded: Bool { costCredits > 0 && status.isTerminal && !hasCode }
}
