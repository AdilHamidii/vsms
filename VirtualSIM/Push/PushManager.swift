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
            try await center.requestAuthorization(options: [.alert, .badge, .sound])
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
            #if DEBUG
            let env = "sandbox"
            #else
            let env = "production"
            #endif
            try await PushAPI(client: api).register(
                token: token,
                environment: env,
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
        if let orderId = info["orderId"] as? String {
            await MainActor.run { self.pendingOrderId = orderId }
        }
    }
}
