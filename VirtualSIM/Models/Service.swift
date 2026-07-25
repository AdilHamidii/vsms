import SwiftUI

struct Service: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let category: String
    let glyph: String
    let icon: String?           // SF Symbol fallback
    let domain: String?         // Used to fetch the brand logo at runtime
    let tintHex: String
    let smspvaCode: String
    let cost: Int
    let successRate: Int
    let etaSeconds: Int
    var sortOrder: Int = 100

    /// What actually happened on real orders for this service, over the last
    /// 30 days. `successRate` above is seed data and must never be shown as
    /// fact; these two are measured. Both nil until there is any traffic.
    var observedCodes: Int?
    var observedAttempts: Int?

    /// MEASURED arrival timing, written by `refresh_arrival_timing()`.
    /// `etaSeconds` above is seed data (22–35s across all 268 services, DB
    /// default 30, never recomputed) and measured median is ~53s — quoting the
    /// seed made the app promise a wait it could not keep, and users cancelled
    /// at a median of 63s believing the code was overdue. Use these instead;
    /// they are nil when the sample is too thin to say anything honest.
    var arrivalP50Seconds: Int?
    var arrivalP90Seconds: Int?
    var arrivalSample: Int?
    /// "service" (this service's own orders) or "global" (all services).
    /// The UI MUST NOT phrase a global band as service-specific.
    var arrivalScope: String?
    var arrivalHoldPct: Int?

    var tint: Color { Color(hexString: tintHex) }

    /// Short measured wait for a metric chip ("~52s"), or nil with no measurement.
    /// Never falls back to `etaSeconds` — a comforting invented number at the
    /// moment of spending is exactly the thing we removed.
    var typicalWaitShort: String? {
        arrivalP50Seconds.map { String(localized: "~\($0)s") }
    }

    /// Full sentence for the waiting screen. Phrasing follows `arrivalScope`
    /// so a global band is never presented as this service's own record.
    var typicalWaitSentence: String? {
        guard let p50 = arrivalP50Seconds else { return nil }
        if arrivalScope == "service" {
            return String(localized: "Usually arrives in about \(p50)s.")
        }
        return String(localized: "Codes usually arrive in about \(p50)s.")
    }

    /// How confident we are that this service delivers, from our own orders.
    ///
    /// Deliberately coarse: with ~25 orders/day a precise percentage would be
    /// false precision, and quoting "8%" invites an argument about the exact
    /// number. What a user needs before spending a credit is simply whether
    /// this is a good bet, a coin flip, or a long shot.
    enum DeliveryOdds {
        case good           // >=50% over a usable sample
        case mixed          // 20-49%
        case poor           // <20% — e.g. Meta, which blocks rental numbers
        case unknown        // too little traffic to say anything honest
    }

    /// Minimum conclusive attempts before we make any claim at all.
    private static let minSample = 8

    var deliveryOdds: DeliveryOdds {
        guard let attempts = observedAttempts, let codes = observedCodes,
              attempts >= Self.minSample
        else { return .unknown }
        let pct = Double(codes) / Double(attempts)
        if pct >= 0.50 { return .good }
        if pct >= 0.20 { return .mixed }
        return .poor
    }

    /// Honest one-liner for the checkout screen — states the sample, never a
    /// bare percentage, so the claim is falsifiable and doesn't overstate.
    var deliveryEvidence: String? {
        guard let attempts = observedAttempts, let codes = observedCodes,
              attempts >= Self.minSample
        else { return nil }
        return String(localized: "\(codes) of the last \(attempts) attempts got a code")
    }

    /// Cascading list of logo sources, in priority order.
    /// Source 1 (DuckDuckGo ip3): apple-touch-icon quality, no API key, reliable.
    /// Source 2 (Google FaviconV2): any domain with a favicon, up to 128px.
    /// If both fail, ServiceLogo falls back to an SF Symbol on a tinted square.
    ///
    /// NOTE: Clearbit's free Logo API (logo.clearbit.com) was shut down by HubSpot
    /// on 2025-12-01 — its host no longer resolves, so it was removed. Leaving it
    /// in the cascade made every logo eat a DNS failure (often a long hang) before
    /// falling through, which read as "logos not loading."
    var logoURLs: [URL] {
        guard let domain, !domain.isEmpty else { return [] }
        let escaped = "https%3A%2F%2F\(domain)"
        return [
            URL(string: "https://icons.duckduckgo.com/ip3/\(domain).ico"),
            URL(string: "https://t2.gstatic.com/faviconV2?client=SOCIAL&type=FAVICON&fallback_opts=TYPE,SIZE,URL&url=\(escaped)&size=128"),
        ].compactMap { $0 }
    }
}
