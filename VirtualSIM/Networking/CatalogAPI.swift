import Foundation

struct Route: Codable, Hashable {
    let serviceId: String
    let countryId: String
    let retailCredits: Int?
    let status: String
    let lastCostCents: Int?
    let successRate: Int?    // 0-100, provider self-reported; nil = no badge
    let premiumCredits: Int? // real-SIM tier price; nil = no premium option
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
        async let rtsTask: [Route] = client.request(
            .get, path: "rest/v1/routes",
            query: [
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "or", value: "(retail_credits.not.is.null,status.neq.active,success_rate.not.is.null)"),
            ],
            authenticated: false
        )
        return Catalog(services: try await svcTask,
                       countries: try await ctyTask,
                       routes:    try await rtsTask)
    }
}
