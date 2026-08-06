import AVFoundation
import Foundation

/// Events the WebRTC SDK raises that our call logic has to act on.
///
/// These are `nonisolated` because the SDK delivers them on its own threads.
/// `CallController` implements them in a `nonisolated` extension that hops to
/// the main actor — the same shape as its `CXProviderDelegate` conformance.
protocol VoiceClientDelegate: AnyObject, Sendable {
    /// Media is flowing — the far end actually picked up.
    ///
    /// ⚠️ This is NOT `provider(_:didActivate:)`. CallKit activates the audio
    /// session moments after an outbound call starts, long before the callee
    /// answers, so treating that as "connected" started the billing clock on
    /// a ringing phone. The SDK's own `.ACTIVE` state is the honest signal.
    func voiceMediaConnected()

    /// The far end hung up, or the SDK dropped the call.
    func voiceRemoteEnded()

    /// The call failed in a way the user has to be told about.
    func voiceFailed(_ message: String)
}

/// The seam between our call logic and the WebRTC SDK.
///
/// ── Why this protocol exists ──────────────────────────────────────────────
///
/// It buys three things:
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
/// placed on the account. Treat the first real call as the probe, and read
/// `app_config.telnyx_voice_faults` after it.
protocol VoiceClient: AnyObject, Sendable {
    func setDelegate(_ delegate: VoiceClientDelegate?)

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

    /// The provider's ids for the live call, readable AFTER `dial` returns.
    ///
    /// Telnyx populates these when the far side answers the invite, which can
    /// land after `dial`'s bounded wait gives up. They are re-read when media
    /// connects so a slow handshake still settles against a detail record
    /// instead of falling through to the six-hour backstop.
    var providerSessionId: String? { get }
    var providerLegId: String? { get }

    /// 🔴 **Hand CallKit's audio session to the SDK — without this there is no
    /// audio at all.** CallKit owns the session and passes it to
    /// `provider(_:didActivate:)`; the SDK has to be given that exact instance.
    /// Never call `AVAudioSession.setActive(true)` yourself.
    func audioSessionActivated(_ session: AVAudioSession)
    func audioSessionDeactivated(_ session: AVAudioSession)

    /// The APNs VoIP token, so Telnyx can ring this device. Supplied whenever
    /// PushKit hands us one, which may be before or after `connect`.
    func registerPushToken(_ token: String)

    /// Hand an incoming VoIP push to the SDK so it can attach to the call.
    ///
    /// Called only AFTER `reportNewIncomingCall` has satisfied iOS — see the
    /// PushKit note in `CallController`.
    func handleVoIPPush(metadata: [String: Any])
}

/// The stand-in used on the simulator and any build without a working SDK
/// session.
///
/// It is deliberately NOT a fake that pretends calls connect. Every method
/// throws or no-ops, so a build without a real client cannot look like it is
/// placing real calls — the failure is visible in development rather than in
/// front of a user who paid for the line.
final class NullVoiceClient: VoiceClient, @unchecked Sendable {
    enum Unavailable: LocalizedError {
        case noVoiceSDK
        var errorDescription: String? {
            String(localized: "Calling isn't available in this build.")
        }
    }

    func setDelegate(_ delegate: VoiceClientDelegate?) {}
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

    var providerSessionId: String? { nil }
    var providerLegId: String? { nil }

    func audioSessionActivated(_ session: AVAudioSession) {}
    func audioSessionDeactivated(_ session: AVAudioSession) {}
    func registerPushToken(_ token: String) {}
    func handleVoIPPush(metadata: [String: Any]) {}
}
