import AVFoundation
import CallKit
import Foundation

/// Who is responsible for resolving a CallKit action.
///
/// 🔴 **The SDK resolves some actions itself and it is not optional to know
/// which.** `TxClient.answerFromCallkit` stores the action and fulfills it only
/// once the INVITE arrives (`TxClient.swift:1423-1426`) or its own 10-second
/// INVITE timeout fires (`:838-858`); fulfilling it ourselves as well is a
/// double-fulfill. Conversely an action nobody resolves is a call CallKit
/// eventually kills on its own.
/// What the app logs in to Telnyx with.
///
/// 🔴 **THE TWO CASES ARE NOT INTERCHANGEABLE, AND THE DIFFERENCE IS WHETHER
/// THE PHONE CAN RING AT ALL.**
///
/// `.token` is minted from an on-demand telephony credential. It authenticates
/// and it dials — 131 completed outbound calls deep — but Telnyx documents that
/// credential type as outbound-only, and a call to the rented number never
/// reaches it. Measured on a live line 2026-09-07 with the app connected: the
/// telephony credential read `registered: true` while the connection the number
/// actually points at read `registered: false`, and every inbound attempt was
/// cleared by Telnyx in under a second with no media leg. That is the whole of
/// why inbound has never once worked.
///
/// `.sip` is the CONNECTION's own user, which is the identity a DID is routed
/// to. Registering as it is what makes an incoming call reach this device.
///
/// `.token` is kept because the server may be older than this build, and
/// because outbound must never regress while inbound is being fixed.
enum VoiceCredential: Equatable {
    case sip(username: String, password: String)
    case token(String)

    /// True for the only case that can receive a call.
    var canReceiveInbound: Bool {
        if case .sip = self { return true }
        return false
    }
}

enum CallKitHandoff {
    /// The SDK now owns the action and will `fulfill()` or `fail()` it.
    case sdkOwnsAction
    /// Nothing else will touch it — the caller must resolve it.
    case callerMustResolve
}

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

    /// A call arrived over an ALREADY-OPEN socket, with no VoIP push involved.
    ///
    /// 🔴 This is the OTHER half of inbound, and it had no implementation at
    /// all: `reportNewIncomingCall` appeared exactly once in the app, inside
    /// the PushKit callback, so a call the SDK delivered over a live socket
    /// never reached CallKit and the phone simply never rang. Anything that
    /// wants to ring has to go through CallKit — there is no other way to
    /// raise a call UI on iOS.
    func voiceIncomingCall(id: UUID, from: String, callerName: String)

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

    /// Connect using a credential from `mint-line-token`. The API key never
    /// reaches the device.
    ///
    /// ⚠️ Pass `.sip` whenever the server offered it — see `VoiceCredential`.
    /// Connecting with `.token` yields a session that can dial out and can
    /// never be rung.
    func connect(_ credential: VoiceCredential) async throws

    func disconnect() async

    /// Place a call. Returns the provider's session id once the SDK has one,
    /// which is what `sync-telnyx-cdr` matches a detail record against.
    func dial(to: String, from: String) async throws -> String?

    /// Answer the call CallKit is asking us to answer.
    ///
    /// 🔴 **Takes the `CXAnswerCallAction` rather than answering blind, because
    /// a push-woken call has no `Call` object yet.** The INVITE only arrives
    /// after the SDK logs in and sends `attachCall`, which is a websocket round
    /// trip after the phone has already started ringing — so answering in the
    /// first second or two found nothing to answer and threw. Telnyx's own
    /// rule (`docs-markdown/index.md:409`): *"When receiving calls from push
    /// notifications, it is always required to wait for the connection to the
    /// WebSocket before fulfilling the call answer action"*, via
    /// `answerFromCallkit(answerAction:)` — which also starts the SDK's INVITE
    /// timeout (`TxClient.swift:1121-1124`), the thing that ends a call whose
    /// INVITE never comes.
    ///
    /// Synchronous on purpose: it is called from the main actor and
    /// `CXAnswerCallAction` is not `Sendable`, so an `async` signature would
    /// hop executors and stop compiling under strict concurrency.
    func answer(action: CXAnswerCallAction) throws -> CallKitHandoff

    /// End the call CallKit is asking us to end.
    ///
    /// The push case must go through the SDK so a DECLINE is sent as
    /// `decline_push` on the login (`TxClient.swift:871-916`) instead of
    /// leaving the caller listening to ringback. Every other case stays on
    /// `hangup()`, which is proven — note `endCallFromCallkit` FAILS the action
    /// when it holds no call under that exact UUID (`TxClient.swift:927-930`),
    /// and our outbound calls carry a CallKit UUID the SDK has never seen.
    func end(action: CXEndCallAction) -> CallKitHandoff

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

    /// 🔴 **Re-assert audio AFTER the SDK has built the call, or an outbound
    /// call is silent both ways.**
    ///
    /// Creating a call makes the SDK build a `Peer`, and a `Peer` turns WebRTC's
    /// manual audio mode on and the audio unit OFF (`useManualAudio = true`,
    /// `isAudioEnabled = false`) so that CallKit, not WebRTC, decides when
    /// audio starts. Telnyx's own sample places the call from inside
    /// `provider(_:perform: CXStartCallAction)` and fulfills only afterwards,
    /// so that disable always happens BEFORE CallKit activates the session and
    /// `audioSessionActivated` re-enables it.
    ///
    /// We fulfill the action first — the allowance gate has to be able to
    /// refuse a call before CallKit ever hears about it — so our order is
    /// reversed: CallKit activates, we enable, and only then does `dial` build
    /// the peer that switches audio back off. Nothing in the normal call path
    /// ever turns it back on. The call connects, the timer runs, a session id
    /// is issued, and neither side hears anything.
    ///
    /// So the enable is re-asserted once the peer exists. It must only be
    /// called while CallKit has actually handed the session over — see
    /// `CallController.reassertAudioIfActive()`.
    func reassertAudioSession()

    /// The APNs VoIP token, so Telnyx can ring this device. Supplied whenever
    /// PushKit hands us one, which may be before or after `connect`.
    ///
    /// Returns true when the value CHANGED. Telnyx only learns a token from a
    /// login message (`TxClient.swift:1779-1804`), and the config is captured
    /// at `connect` time — so a token that rotates while the socket is up has
    /// to force a re-login or Telnyx keeps pushing to the dead one.
    @discardableResult
    func registerPushToken(_ token: String) -> Bool

    /// Whether a socket session is currently established.
    var isConnected: Bool { get }

    /// Hand an incoming VoIP push to the SDK so it can attach to the call.
    ///
    /// Called only AFTER `reportNewIncomingCall` has satisfied iOS — see the
    /// PushKit note in `CallController`.
    ///
    /// The credential is passed in rather than read from the live session: the
    /// whole point is that this path runs when there is no live session, from a
    /// credential the caller either restored from the Keychain or just minted.
    /// It THROWS so the caller can tell a failed handoff from a silent one —
    /// `TxClient.processVoIPNotification` rejects metadata with no
    /// `voice_sdk_id` (`TxClient.swift:1459-1467`), which is the single most
    /// diagnostic failure on this path and used to be discarded.
    func handleVoIPPush(metadata: [String: Any], credential: VoiceCredential) throws
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
    func connect(_ credential: VoiceCredential) async throws { throw Unavailable.noVoiceSDK }
    func disconnect() async {}
    func dial(to: String, from: String) async throws -> String? {
        throw Unavailable.noVoiceSDK
    }
    func answer(action: CXAnswerCallAction) throws -> CallKitHandoff {
        throw Unavailable.noVoiceSDK
    }
    func end(action: CXEndCallAction) -> CallKitHandoff { .callerMustResolve }
    func hangup() async {}
    func setMuted(_ muted: Bool) async {}
    func setSpeaker(_ on: Bool) async {}
    func sendDTMF(_ digit: String) async {}

    var providerSessionId: String? { nil }
    var providerLegId: String? { nil }

    func audioSessionActivated(_ session: AVAudioSession) {}
    func audioSessionDeactivated(_ session: AVAudioSession) {}
    func reassertAudioSession() {}
    @discardableResult
    func registerPushToken(_ token: String) -> Bool { false }
    var isConnected: Bool { false }
    func handleVoIPPush(metadata: [String: Any], credential: VoiceCredential) throws {
        throw Unavailable.noVoiceSDK
    }
}
