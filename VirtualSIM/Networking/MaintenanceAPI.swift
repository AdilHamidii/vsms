import Foundation

/// Server-driven maintenance banner. Set by the weekly virtualsms price sync
/// (app_config key='maintenance') so the app can pause ordering while prices
/// refresh, with a countdown to the estimated finish.
struct MaintenanceStatus: Codable, Hashable {
    let active: Bool
    let until: Date?
    let message: String?

    static let off = MaintenanceStatus(active: false, until: nil, message: nil)

    /// True only while genuinely in maintenance — a stale `active:true` whose
    /// `until` has passed no longer blocks the app.
    var isActiveNow: Bool {
        guard active else { return false }
        if let until { return until > Date() }
        return true
    }
}

struct MaintenanceAPI {
    let client: APIClient

    private struct Row: Codable { let value: MaintenanceStatus }

    func current() async throws -> MaintenanceStatus {
        let rows: [Row] = try await client.request(
            .get,
            path: "rest/v1/app_config",
            query: [
                URLQueryItem(name: "key", value: "eq.maintenance"),
                URLQueryItem(name: "select", value: "value"),
            ]
        )
        return rows.first?.value ?? .off
    }
}
