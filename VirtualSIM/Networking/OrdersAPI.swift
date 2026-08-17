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
    let tier: String?        // "standard" | "premium"; nil on pre-tier rows
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

    /// `allowConcurrent` tells the server this is a DELIBERATE second live
    /// number for the same service, not a double-tap — the site rejected the
    /// first one and the 180s hold means it cannot be released yet. It shortens
    /// `begin_order`'s dedupe window from 15s to 3s; without it, walking back
    /// through checkout inside 15s silently hands back the SAME order.
    /// `fromDefault` records that the SERVICE was the app's own pre-selection
    /// rather than something the user picked. It exists so delivery evidence
    /// can exclude those orders: measured 2026-08-07, six such orders from
    /// four brand-new users all got numbers and none got a code, because the
    /// numbers were never entered anywhere — nobody had come for that service.
    /// Scoring them as delivery failures measures our own steering and drags
    /// the `delivery-degraded` watchdog down with it.
    func create(serviceId: String, countryId: String, premium: Bool = false,
                allowConcurrent: Bool = false,
                fromDefault: Bool = false) async throws -> ServerOrder {
        struct Body: Encodable {
            let service_id: String; let country_id: String; let tier: String
            let allow_concurrent: Bool
            let from_default: Bool
        }
        let env: OrderEnvelope = try await client.request(
            .post, path: "functions/v1/create-order",
            body: Body(service_id: serviceId, country_id: countryId,
                       tier: premium ? "premium" : "standard",
                       allow_concurrent: allowConcurrent,
                       from_default: fromDefault)
        )
        return env.order
    }

    /// Authoritative read of one order row straight from PostgREST.
    ///
    /// Deliberately NOT `check-order`: that edge function polls the live SMS
    /// provider and returns HTTP 502 `provider_unreachable` whenever the
    /// provider throws, so it is exactly the wrong thing to ask "did my order
    /// already end?". The cron (`poll-active-orders`, every 60s) has by then
    /// written `expired`/`canceled` and issued the refund; this row read sees
    /// that truth with no provider in the path. RLS scopes it to the caller.
    func fetch(orderId: String) async throws -> ServerOrder {
        let rows: [ServerOrder] = try await client.request(
            .get,
            path: "rest/v1/orders",
            query: [
                URLQueryItem(name: "id",     value: "eq.\(orderId)"),
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "limit",  value: "1"),
            ]
        )
        guard let row = rows.first else {
            throw APIError.http(status: 404, body: "{\"error\":\"order_not_found\"}")
        }
        return row
    }

    func check(orderId: String) async throws -> ServerOrder {
        struct Body: Encodable { let order_id: String }
        let env: OrderEnvelope = try await client.request(
            .post, path: "functions/v1/check-order",
            body: Body(order_id: orderId)
        )
        return env.order
    }

    /// Destroys a paid, in-flight order and refunds it.
    ///
    /// `enforce_min_hold` opts this client in to the server's 180s minimum
    /// hold. It is a flag rather than server-default because shipped 1.4
    /// ignores a failed cancel and creates the replacement order anyway —
    /// enforcing for everyone would double-charge those users. We send it
    /// because `rerollNumber` and `cancelWaiting` both abort on failure.
    func cancel(orderId: String) async throws -> ServerOrder {
        struct Body: Encodable { let order_id: String; let enforce_min_hold: Bool }
        let env: OrderEnvelope = try await client.request(
            .post, path: "functions/v1/cancel-order",
            body: Body(order_id: orderId, enforce_min_hold: true)
        )
        return env.order
    }
}
