import Foundation

struct EsimPlansAPI {
    let client: APIClient

    /// Every column `EsimPlan` decodes, and no others.
    ///
    /// This was `select=*`, which shipped `last_cost_cents` and
    /// `smoothed_cost_cents` — our eSIM wholesale cost book — to anyone holding
    /// the publishable key. Naming the columns is the CLIENT half of the
    /// two-phase fix; the server-side column revoke can only land once a build
    /// carrying this is *adopted*, because Postgres needs SELECT on every column
    /// to answer `select=*` and revoking first would make the catalog fail to
    /// load for the whole install base. Client first, revoke second — the same
    /// ordering the `routes` leak needs.
    private static let columns = [
        "id", "name", "country_code", "region", "data_mb",
        "validity_days", "speed", "extendable", "retail_credits", "status",
    ].joined(separator: ",")

    /// Public catalog (like services/routes) — fetched with the publishable key.
    func fetch() async throws -> [EsimPlan] {
        try await client.request(
            .get, path: "rest/v1/esim_plans",
            query: [
                URLQueryItem(name: "select", value: Self.columns),
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

    /// Every column `ServerEsimOrder` decodes, and no others. `select=*` here
    /// shipped `actual_cost_cents` — the wholesale we paid for that eSIM — to
    /// the buyer, decoded by nothing. Same two-phase rule as `EsimPlansAPI`
    /// above: client names its columns first, server revokes second.
    private static let orderColumns = [
        "id", "plan_id", "smspool_tx", "cost_credits", "status",
        "activation_code", "smdp_address", "matching_id", "apn",
        "sim_pin", "sim_puk", "data_total_mb", "data_used_mb",
        "activated", "activated_at", "expires_at", "created_at",
    ].joined(separator: ",")

    func list() async throws -> [ServerEsimOrder] {
        try await client.request(
            .get, path: "rest/v1/esim_orders",
            query: [
                URLQueryItem(name: "select", value: Self.orderColumns),
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
