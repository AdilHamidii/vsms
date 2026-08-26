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

    // MARK: - International rate card

    /// What each destination costs, in credits per minute.
    ///
    /// Reads the `voice_rate_card` VIEW, never the `voice_rates` table — the
    /// table is the wholesale cost book and has SELECT revoked from clients.
    /// Columns are named explicitly rather than `select=*` so the view can gain
    /// an internal column later without it reaching a device, which is the
    /// mistake `routes` and `esim_plans` are still paying for.
    ///
    /// Only `enabled` destinations are in the view, so an empty result means
    /// "international is not open yet", not "the fetch failed". The caller must
    /// keep treating an unmatched number as uncallable either way.
    func voiceRates() async throws -> [VoiceRate] {
        try await client.request(
            .get, path: "rest/v1/voice_rate_card",
            query: [URLQueryItem(name: "select",
                                 value: "prefix,iso2,label,credits_per_min,covered_by_allowance")],
            authenticated: false
        )
    }

    // MARK: - Where we can sell

    /// Every country in the catalogue, sellable or not.
    ///
    /// Reads the `line_country_menu` VIEW, never `line_country_catalog` — the
    /// table carries wholesale samples and the regulatory requirement summary,
    /// which is a compliance record and must never reach a device. Columns are
    /// named explicitly for the same reason `voiceRates()` names its own: a
    /// column added to the view later cannot leak by accident.
    ///
    /// Unsellable countries are returned deliberately. The picker shows them
    /// grayed rather than hiding them, so "not yet" is visible instead of
    /// looking like a country we have never heard of.
    ///
    /// `number_type=eq.local` because that is the only type the store sells;
    /// a country's toll-free row has different capabilities and would render
    /// as a duplicate.
    func countries() async throws -> [LineCountry] {
        try await client.request(
            .get, path: "rest/v1/line_country_menu",
            query: [URLQueryItem(name: "select",
                                 value: "country_code,country_name,number_type,supports_voice," +
                                        "supports_sms,supports_mms,supports_emergency," +
                                        "available,sell_reason,has_localities"),
                    URLQueryItem(name: "number_type", value: "eq.local"),
                    URLQueryItem(name: "order", value: "country_name.asc")]
        )
    }

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

    /// EVERY line the caller holds, newest first.
    ///
    /// ⚠️ This used to fetch `limit=1`, on the stated grounds that
    /// `phone_lines_one_live_per_user` made more than one impossible. That
    /// index was DROPPED so credits can rent several numbers, so the limit
    /// stopped being a description of reality and became a filter: a user with
    /// three numbers saw one, and the other two — with their conversations and
    /// call history — were simply invisible, with nothing on screen saying so.
    ///
    /// `my_line` also returns RELEASED rows, whose history the app still shows;
    /// callers decide what counts as live.
    func fetchAll() async throws -> [Line] {
        try await client.request(
            .get, path: "rest/v1/my_line",
            query: [URLQueryItem(name: "select", value: Self.lineColumns),
                    URLQueryItem(name: "order", value: "created_at.desc")]
        )
    }

    // MARK: - Buying one

    /// Live availability for one city. Never cached: stock is per (city, area
    /// code) and genuinely runs dry — Toronto's 416 returns zero while 437 is
    /// full — so a cached "available" is a promise we cannot keep. Same rule
    /// `email-domains` follows for HeroSMS stock.
    ///
    /// Cheap enough to call on every city tap: it buys nothing and charges
    /// nothing.
    ///
    /// `country` is OPTIONAL and omitted by default: the server defaults it to
    /// the launch market, so an old client and a new one ask the same question.
    /// Sending it is what makes the country picker mean anything.
    func availability(city: String?, country: String? = nil) async throws -> LineAvailability {
        struct Body: Encodable { let city: String?; let country: String? }
        return try await client.request(
            .post, path: "functions/v1/search-line-numbers",
            body: Body(city: city, country: country)
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
    func reserve(city: String, phoneNumber: String,
                 country: String? = nil) async throws -> LineReservationQuote {
        struct Body: Encodable {
            let city: String; let phone_number: String; let country: String?
        }
        return try await client.request(
            .post, path: "functions/v1/reserve-line-number",
            body: Body(city: city, phone_number: phoneNumber, country: country)
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
        city: String, monthlyCents: Int?, country: String? = nil
    ) async throws -> LineProvisionResult {
        struct Body: Encodable {
            let signed_transaction: String
            let phone_number: String
            let city: String
            let monthly_cents: Int?
            let country: String?
        }
        return try await client.request(
            .post, path: "functions/v1/verify-line-subscription",
            body: Body(signed_transaction: signedTransaction, phone_number: phoneNumber,
                       city: city, monthly_cents: monthlyCents, country: country)
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
    /// Rent a number with CREDITS. Charges, buys and provisions in one call,
    /// and refunds itself on every failure after the charge.
    ///
    /// This is the ONLY route to a second number: Apple permits one active
    /// subscription per group, so the subscription path is capped at one line
    /// per user by construction.
    func rentWithCredits(phoneNumber: String, city: String,
                         country: String? = nil) async throws -> LineProvisionResult {
        struct Body: Encodable {
            let phone_number: String; let city: String; let country: String?
        }
        return try await client.request(
            .post, path: "functions/v1/rent-line-credits",
            body: Body(phone_number: phoneNumber, city: city, country: country)
        )
    }

    /// Replace this line's phone number with a fresh one in the same area
    /// code, paid in credits.
    ///
    /// ⚠️ The old number is released to the carrier and CANNOT be recovered —
    /// not by us and not by paying again. Every caller must confirm before
    /// invoking this, and the confirmation has to say so plainly.
    ///
    /// The line id is required rather than optional. `send` documents why the
    /// nil-means-oldest fallback is worse than a failure, and it is worse
    /// again here: guessing wrong would give away a number the user is still
    /// using.
    func swapNumber(lineId: String) async throws -> LineSwapResult {
        struct Body: Encodable { let line_id: String }
        return try await client.request(
            .post, path: "functions/v1/swap-line-number",
            body: Body(line_id: lineId)
        )
    }

    /// `lineId` names WHICH number to send from. A user may hold several, and
    /// the server falls back to a deterministic oldest-first pick when it is
    /// omitted — so leaving it nil does not fail, it sends from the wrong
    /// number, which is worse. The id is re-scoped to the caller server-side,
    /// so it cannot be used to send from someone else's line.
    func send(to: String, text: String, lineId: String?) async throws -> LineSendResult {
        struct Body: Encodable { let to: String; let text: String; let line_id: String? }
        return try await client.request(
            .post, path: "functions/v1/send-line-message",
            body: Body(to: to, text: text, line_id: lineId)
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

    /// Mint a short-lived WebRTC credential for this user's line.
    ///
    /// ⚠️ **`mint-line-token` had NO caller anywhere in the app until calling
    /// was wired up** — the endpoint was deployed, the adapters written, and
    /// nothing could ever obtain a token, so `VoiceClient.connect` was
    /// unreachable by construction. Same shape as the six `line_subscriptions`
    /// updaters that shipped with no INSERT: a deployed endpoint is not a
    /// reached endpoint.
    ///
    /// The token is deliberately not cached across launches. It expires on its
    /// own and the failure mode of a stale one is a call that cannot connect,
    /// which is worse than one extra round trip before dialing.
    /// `lineId` names which number the credential is FOR — a voice token is
    /// scoped to one line's connection, so the wrong one rings the wrong number.
    func mintVoiceToken(lineId: String?) async throws -> LineVoiceToken {
        struct Body: Encodable { let line_id: String? }
        return try await client.request(
            .post, path: "functions/v1/mint-line-token", body: Body(line_id: lineId)
        )
    }

    /// The pre-flight gate for an outbound call: it checks the line's status
    /// and RESERVES voice allowance, then returns.
    ///
    /// It deliberately does not place the call — the client dials over WebRTC
    /// with a credential from `mint-line-token`. Putting a server round trip on
    /// the ring path would add its latency and its failure modes to the one
    /// interaction where a stall is unmistakable.
    /// `direction` defaults to outbound. An INBOUND call must be registered too:
    /// `record_line_call` is what creates the `line_calls` row, and without one
    /// an inbound call leaves no history, no allowance accounting and — worse —
    /// nothing for `sync-telnyx-cdr` to match its detail record against, so the
    /// real per-minute cost is never attributed to anyone. Inbound reserves
    /// nothing server-side, so registering it never bills the user.
    /// For inbound, `to` is the PEER that rang us.
    func beginCall(to: String, direction: String = "outbound",
                   lineId: String?) async throws -> LineCallGrant {
        struct Body: Encodable {
            let to: String; let direction: String; let line_id: String?
        }
        return try await client.request(
            .post, path: "functions/v1/begin-line-call",
            body: Body(to: to, direction: direction, line_id: lineId)
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
        legId: String? = nil,
        status: String? = nil,
        answeredAt: Date? = nil,
        durationSeconds: Int? = nil
    ) async throws {
        struct Body: Encodable {
            let call_id: String
            let session_id: String?
            let leg_id: String?
            let status: String?
            let answered_at: String?
            let duration_seconds: Int?
        }
        _ = try await client.request(
            .post, path: "functions/v1/report-line-call",
            body: Body(
                call_id: callId,
                session_id: sessionId,
                leg_id: legId,
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
