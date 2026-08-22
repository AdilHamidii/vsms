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

    /// Full sentence for the WAITING screen. Phrasing follows `arrivalScope`
    /// so a global band is never presented as this service's own record.
    ///
    /// Deliberately quotes **p90, not p50** — and that is the whole point of
    /// this property. A median is wrong for half of all codes *by definition*,
    /// so quoting it next to a running clock states a deadline we miss half the
    /// time, at the exact moment the user is deciding whether to hit ✕.
    /// Measured 2026-07-28: the live global band is p50 59s / p90 161s, we were
    /// printing "about 59s", and first-time users cancelled at a median of
    /// **104s** — past our stated number, well short of the real one. **28 of
    /// 37 first orders were cancelled and not one of them ever got a code**,
    /// while first-timers who let the window run delivered 33%.
    ///
    /// This is the same mistake as the seed `etaSeconds` (28s promised against
    /// 53s actual) one layer up: that fix corrected the data source and kept
    /// the framing. Rounding is UP, for the same reason — over-stating the wait
    /// costs nothing, under-stating it destroys a paid order.
    var typicalWaitSentence: String? {
        guard let p90 = arrivalP90Seconds, p90 > 0 else { return nil }
        let mins = max(1, Int(ceil(Double(p90) / 60.0)))
        if arrivalScope == "service" {
            return String(localized: "Most \(name) codes arrive within \(mins) min.")
        }
        return String(localized: "Most codes arrive within \(mins) min.")
    }

    /// Minimum attempts before we state a record at all.
    ///
    /// "1 of the last 7 attempts got a code" is not a claim about a rate — it
    /// IS the sample, and it carries its own uncertainty. Nothing RENDERS a
    /// record any more (owner decision 2026-08-22 — see the header of
    /// `SuccessBadge.swift`); this floor survives because `deliversPoorly`
    /// steers on it.
    ///
    /// The confidence tier (`DeliveryOdds`, floor 8) and the evidence line it
    /// coloured were deleted with the surfaces that showed them.
    private static let minEvidenceSample = 3

    /// True when our OWN orders say this service usually rejects temporary
    /// numbers — the signal used to default checkout to the real-SIM tier.
    ///
    /// Asymmetric on purpose, mirroring the route rule ("demote fast, promote
    /// slow"): a rate needs 3 attempts to look bad, but delivering ZERO needs
    /// only 2. Measured 2026-07-30 this selects instagram (2 of 11), whatsapp
    /// (1 of 7) and discord (0 of 2) — between them 18 first orders and **0**
    /// first-time codes — while leaving facebook (6 of 14) and tiktok (5 of 7)
    /// on standard. Telegram (0 of 0) is correctly excluded: no evidence is not
    /// evidence of failure.
    var deliversPoorly: Bool {
        guard let a = observedAttempts, let c = observedCodes else { return false }
        if c == 0 && a >= 2 { return true }
        return a >= Self.minEvidenceSample && Double(c) / Double(a) < 0.20
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
