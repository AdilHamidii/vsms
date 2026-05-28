import UIKit

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor static let shared = AppDelegate()
    var push: PushManager?

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
            self.push?.receivedDeviceToken(deviceToken)
        }
    }

    nonisolated func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Phase F: surface this.
        print("APNs registration failed: \(error.localizedDescription)")
    }
}
