import Foundation

struct ServerOrder: Codable, Hashable {
    let id: String
    let userId: String
    let serviceId: String
    let countryId: String
    let smspvaId: String?
    let smspvaNumber: String?
    let costCredits: Int
    let status: OrderStatus
    let otp: String?
    let rawMessage: String?
    let createdAt: Date
    let expiresAt: Date
    let arrivedAt: Date?
    let closedAt: Date?
}

private struct OrderEnvelope: Codable { let order: ServerOrder }

struct OrdersAPI {
    let client: APIClient

    func list() async throws -> [ServerOrder] {
        try await client.request(
            .get,
            path: "rest/v1/orders",
            query: [
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "order",  value: "created_at.desc"),
            ]
        )
    }

    func create(serviceId: String, countryId: String) async throws -> ServerOrder {
        struct Body: Encodable { let service_id: String; let country_id: String }
        let env: OrderEnvelope = try await client.request(
            .post, path: "functions/v1/create-order",
            body: Body(service_id: serviceId, country_id: countryId)
        )
        return env.order
    }

    func check(orderId: String) async throws -> ServerOrder {
        struct Body: Encodable { let order_id: String }
        let env: OrderEnvelope = try await client.request(
            .post, path: "functions/v1/check-order",
            body: Body(order_id: orderId)
        )
        return env.order
    }

    func cancel(orderId: String) async throws -> ServerOrder {
        struct Body: Encodable { let order_id: String }
        let env: OrderEnvelope = try await client.request(
            .post, path: "functions/v1/cancel-order",
            body: Body(order_id: orderId)
        )
        return env.order
    }
}
