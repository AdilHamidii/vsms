import Foundation

struct Route: Codable, Hashable {
    let serviceId: String
    let countryId: String
    let retailCredits: Int?
    let status: String
    let lastCostCents: Int?
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
                    URLQueryItem(name: "order",  value: "sort_order.asc")],
            authenticated: false
        )
        async let ctyTask: [Country] = client.request(
            .get, path: "rest/v1/countries",
            query: [URLQueryItem(name: "select", value: "*"),
                    URLQueryItem(name: "order",  value: "sort_order.asc")],
            authenticated: false
        )
        async let rtsTask: [Route] = client.request(
            .get, path: "rest/v1/routes",
            query: [URLQueryItem(name: "select", value: "*")],
            authenticated: false
        )
        return Catalog(services: try await svcTask,
                       countries: try await ctyTask,
                       routes:    try await rtsTask)
    }
}
