import Foundation

/// Temporary email addresses — the third product line.
///
/// Everything except the history list goes through edge functions, because the
/// provider call and the credit charge have to happen together server-side.
struct EmailAPI {
    let client: APIClient

    private struct OrderEnvelope: Codable { let order: ServerEmailOrder }

    /// The four sellable domains for one service, with LIVE stock.
    ///
    /// Deliberately not cached: stock is per (service, domain) and moves —
    /// hotmail.com measured 1,028 available for google.com and 2 for
    /// discord.com in the same sweep. A cached "available" is a promise we
    /// cannot keep.
    func domains(serviceId: String) async throws -> EmailDomainsResponse {
        struct Body: Encodable { let service_id: String }
        return try await client.request(
            .post, path: "functions/v1/email-domains", body: Body(service_id: serviceId)
        )
    }

    /// Buy one address. Charges 1 credit for gmail, nothing for
    /// outlook/hotmail (icloud was removed 2026-07-31) — the server is the
    /// authority on both the price and the free-tier daily cap.
    func create(serviceId: String, domain: String) async throws -> ServerEmailOrder {
        struct Body: Encodable { let service_id: String; let domain: String }
        let env: OrderEnvelope = try await client.request(
            .post, path: "functions/v1/create-email-order",
            body: Body(service_id: serviceId, domain: domain)
        )
        return env.order
    }

    /// Refresh one activation. Server-side this reconciles against the provider
    /// and refunds a paid order that ended without a code.
    func check(orderId: String) async throws -> ServerEmailOrder {
        struct Body: Encodable { let order_id: String }
        let env: OrderEnvelope = try await client.request(
            .post, path: "functions/v1/check-email-order", body: Body(order_id: orderId)
        )
        return env.order
    }

    /// History, straight from PostgREST. RLS scopes it to the caller.
    func list() async throws -> [ServerEmailOrder] {
        try await client.request(
            .get, path: "rest/v1/email_orders",
            query: [URLQueryItem(name: "select", value: "*"),
                    URLQueryItem(name: "order", value: "created_at.desc")]
        )
    }
}
