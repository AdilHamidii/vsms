import Foundation

/// Which APNs environment this build's push tokens actually belong to.
///
/// ── Why this is not `#if DEBUG` ───────────────────────────────────────────
///
/// It was, in three places (`PushManager`, `CallController`,
/// `TelnyxVoiceClient`), and the configuration they assumed is not the one
/// that ships.
///
/// ⚠️ **`VirtualSIM.entitlements` says `aps-environment = production` and that
/// is NOT what a device build is signed with.** Xcode rewrites the key to
/// match the profile it signs with. Verified against a real Debug device
/// build: `codesign -d --entitlements -` reports **`development`**. So the
/// entitlements file is not the authority and neither is the build
/// configuration — **the provisioning profile is**, which is what iOS itself
/// honours when it decides which APNs environment a token belongs to.
///
/// | run | profile Xcode signs with | truth | `#if DEBUG` said |
/// |---|---|---|---|
/// | Debug → device | Development | `sandbox` | sandbox ✓ |
/// | **Release → device from Xcode** | **Development** | **`sandbox`** | **production ✗** |
/// | TestFlight / Ad Hoc | Distribution | `production` | production ✓ |
/// | App Store | Distribution | `production` | production ✓ |
/// | Simulator (no profile) | — | `production` | — |
///
/// **Row two is the live hazard.** Xcode signs *Run* with the Development
/// profile whatever the configuration, so switching the scheme to Release to
/// test performance or StoreKit yields a sandbox token that the old code
/// registered as production. This project does exactly that — the 2026-08-03
/// IAP outage was first misdiagnosed as "local StoreKit signing on a device
/// Release build" — and the failure is the expensive kind: outbound calling
/// works perfectly, inbound never rings, and nothing logs a reason. Same class
/// as the `INFOPLIST_KEY_UIBackgroundModes` trap: a build-time constant
/// asserting something about the shipped configuration that nothing checks.
///
/// The simulator cannot receive remote pushes at all, so its value is
/// irrelevant; it defaults with everything else. Absence of a profile means
/// "not a development build", which is the safe direction.
///
/// Verified against all 10 provisioning profiles on this machine: the slicing
/// below parses every one, and correctly separates the Store profile
/// (`production`) from the Team profile (`development`).
enum APNSEnvironment: String {
    case sandbox
    case production

    /// Resolved once. The profile cannot change while the app is running.
    static let current: APNSEnvironment = resolve()

    private static func resolve() -> APNSEnvironment {
        guard
            let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
            let data = try? Data(contentsOf: url),
            let profile = embeddedPlist(in: data),
            let entitlements = profile["Entitlements"] as? [String: Any],
            let aps = entitlements["aps-environment"] as? String
        else {
            return .production
        }
        // Apple writes exactly "development" or "production" here.
        return aps == "development" ? .sandbox : .production
    }

    /// A `.mobileprovision` is a CMS-signed blob with a plain-text XML plist
    /// in the middle. There is no public API to read it, and parsing the whole
    /// container would mean unwrapping PKCS#7 for one string — so the plist is
    /// sliced out by its delimiters.
    ///
    /// Failing to find it returns nil and the caller falls back to
    /// `.production`, which is the safe direction.
    private static func embeddedPlist(in data: Data) -> [String: Any]? {
        guard
            let start = data.range(of: Data("<?xml".utf8)),
            let end = data.range(of: Data("</plist>".utf8),
                                 in: start.lowerBound..<data.endIndex)
        else { return nil }

        return try? PropertyListSerialization.propertyList(
            from: Data(data[start.lowerBound..<end.upperBound]),
            options: [],
            format: nil
        ) as? [String: Any]
    }
}
