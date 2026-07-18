import Foundation

struct EsimPlansAPI {
    let client: APIClient

    /// Public catalog (like services/routes) — fetched with the publishable key.
    func fetch() async throws -> [EsimPlan] {
        try await client.request(
            .get, path: "rest/v1/esim_plans",
            query: [
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "status", value: "eq.active"),
                URLQueryItem(name: "order", value: "country_code.asc,retail_credits.asc"),
            ],
            authenticated: false
        )
    }
}

struct EsimOrdersAPI {
    let client: APIClient
    private struct Envelope: Codable { let order: ServerEsimOrder }

    func list() async throws -> [ServerEsimOrder] {
        try await client.request(
            .get, path: "rest/v1/esim_orders",
            query: [
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "order", value: "created_at.desc"),
            ]
        )
    }

    func create(planId: String) async throws -> ServerEsimOrder {
        struct Body: Encodable { let plan_id: String }
        let env: Envelope = try await client.request(
            .post, path: "functions/v1/create-esim-order", body: Body(plan_id: planId)
        )
        return env.order
    }

    func checkUsage(orderId: String) async throws -> ServerEsimOrder {
        struct Body: Encodable { let order_id: String }
        let env: Envelope = try await client.request(
            .post, path: "functions/v1/check-esim-usage", body: Body(order_id: orderId)
        )
        return env.order
    }
}
