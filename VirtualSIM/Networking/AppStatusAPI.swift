import Foundation

/// Owner-written banner, set from Telegram with `/announce`.
///
/// The text is written by a human and shown verbatim, so it is deliberately NOT
/// localized — translating it is impossible and machine-translating it would put
/// words in the owner's mouth. Everything around it (the dismiss control, the
/// accessibility label) is localized.
struct Announcement: Codable, Hashable {
    let active: Bool
    let text: String
    let kind: String
    /// Changes on every post. This is what makes a dismissal stick to ONE
    /// announcement instead of silencing the channel forever — see
    /// `AppState.dismissedAnnouncementId`.
    let id: String

    /// `active` alone is not enough: a cleared announcement is stored as
    /// `active:false` with empty text, but a mis-set one could be active with
    /// blank text, and an empty banner is worse than no banner.
    var isLive: Bool {
        active && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isWarning: Bool { kind == "warn" }
}

/// Public, deliberately-published slice of `app_config`.
///
/// The table also holds provider balances and the watchdog verdict, so it is
/// RLS-restricted to an explicit key whitelist (`maintenance`, `announcement`,
/// `esim_paused`, `lines_paused`, `line_swap_credits`,
/// `delivery_metrics_hidden`). Never widen that policy
/// to `using (true)` — the same table holds provider balances, the watchdog
/// verdict and every sync cursor.
struct AppStatus: Equatable {
    var announcement: Announcement?
    var esimPaused: Bool
    /// What it costs to replace a rented line's number.
    ///
    /// NIL until the server says otherwise, and that is load-bearing: this is
    /// a price the owner changes without a release, so the client must never
    /// carry a default. Callers hide the swap affordance entirely rather than
    /// quoting a figure the server has not confirmed — the rule that the
    /// "+3 credits" onboarding card and `inviteJoinerCredits` both broke.
    var lineSwapCredits: Int?
    /// Owner kill switch (`/metrics off` in the ops bot) for the ONLY delivery
    /// figure a user sees — the vendor's network rate. Display-only: steering
    /// and sorting keep reading the rate. Absent key = shown.
    var deliveryMetricsHidden: Bool = false

    static let unknown = AppStatus(announcement: nil, esimPaused: false,
                                   lineSwapCredits: nil)
}

struct AppStatusAPI {
    let client: APIClient

    /// One request for both keys. Their `value` shapes differ — an object for
    /// the announcement, a bare boolean for the pause flag — so each is decoded
    /// leniently and a shape we do not recognise is simply skipped rather than
    /// failing the whole fetch and blanking a live announcement.
    private struct Row: Decodable {
        let key: String
        let announcement: Announcement?
        let flag: Bool?
        let number: Int?

        enum CodingKeys: String, CodingKey { case key, value }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            announcement = try? c.decode(Announcement.self, forKey: .value)
            flag = try? c.decode(Bool.self, forKey: .value)
            number = try? c.decode(Int.self, forKey: .value)
        }
    }

    func fetch() async throws -> AppStatus {
        let rows: [Row] = try await client.request(
            .get, path: "rest/v1/app_config",
            query: [
                URLQueryItem(name: "key",
                             value: "in.(announcement,esim_paused,line_swap_credits,delivery_metrics_hidden)"),
                URLQueryItem(name: "select", value: "key,value"),
            ]
        )
        return AppStatus(
            announcement: rows.first(where: { $0.key == "announcement" })?.announcement,
            esimPaused: rows.first(where: { $0.key == "esim_paused" })?.flag ?? false,
            // No `?? 5`. An absent or unreadable price hides the feature; it
            // must never fall back to a number this build happens to remember.
            lineSwapCredits: rows.first(where: { $0.key == "line_swap_credits" })?.number,
            deliveryMetricsHidden: rows.first(where: { $0.key == "delivery_metrics_hidden" })?.flag ?? false
        )
    }
}
