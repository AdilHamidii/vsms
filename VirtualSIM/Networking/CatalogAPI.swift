import Foundation

struct Route: Codable, Hashable {
    let serviceId: String
    let countryId: String
    let retailCredits: Int?
    let status: String
    let successRate: Int?    // 0-100; nil = no badge
    let rateSource: String?  // "measured" | "seeded"; only measured may be stated as fact
    let successSample: Int?  // conclusive orders behind successRate; nil = seeded
    let successCodes: Int?   // codes delivered — the numerator of "worked X of Y"
    let premiumCredits: Int? // real-SIM tier price; nil = no premium option
    /// Service refuses VoIP numbers here, so ONLY the Real SIM tier is sold.
    /// Optional because clients predating the column decode a missing key as
    /// nil — `Codable` drops unknown keys, but a non-optional Bool would throw.
    let realSimOnly: Bool?
    /// The delivery rate the PROVIDER publishes for the exact pool of numbers
    /// this route buys from, over the last 30 days. 0-100.
    ///
    /// nil means the provider publishes no rate for that pool — which means
    /// "too few orders", NEVER "bad". It must render as absent and must never
    /// be coerced to 0. Those routes are still sold; they simply rank last.
    ///
    /// This is NOT our own measurement and must never reach `SuccessBadge`,
    /// which states what happened to orders WE placed ("Worked 3 of 7 times").
    let poolRatePct: Int?

    // `lastCostCents` was decoded here and never read by a single call site —
    // it only ever served to publish our wholesale cost. See the explicit
    // column list in fetch(): the catalog is fetched UNAUTHENTICATED, so every
    // column named there is world-readable to anyone with the publishable key.
    // Never add a cost/margin column to this struct or that query.
}

struct Catalog: Codable {
    let services: [Service]
    let countries: [Country]
    let routes: [Route]
}

struct CatalogAPI {
    let client: APIClient

    /// Every column `Service` decodes, and no others. Same rule as `routes`
    /// below: this request is UNAUTHENTICATED, so `select=*` hands every
    /// present-and-future column on the table to anyone holding the
    /// publishable key. Add a column here only when the model decodes it.
    private static let serviceColumns = [
        "id", "name", "category", "glyph", "icon", "domain", "tint_hex",
        "smspva_code", "cost", "success_rate", "eta_seconds", "sort_order",
        "observed_codes", "observed_attempts",
        "arrival_p50_seconds", "arrival_p90_seconds", "arrival_sample",
        "arrival_scope", "arrival_hold_pct",
    ].joined(separator: ",")

    /// Every column `Country` decodes, and no others.
    private static let countryColumns = [
        "id", "name", "flag", "dial_code", "smspva_code", "stock",
        "avg_seconds", "sort_order", "observed_attempts", "observed_codes",
    ].joined(separator: ",")

    func fetch() async throws -> Catalog {
        async let svcTask: [Service] = client.request(
            .get, path: "rest/v1/services",
            query: [URLQueryItem(name: "select", value: Self.serviceColumns),
                    // Skip services flagged not-visible server-side (e.g. ones
                    // whose only provider code is an UNMAPPED placeholder — a
                    // guaranteed dead end). Data-driven, no client release needed.
                    URLQueryItem(name: "visible", value: "eq.true"),
                    URLQueryItem(name: "order",  value: "sort_order.asc")],
            authenticated: false
        )
        async let ctyTask: [Country] = client.request(
            .get, path: "rest/v1/countries",
            query: [URLQueryItem(name: "select", value: Self.countryColumns),
                    URLQueryItem(name: "order",  value: "sort_order.asc")],
            authenticated: false
        )
        // We only fetch routes with a non-null retail_credits override or a
        // non-active status. Every other (service, country) pair just uses
        // service.cost and is considered active — no need to ship 13,000+
        // rows that all say the same thing as the service.
        // EXPLICIT column list, never `*`. This request is unauthenticated, so
        // `select=*` published the whole margin book — last_cost_cents,
        // smoothed_cost_cents, smspva_operator_cents — to anyone holding the
        // publishable key (which ships in the app). The server also revokes
        // column privileges on those (migration 20260725130000); this list is
        // the half that stops us asking for them in the first place.
        async let rtsTask: [Route] = client.request(
            .get, path: "rest/v1/routes",
            query: [
                URLQueryItem(name: "select",
                             value: "service_id,country_id,retail_credits,status,success_rate,rate_source,success_sample,success_codes,premium_credits,real_sim_only,pool_rate_pct"),
                URLQueryItem(name: "or", value: "(retail_credits.not.is.null,status.neq.active,success_rate.not.is.null)"),
            ],
            authenticated: false
        )
        return Catalog(services: try await svcTask,
                       countries: try await ctyTask,
                       routes:    try await rtsTask)
    }

    /// The provider's own top-10 success rates per service (~390 rows).
    ///
    /// AUTHENTICATED, unlike everything above. `service_country_ranks` grants
    /// SELECT to `authenticated` only and has no anon policy — this is a
    /// provider's quality book, and there is no reason to serve it to a caller
    /// who has not signed in. (Contrast `routes`, which carries a `public read`
    /// policy and is readable with no account at all.)
    ///
    /// Deliberately a SEPARATE call rather than a fourth leg of `fetch()`: it
    /// is an enhancement, not a prerequisite. Home renders correctly without
    /// it, so a failure here must not be able to fail the catalog — see
    /// `AppState.loadCountryRanks`, which swallows.
    func fetchCountryRanks() async throws -> [CountryRank] {
        try await client.request(
            .get, path: "rest/v1/service_country_ranks",
            query: [URLQueryItem(name: "select",
                                 value: "service_id,country_id,vendor_percent,vendor_rank"),
                    URLQueryItem(name: "order", value: "service_id.asc,vendor_rank.asc")],
            authenticated: true
        )
    }
}
