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

    /// Hold a specific number, and — the real point — find out BEFORE the
    /// paywall whether we could actually deliver it.
    ///
    /// The server re-quotes the price itself rather than trusting anything sent
    /// from here, and refuses on a Telnyx float shortfall, an existing line, or
    /// a paused product. That refusal has to happen now: once StoreKit takes
    /// the money, the only remedy left is an Apple refund, which is the one
    /// money path this app cannot drive.
    func reserve(city: String, phoneNumber: String) async throws -> LineReservationQuote {
        struct Body: Encodable { let city: String; let phone_number: String }
        return try await client.request(
            .post, path: "functions/v1/reserve-line-number",
            body: Body(city: city, phone_number: phoneNumber)
        )
    }

    /// Hand Apple's signed transaction to the server, which verifies it against
    /// the pinned root, records the cascade-free subscription tombstone, then
    /// buys and configures the number.
    ///
    /// `monthlyCents` comes from the reservation quote and is carried purely so
    /// the server can stamp it onto the line: Telnyx reports the cost nowhere
    /// after purchase — the order response returns `cost_information: null` and
    /// the number resource has no price field at all.
    func verifySubscription(
        signedTransaction: String, phoneNumber: String,
        city: String, monthlyCents: Int?
    ) async throws -> LineProvisionResult {
        struct Body: Encodable {
            let signed_transaction: String
            let phone_number: String
            let city: String
            let monthly_cents: Int?
        }
        return try await client.request(
            .post, path: "functions/v1/verify-line-subscription",
            body: Body(signed_transaction: signedTransaction, phone_number: phoneNumber,
                       city: city, monthly_cents: monthlyCents)
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

    /// Send a text. The allowance is consumed server-side before Telnyx is
    /// called, and handed back if the send fails terminally — this line has no
    /// money to refund, so the allowance is the only thing that can be made
    /// whole.
    func send(to: String, text: String) async throws -> LineSendResult {
        struct Body: Encodable { let to: String; let text: String }
        return try await client.request(
            .post, path: "functions/v1/send-line-message", body: Body(to: to, text: text)
        )
    }

    /// Block / unblock / report / mark-read. Every write to `line_threads` is
    /// revoked from `authenticated` — RLS is row-level and cannot stop a client
    /// setting `blocked` on someone else's row — so all four go through the
    /// service role, and the RPCs verify ownership rather than trusting the id.
    func threadAction(threadId: String, action: String, reason: String? = nil) async throws {
        struct Body: Encodable {
            let thread_id: String; let action: String; let reason: String?
        }
        _ = try await client.request(
            .post, path: "functions/v1/line-thread-action",
            body: Body(thread_id: threadId, action: action, reason: reason),
            as: APIClient.Empty.self
        )
    }

    /// The pre-flight gate for an outbound call: it checks the line's status
    /// and RESERVES voice allowance, then returns.
    ///
    /// It deliberately does not place the call — the client dials over WebRTC
    /// with a credential from `mint-line-token`. Putting a server round trip on
    /// the ring path would add its latency and its failure modes to the one
    /// interaction where a stall is unmistakable.
    func beginCall(to: String) async throws -> LineCallGrant {
        struct Body: Encodable { let to: String }
        return try await client.request(
            .post, path: "functions/v1/begin-line-call", body: Body(to: to)
        )
    }

    /// Hand the provider's session id back to the server.
    ///
    /// 🔴 WITHOUT THIS EVERY CALL COSTS ITS FULL RESERVATION AND NOTHING ELSE
    /// IS ENFORCED. `begin-line-call` reserves a flat 120 seconds and
    /// `sync-telnyx-cdr` settles the difference — but the poller matches only
    /// on `provider_call_session_id`, and the id exists solely on the device,
    /// because the server is deliberately not on the ring path. So a
    /// ten-second call kept the whole two minutes (50 dials a month) and a
    /// forty-minute call also cost two minutes, since the reservation was the
    /// only thing standing between a user and unlimited talk time.
    ///
    /// Everything except the session id is ADVISORY. `duration_seconds` is what
    /// this device claimed; `billed_seconds` from the detail record is the
    /// truth. What the client uniquely knows is a KEY, not a value.
    func reportCall(
        callId: String,
        sessionId: String? = nil,
        status: String? = nil,
        answeredAt: Date? = nil,
        durationSeconds: Int? = nil
    ) async throws {
        struct Body: Encodable {
            let call_id: String
            let session_id: String?
            let status: String?
            let answered_at: String?
            let duration_seconds: Int?
        }
        _ = try await client.request(
            .post, path: "functions/v1/report-line-call",
            body: Body(
                call_id: callId,
                session_id: sessionId,
                status: status,
                answered_at: answeredAt.map { ISO8601DateFormatter().string(from: $0) },
                duration_seconds: durationSeconds
            ),
            as: APIClient.Empty.self
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
