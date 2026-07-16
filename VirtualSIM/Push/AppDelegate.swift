import UIKit

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
        }
    }

    /// APNs can return a token before AuthGate has wired up `push`; hold the most
    /// recent one and flush it as soon as `push` is set.
    private static var pendingTokenData: Data?

    override init() { super.init() }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        true
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
