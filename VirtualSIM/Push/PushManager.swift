import Foundation
import UIKit
import UserNotifications

@Observable
@MainActor
final class PushManager: NSObject {
    /// Hex-encoded APNs device token, or nil if not yet registered.
    var deviceToken: String?
    /// When a push arrives carrying an order_id, we stash it so the app can
    /// route to the OTP screen once the catalog/orders have loaded.
    var pendingOrderId: String?
    /// A tapped inbound-text push. Routed on `kind`, never on `orderId` — see
    /// the note in `userNotificationCenter(_:didReceive:)`.
    var pendingLineThreadId: String?

    private var apiClient: APIClient?
    private var session: Session?

    func attach(api: APIClient, session: Session) {
        self.apiClient = api
        self.session = session
    }

    /// Prompts for permission (idempotent) and registers with APNs.
    ///
    /// Call this at a moment the user WANTS to be notified — the Waiting
    /// screen, right after they've paid for a number. Prompting cold at
    /// sign-in measured 41% opt-in: the user had no idea yet why we'd ping
    /// them. iOS shows the dialog only while status is notDetermined, so
    /// repeat calls are free.
    func requestAuthorizationAndRegister() async {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        do {
            // HONOUR the result. iOS hands out a device token even when alert
            // authorization was DENIED, and APNs then returns 200 for a push
            // nobody can see — so a denied device used to register, look
            // healthy, and silently burn the once-per-user winback nudge.
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            guard granted else { return }
        } catch {
            return
        }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Provisional authorization: delivers quietly to Notification Center with
    /// NO dialog and no opt-in cost, and can be upgraded later.
    ///
    /// Needed because the full prompt now lives only on the Waiting screen —
    /// a screen 114 of 146 users have never reached. Without this, a signup
    /// that never orders can never acquire a token, and `winback_candidates`
    /// requires one, so the cohort the winback exists for became permanently
    /// unreachable. Provisional keeps the contextual prompt intact while making
    /// every signup addressable.
    func registerProvisionalIfUndetermined() async {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        do {
            let granted = try await center.requestAuthorization(
                options: [.alert, .badge, .sound, .provisional])
            guard granted else { return }
        } catch {
            return
        }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Silently refreshes the APNs registration for users who already granted
    /// permission — no dialog, ever. Runs at every sign-in so tokens stay
    /// current without burning the one-shot permission prompt on a cold
    /// moment; users still notDetermined keep that state until the Waiting
    /// screen asks with context.
    func registerIfAuthorized() async {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Called from the AppDelegate when APNs returns the token.
    func receivedDeviceToken(_ data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        deviceToken = hex
        Task { await uploadToken(hex) }
    }

    private func uploadToken(_ token: String) async {
        guard let api = apiClient,
              case .signedIn = session?.status else { return }
        do {
            // Read from the provisioning profile, NOT `#if DEBUG`. Xcode signs
            // *Run* with the Development profile whatever the configuration,
            // so a Release build on a device holds a SANDBOX token while
            // `#if DEBUG` reported production — and a token registered against
            // the wrong gateway is silently dropped. See `APNSEnvironment`.
            try await PushAPI(client: api).register(
                token: token,
                environment: APNSEnvironment.current.rawValue,
                bundleId: Bundle.main.bundleIdentifier ?? "com.anthersystems.VirtualSIM"
            )
        } catch {
            // Phase F: surface error.
        }
    }
}

extension PushManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Show banner+sound even when the app is in foreground.
        return [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo

        // ⚠️ `kind` is checked FIRST. Routing used to be `orderId`-only, so an
        // inbound text carrying an orderId-shaped key would deep-link into the
        // SMS refund screen — the same trap the late-code rescue push had to
        // avoid by carrying no orderId at all. A push with a `kind` we do not
        // recognise falls through to nothing rather than guessing a screen.
        if let kind = info["kind"] as? String {
            switch kind {
            case "line_message":
                if let threadId = info["threadId"] as? String {
                    await MainActor.run { self.pendingLineThreadId = threadId }
                }
                return
            default:
                break
            }
        }

        if let orderId = info["orderId"] as? String {
            await MainActor.run { self.pendingOrderId = orderId }
        }
    }
}
