import Foundation

/// UI-facing order. Wraps the server row and the resolved Service/Country
/// from the catalog so existing screens (which read order.service.name etc.)
/// keep working with no API surface changes.
struct Order: Identifiable, Hashable {
    let server: ServerOrder
    let service: Service
    let country: Country

    var id: String { server.id }
    var number: String { server.smspvaNumber ?? "Pending…" }
    var otp: String? { server.otp }
    var status: OrderStatus { server.status }
    var createdAt: Date { server.createdAt }
    var expiresAt: Date { server.expiresAt }
    /// When the code actually landed, server-stamped. Already selected by
    /// `OrdersAPI.columns` and populated on every delivered order measured
    /// (88 of 88 in the 30 days to 2026-09-11) — it is what
    /// `AppState.lastCodeArrival` reads, so the review prompt needs no
    /// client-side delivery bookkeeping of its own.
    /// ⚠️ Non-nil only where a code arrived; read it with `otp != nil`, never
    /// with `status == .received` (a rescued code lives on a canceled row).
    var arrivedAt: Date? { server.arrivedAt }
    var costCredits: Int { server.costCredits }
    /// Which provider filled this order. nil = not recorded, which is NOT the
    /// same as "no provider" — see `AppState.minHoldSeconds(forProvider:)`.
    var providerId: String? { server.provider }

    /// Non-nil and in the future ⇒ another code can still arrive on this same
    /// number, and the UI may say so. Nil means the pool cannot take a second
    /// SMS — never advertise one in that case.
    var resendWatchUntil: Date? { server.resendWatchUntil }

    /// Newest first, for display. `otp` is the newest and is element 0.
    var codeHistory: [OrderCode] { (server.otpHistory ?? []).reversed() }

    /// True when this order ended without a code and the credits went back.
    ///
    /// Both terminal-failure paths refund unconditionally before writing the
    /// status — `poll-active-orders` on expiry and `cancel-order` on cancel —
    /// so the status alone is a sound signal. (`cancel-order` returns
    /// `.received` instead when its last-chance poll finds a code, so a
    /// canceled row here really did refund.) `.refunded` is never written by
    /// the backend today; included so it can't silently read as "not refunded"
    /// if that ever changes.
    var isRefunded: Bool {
        switch server.status {
        case .expired, .canceled, .refunded: true
        case .waiting, .received:            false
        }
    }

    var ago: String {
        Self.relative.localizedString(for: server.createdAt, relativeTo: Date())
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
