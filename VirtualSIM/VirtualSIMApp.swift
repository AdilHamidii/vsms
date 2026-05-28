import SwiftUI

@main
struct VirtualSIMApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            AuthGate()
        }
    }
}
