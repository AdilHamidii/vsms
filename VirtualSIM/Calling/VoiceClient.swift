import Foundation

/// The seam between our call logic and the WebRTC SDK.
///
/// ── Why this protocol exists ──────────────────────────────────────────────
///
/// `TelnyxRTC` is a SwiftPM dependency, and this project currently has **zero**
/// of them — which is why `swiftc -typecheck` can verify the whole app in
/// seconds without resolving a package graph. Adding the SDK permanently
/// retires that, so the dependency is added LAST and everything that does not
/// need it is written against this protocol first.
///
/// It buys three things beyond sequencing:
///  - the dialer, the in-call UI, CallKit and the allowance gate can all be
///    exercised on a simulator with `NullVoiceClient`, and calling is otherwise
///    a device-only feature (the simulator cannot receive a PushKit push),
///  - the CallKit lifecycle is testable without a live media session, which
///    matters because the one rule you cannot get wrong there — reporting an
///    incoming call synchronously — is invisible until iOS kills the app,
///  - if Telnyx is ever replaced, the swap is one type.
///
/// ⚠️ The Telnyx voice adapters this pairs with (`_shared/telnyx.ts`) are
/// written from documentation and have never been exercised: no call has been
/// placed on the account. Treat the first real call as the probe.
protocol VoiceClient: AnyObject, Sendable {
    /// Connect using a short-lived credential from `mint-line-token`. The API
    /// key never reaches the device.
    func connect(token: String) async throws

    func disconnect() async

    /// Place a call. Returns the provider's session id once the SDK has one,
    /// which is what `sync-telnyx-cdr` matches a detail record against.
    func dial(to: String, from: String) async throws -> String?

    /// Answer the call currently ringing.
    func answer() async throws

    /// End whatever call is live. Must be safe to call when there is none —
    /// CallKit can deliver an end action for a call the SDK already dropped.
    func hangup() async

    func setMuted(_ muted: Bool) async
    func setSpeaker(_ on: Bool) async

    /// DTMF for phone menus. A verification call that reads a code aloud
    /// usually needs a key pressed first.
    func sendDTMF(_ digit: String) async
}

/// The stand-in used until `TelnyxRTC` is wired in, and permanently on the
/// simulator.
///
/// It is deliberately NOT a fake that pretends calls connect. Every method
/// throws or no-ops, so a build without the SDK cannot look like it is placing
/// real calls — the failure is visible in development rather than in front of
/// a user who paid for the line.
final class NullVoiceClient: VoiceClient, @unchecked Sendable {
    enum Unavailable: LocalizedError {
        case noVoiceSDK
        var errorDescription: String? {
            "Calling isn't available in this build."
        }
    }

    func connect(token: String) async throws { throw Unavailable.noVoiceSDK }
    func disconnect() async {}
    func dial(to: String, from: String) async throws -> String? {
        throw Unavailable.noVoiceSDK
    }
    func answer() async throws { throw Unavailable.noVoiceSDK }
    func hangup() async {}
    func setMuted(_ muted: Bool) async {}
    func setSpeaker(_ on: Bool) async {}
    func sendDTMF(_ digit: String) async {}
}
