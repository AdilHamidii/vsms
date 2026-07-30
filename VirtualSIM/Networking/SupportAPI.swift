import Foundation

/// One message in a support conversation. Mirrors `support_messages`.
struct SupportMessage: Codable, Hashable, Identifiable {
    let id: String
    let threadId: String
    /// "user" or "agent". A String rather than an enum on purpose: this decodes
    /// straight from PostgREST, and `OrderStatus` already proved that a bare
    /// String enum with no unknown case breaks a whole screen the moment the
    /// server learns a new value.
    let sender: String
    let body: String
    let createdAt: String?

    var isAgent: Bool { sender == "agent" }
}

struct SupportAPI {
    let client: APIClient

    /// Send a message. The server creates or reuses the thread — there is at
    /// most one live thread per user, enforced by a partial unique index.
    func send(_ body: String) async throws {
        struct Body: Encodable { let body: String }
        struct Ack: Decodable { let thread_id: String; let relayed: Bool }
        _ = try await client.request(
            .post, path: "functions/v1/support-send", body: Body(body: body), as: Ack.self
        )
    }

    /// The whole conversation, oldest first. RLS scopes it to the caller, so no
    /// thread id is needed — a user only ever has one live thread.
    func messages() async throws -> [SupportMessage] {
        try await client.request(
            .get, path: "rest/v1/support_messages",
            query: [URLQueryItem(name: "select", value: "*"),
                    URLQueryItem(name: "order", value: "created_at.asc")]
        )
    }
}
