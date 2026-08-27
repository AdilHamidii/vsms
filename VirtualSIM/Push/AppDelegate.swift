import UIKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// The live PushManager, set by AuthGate once session + API exist.
    ///
    /// Static (not an instance property) on purpose: SwiftUI's
    /// `@UIApplicationDelegateAdaptor(AppDelegate.self)` constructs its OWN
    /// AppDelegate, and *that* instance — not any singleton we make — is the one
    /// UIKit hands the APNs callbacks to. Previously AuthGate set `.push` on a
    /// separate `AppDelegate.shared`, so every device token landed on an
    /// instance whose `push` was nil and was silently dropped (push_devices
    /// stayed empty). Routing through a static removes the instance mismatch.
    static var push: PushManager? {
        didSet {
            if let data = pendingTokenData, let push {
                pendingTokenData = nil
                push.receivedDeviceToken(data)
            }
            if let response = pendingResponse, let push {
                pendingResponse = nil
                push.handle(response: response)
            }
        }
    }

    /// APNs can return a token before AuthGate has wired up `push`; hold the most
    /// recent one and flush it as soon as `push` is set.
    private static var pendingTokenData: Data?

    /// A tapped notification that arrived before `push` existed.
    ///
    /// This is the NORMAL case for a launch-from-push, not an edge case: UIKit
    /// delivers the response within milliseconds of launch, while `push` is set
    /// from `AuthGate`'s task. Same buffer-and-flush shape as the device token,
    /// and for the same reason — dropping it loses the deep link silently.
    private static var pendingResponse: UNNotificationResponse?

    override init() { super.init() }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // 🔴 THE DELEGATE MUST BE SET BEFORE LAUNCH COMPLETES. Apple only
        // delivers a tapped-notification response to a delegate that was
        // already assigned when the app finished launching. It used to be
        // assigned by `PushManager` from `AuthGate`'s `.task`, i.e. after
        // launch — so terminated app → "Your code arrived" push → tap opened
        // on Home with `pendingOrderId` never set, on the app's
        // highest-volume re-entry path. Nothing logged; it just looked like
        // the push did not deep-link.
        UNUserNotificationCenter.current().delegate = self

        // 🔴 THE VoIP REGISTRY MUST EXIST FROM PROCESS START. A `.voIP` push
        // can wake a TERMINATED app, and it used to be created in
        // `LineScreen.task` — so a push arriving before the user had ever
        // opened the Number tab found no registry, produced no incoming-call
        // report, and iOS permanently stops delivering VoIP pushes to a bundle
        // that does that repeatedly. Registering here also means the token
        // exists long before anyone dials.
        CallController.shared.registerForVoIPPushes()
        return true
    }

    nonisolated func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            if let push = AppDelegate.push {
                push.receivedDeviceToken(deviceToken)
            } else {
                AppDelegate.pendingTokenData = deviceToken
            }
        }
    }

    nonisolated func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("APNs registration failed: \(error.localizedDescription)")
    }
}

/// The single `UNUserNotificationCenterDelegate` for the whole app.
///
/// It lives on the AppDelegate rather than on `PushManager` because only the
/// AppDelegate exists early enough — see `didFinishLaunchingWithOptions`. It
/// owns no routing: every tap is forwarded to `PushManager.handle(response:)`,
/// or buffered until that object exists.
extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Show banner+sound even when the app is in foreground.
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            if let push = AppDelegate.push {
                push.handle(response: response)
            } else {
                AppDelegate.pendingResponse = response
            }
        }
    }
}
