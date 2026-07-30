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
    /// Decodes NOTHING on purpose.
    ///
    /// This used to decode `{thread_id, relayed}` into a struct declaring
    /// `let thread_id`. `JSONDecoder.relay` sets `.convertFromSnakeCase`, so the
    /// key arrives as `threadId` and the snake_case property never matched —
    /// the decode threw on a request that had already stored the message AND
    /// relayed it to Telegram. The user saw "Couldn't reach the server" while
    /// the owner's phone was buzzing with their message.
    ///
    /// The caller discards the value anyway, so the safest contract is not to
    /// have one: `Empty` short-circuits decoding entirely, and no future change
    /// to this endpoint's response shape can break sending a support message —
    /// which is the one screen a user reaches for when everything else is
    /// already broken.
    func send(_ body: String) async throws {
        struct Body: Encodable { let body: String }
        _ = try await client.request(
            .post, path: "functions/v1/support-send", body: Body(body: body),
            as: APIClient.Empty.self
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
