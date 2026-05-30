import SwiftUI

@main
struct VirtualSIMApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Bump the shared URLCache so brand logos + country flags persist
        // across cold launches. Each PNG is ~3-15KB, so 64MB on disk holds
        // tens of thousands of images comfortably.
        URLCache.shared = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity:   64 * 1024 * 1024
        )
    }

    var body: some Scene {
        WindowGroup {
            AuthGate()
        }
    }
}
