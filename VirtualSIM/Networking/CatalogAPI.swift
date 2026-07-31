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

    func fetch() async throws -> Catalog {
        async let svcTask: [Service] = client.request(
            .get, path: "rest/v1/services",
            query: [URLQueryItem(name: "select", value: "*"),
                    // Skip services flagged not-visible server-side (e.g. ones
                    // whose only provider code is an UNMAPPED placeholder — a
                    // guaranteed dead end). Data-driven, no client release needed.
                    URLQueryItem(name: "visible", value: "eq.true"),
                    URLQueryItem(name: "order",  value: "sort_order.asc")],
            authenticated: false
        )
        async let ctyTask: [Country] = client.request(
            .get, path: "rest/v1/countries",
            query: [URLQueryItem(name: "select", value: "*"),
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
                             value: "service_id,country_id,retail_credits,status,success_rate,rate_source,success_sample,success_codes,premium_credits,real_sim_only"),
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
