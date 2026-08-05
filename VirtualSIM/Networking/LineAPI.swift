import Foundation

/// The rentable second number — the fourth product line.
///
/// Reads go straight to PostgREST with an EXPLICIT `select=` list; anything
/// that spends money or touches Telnyx goes through an edge function. The
/// explicit column lists are deliberate: `EmailAPI.list()` and
/// `OrdersAPI.list()` both send `select=*`, which is how `actual_cost_cents`
/// (our per-order wholesale) ends up on every buyer's phone. Do not copy that
/// here — and note `my_line` is a VIEW precisely so the client cannot reach the
/// Telnyx ids and `monthly_cost_cents` on the base table at all.
struct LineAPI {
    let client: APIClient

    // MARK: - The line itself

    /// Every column of `my_line`, which is already the safe projection. RLS
    /// plus the view's own `where user_id = auth.uid()` scope it to the caller,
    /// so this returns at most one row.
    private static let lineColumns = [
        "id", "e164", "country_code", "number_type", "status",
        "current_period_start", "current_period_end", "grace_until", "hold_until",
        "sms_allowance", "sms_used", "voice_allowance_seconds", "voice_used_seconds",
        "allowance_period_start", "emergency_disabled",
        "created_at", "activated_at", "released_at",
    ].joined(separator: ",")

    /// The caller's line, or nil.
    ///
    /// A user can hold at most one live line — `phone_lines_one_live_per_user`
    /// is a partial unique index, so that is enforced rather than assumed — but
    /// `my_line` also returns RELEASED rows, whose history the app still shows.
    /// Ordering puts the newest first so a resubscribe after a release resolves
    /// to the new line, not the dead one.
    func fetch() async throws -> Line? {
        let rows: [Line] = try await client.request(
            .get, path: "rest/v1/my_line",
            query: [URLQueryItem(name: "select", value: Self.lineColumns),
                    URLQueryItem(name: "order", value: "created_at.desc"),
                    URLQueryItem(name: "limit", value: "1")]
        )
        return rows.first
    }

    // MARK: - Buying one

    /// Live availability for one city. Never cached: stock is per (city, area
    /// code) and genuinely runs dry — Toronto's 416 returns zero while 437 is
    /// full — so a cached "available" is a promise we cannot keep. Same rule
    /// `email-domains` follows for HeroSMS stock.
    ///
    /// Cheap enough to call on every city tap: it buys nothing and charges
    /// nothing.
    func availability(city: String?) async throws -> LineAvailability {
        struct Body: Encodable { let city: String? }
        return try await client.request(
            .post, path: "functions/v1/search-line-numbers", body: Body(city: city)
        )
    }

    // MARK: - Threads and messages
    //
    // Not yet reachable — the inbox ships with the messaging step. Written now
    // so the column lists live next to the model that consumes them.

    private static let threadColumns =
        "id,line_id,peer_e164,last_message_at,last_preview,unread_count,blocked,created_at"

    private static let messageColumns =
        "id,thread_id,line_id,direction,e164_from,e164_to,body,status,segments," +
        "sent_at,received_at,created_at"

    private static let callColumns =
        "id,line_id,direction,peer_e164,status,started_at,answered_at,ended_at," +
        "duration_seconds,billed_seconds,created_at"

    func threads() async throws -> [LineThread] {
        try await client.request(
            .get, path: "rest/v1/line_threads",
            query: [URLQueryItem(name: "select", value: Self.threadColumns),
                    URLQueryItem(name: "order", value: "last_message_at.desc.nullslast")]
        )
    }

    /// Newest-first from the server so the `limit` keeps the RECENT messages;
    /// the thread view reverses for display. Ordering ascending with a limit
    /// would page in the oldest messages and show an empty-looking thread.
    func messages(threadId: String, limit: Int = 200) async throws -> [LineMessage] {
        try await client.request(
            .get, path: "rest/v1/line_messages",
            query: [URLQueryItem(name: "select", value: Self.messageColumns),
                    URLQueryItem(name: "thread_id", value: "eq.\(threadId)"),
                    URLQueryItem(name: "order", value: "created_at.desc"),
                    URLQueryItem(name: "limit", value: String(limit))]
        )
    }

    func calls(limit: Int = 100) async throws -> [LineCall] {
        try await client.request(
            .get, path: "rest/v1/line_calls",
            query: [URLQueryItem(name: "select", value: Self.callColumns),
                    URLQueryItem(name: "order", value: "created_at.desc"),
                    URLQueryItem(name: "limit", value: String(limit))]
        )
    }
}
