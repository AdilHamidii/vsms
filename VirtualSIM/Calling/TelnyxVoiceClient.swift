import AVFoundation
import CallKit
import Foundation
import TelnyxRTC

/// The real WebRTC client, over Telnyx's `TxClient`.
///
/// ── What this file is responsible for ─────────────────────────────────────
///
/// Everything SDK-shaped, and nothing else. CallKit, PushKit, the allowance
/// gate and the in-call UI all live in `CallController` and talk to this
/// through `VoiceClient` — so replacing Telnyx is one file, and the CallKit
/// rules that iOS enforces are not tangled up with a vendor's API.
///
/// ⚠️ **The server-side voice adapters were written from documentation and the
/// detail-records block beside them was wrong twice.** Nothing here has been
/// exercised against a real call either: the account has never placed one. The
/// first real call IS the probe — read `app_config.telnyx_voice_faults` and
/// `telnyx_cdr_probe` after it, and expect to correct something.
///
/// ⚠️ **Voice cannot be tested on a simulator.** PushKit does not deliver VoIP
/// pushes there, so inbound calling is device-only. Outbound may appear to work
/// and is not proof.
final class TelnyxVoiceClient: NSObject, VoiceClient, @unchecked Sendable {
    enum Fault: LocalizedError {
        case notConnected
        case connectTimedOut
        case noActiveCall

        var errorDescription: String? {
            switch self {
            case .notConnected, .connectTimedOut:
                String(localized: "Couldn't reach the calling network.")
            case .noActiveCall:
                String(localized: "That call has already ended.")
            }
        }
    }

    private let client = TxClient()
    private weak var delegate: VoiceClientDelegate?

    /// Guards everything below it. The SDK calls back on its own threads while
    /// `CallController` drives this from the main actor.
    private let lock = NSLock()
    private var _call: TelnyxRTC.Call?
    private var _pushToken: String?
    private var _credential: VoiceCredential?
    private var _isReady = false
    private var _lastError: Error?
    /// Whether the call in flight arrived as a VoIP push.
    ///
    /// Decides which CallKit path is correct, and the SDK does not expose its
    /// own `isCallFromPush`. Cleared the moment the call goes ACTIVE, because
    /// the SDK clears its flag then too (`TxClient.swift:1426`,
    /// `resetPushVariables`) — after that an end must take the ordinary
    /// hangup path.
    private var _fromPush = false

    override init() {
        super.init()
        client.delegate = self
    }

    // MARK: - Locked accessors

    private var currentCall: TelnyxRTC.Call? {
        get { lock.withLock { _call } }
        set { lock.withLock { _call = newValue } }
    }

    private var isReady: Bool { lock.withLock { _isReady } }

    /// Whether the live session is already authenticated as this exact
    /// identity. A `.sip` session and a `.token` session are NOT
    /// interchangeable: only the registered SIP user can be rung.
    private func sameCredential(_ candidate: VoiceCredential) -> Bool {
        lock.withLock { _credential == candidate }
    }

    func setDelegate(_ delegate: VoiceClientDelegate?) {
        self.delegate = delegate
    }

    // MARK: - Session

    func connect(_ credential: VoiceCredential) async throws {
        // 🔴 A READY SESSION IS ONLY REUSABLE IF IT IS THE SAME CREDENTIAL.
        //
        // This used to be a bare `if isReady { return }`, which silently
        // ignored the credential it was handed. A session already up on a
        // `.token` therefore stayed token-only while the caller went on to
        // persist the `.sip` pair and set `inboundReady = true` — telling the
        // user their number would ring on a socket that cannot receive, and
        // storing a SIP credential that had never logged in. There are four
        // `prepareVoice()` entry points, so this happened on ordinary launches,
        // not just edge cases.
        if isReady, sameCredential(credential) { return }
        // Changing identity means tearing the old session down first; the SDK
        // holds one login per client.
        if isReady { client.disconnect() }

        lock.withLock {
            _credential = credential
            _isReady = false
            _lastError = nil
        }

        try client.connect(txConfig: config(credential))

        // Polled rather than awaited on a continuation: `onClientReady` and
        // `onClientError` can both fire, or neither, and a continuation resumed
        // twice is a crash while one never resumed is a permanently stuck
        // dialer. Polling cannot get that wrong.
        let ready = await waitUntil(timeout: 15) { [weak self] in self?.isReady ?? false }
        guard ready else {
            throw lock.withLock { _lastError } ?? Fault.connectTimedOut
        }
    }

    func disconnect() async {
        client.disconnect()
        lock.withLock {
            _call = nil
            _isReady = false
            _fromPush = false
            // Dropped too: a credential outlives the session it was minted
            // for, and the next sign-in on this device is a different account.
            _credential = nil
        }
    }

    var isConnected: Bool { client.isConnected() }

    /// One definition of the login configuration.
    ///
    /// 🔴 **`enableMissedCallNotifications` must be true and must be identical
    /// on every path.** It defaults to false, and the v4 migration is explicit
    /// (`docs-markdown/migrations/v3-to-v4.md:53`): *"the default (`false`)
    /// means Telnyx servers will not send missed call pushes to your app"* —
    /// so without it the "Missed call!" / "Answered Elsewhere" dismissal
    /// handling in `CallController` can never run and a caller who hangs up
    /// leaves the CallKit screen ringing until iOS times it out. The SDK's own
    /// guidance (`v3-to-v4.md:50`) is to pass it consistently at every
    /// connection point, `processVoIPNotification` included — the login it
    /// produces is what tags the user agent.
    private func config(_ credential: VoiceCredential) -> TxConfig {
        let push = lock.withLock { _pushToken }
        switch credential {
        // 🔴 The SIP initializer is what makes the connection REGISTER, and a
        // registration is the only thing an inbound call can be routed to.
        // The token initializer below authenticates without registering the
        // identity the phone number points at, so a session built from it can
        // dial out forever and never ring.
        case let .sip(username, password):
            return TxConfig(
                sipUser: username,
                password: password,
                pushDeviceToken: push,
                pushEnvironment: pushEnvironment,
                enableMissedCallNotifications: true,
                logLevel: .error)
        case let .token(token):
            return TxConfig(
                token: token,
                pushDeviceToken: push,
                pushEnvironment: pushEnvironment,
                enableMissedCallNotifications: true,
                logLevel: .error)
        }
    }

    // MARK: - Calls

    func dial(to: String, from: String) async throws -> String? {
        guard isReady else { throw Fault.notConnected }

        // `callerNumber` is the rented line, which is what the far end sees.
        let call = try client.newCall(
            callerName: "",
            callerNumber: from,
            destinationNumber: to,
            callId: UUID())
        currentCall = call

        // Telnyx assigns its session id when the invite is acknowledged, which
        // is normally well under a second but is not synchronous with
        // `newCall`. Bounded so a slow handshake delays the ring by at most
        // this much; if it expires the id is re-read when media connects.
        _ = await waitUntil(timeout: 6) { [weak self] in self?.providerSessionId != nil }
        return providerSessionId
    }

    func answer(action: CXAnswerCallAction) throws -> CallKitHandoff {
        // A push-woken call: there is normally NO `Call` object yet, because
        // the INVITE only follows the login this very call triggers. The SDK
        // holds the action and fulfills it when the INVITE lands
        // (`TxClient.swift:1423-1426`), or ends the call on its own 10-second
        // INVITE timeout (`:838-858`) — which it starts ONLY when it is
        // holding an answer action (`:1121-1124`). Answering `currentCall`
        // here instead is what made every push call fail on the spot.
        if lock.withLock({ _fromPush }) {
            client.answerFromCallkit(answerAction: action)
            return .sdkOwnsAction
        }
        // Delivered over a live socket: `onIncomingCall` has already handed us
        // the call, so this is the proven path and stays untouched.
        guard let call = currentCall else { throw Fault.noActiveCall }
        call.answer()
        return .callerMustResolve
    }

    func end(action: CXEndCallAction) -> CallKitHandoff {
        // Declining a push call has to reach Telnyx as `decline_push` on the
        // login (`TxClient.swift:871-916`); a local hangup on a call object we
        // do not have yet reaches nobody and the caller keeps hearing ringback.
        if lock.withLock({ _fromPush }) {
            lock.withLock { _fromPush = false }
            client.endCallFromCallkit(endAction: action)
            currentCall = nil
            return .sdkOwnsAction
        }
        // ⚠️ Everything else deliberately does NOT go through the SDK:
        // `endCallFromCallkit` FAILS the action when it holds no call under
        // that UUID (`TxClient.swift:927-930`), and an outbound call's CallKit
        // UUID is ours, not the SDK's — so routing outbound through it would
        // make ending a call impossible.
        return .callerMustResolve
    }

    func hangup() async {
        currentCall?.hangup()
        currentCall = nil
        lock.withLock { _fromPush = false }
    }

    func setMuted(_ muted: Bool) async {
        guard let call = currentCall else { return }
        muted ? call.muteAudio() : call.unmuteAudio()
    }

    func setSpeaker(_ on: Bool) async {
        on ? client.setSpeaker() : client.setEarpiece()
    }

    func sendDTMF(_ digit: String) async {
        currentCall?.dtmf(dtmf: digit)
    }

    // MARK: - Identifiers for settlement

    /// ⚠️ **Lowercased deliberately.** `UUID.uuidString` is UPPERCASE and
    /// Telnyx's detail records carry lowercase uuids, while `sync-telnyx-cdr`
    /// matches with an exact-string `Map` lookup. Uppercase here would settle
    /// nothing and look exactly like a provider that never reported the call.
    var providerSessionId: String? {
        currentCall?.telnyxSessionId?.uuidString.lowercased()
    }

    var providerLegId: String? {
        currentCall?.telnyxLegId?.uuidString.lowercased()
    }

    // MARK: - Audio session

    /// 🔴 CallKit owns the session and hands it over. The SDK must be given
    /// that exact instance, and nothing here may call `setActive(true)` — see
    /// the note on `CallController.provider(_:didActivate:)`.
    func audioSessionActivated(_ session: AVAudioSession) {
        client.enableAudioSession(audioSession: session)
    }

    func audioSessionDeactivated(_ session: AVAudioSession) {
        client.disableAudioSession(audioSession: session)
    }

    /// Re-enable the audio unit after `newCall` has built the peer — see the
    /// long note on `VoiceClient.reassertAudioSession()` for why this is not
    /// redundant with `audioSessionActivated`.
    ///
    /// `isAudioDeviceEnabled` rather than `enableAudioSession`: the setter does
    /// exactly the two things needed here (tell WebRTC the session is live and
    /// switch the audio unit on) and nothing else. `enableAudioSession` also
    /// re-applies the category and calls `setActive(true)` on a session CallKit
    /// already activated, which is the churn the CallKit rules warn about — it
    /// is the right call ONCE, from `provider(_:didActivate:)`, and the wrong
    /// one to repeat mid-call.
    func reassertAudioSession() {
        guard !client.isAudioDeviceEnabled else { return }
        client.isAudioDeviceEnabled = true
    }

    // MARK: - Push

    @discardableResult
    func registerPushToken(_ token: String) -> Bool {
        lock.withLock {
            guard _pushToken != token else { return false }
            _pushToken = token
            return true
        }
    }

    /// Hand the push to the SDK so it can attach to the ringing call.
    ///
    /// Telnyx nests what it needs under `metadata`; `CallController` passes
    /// that dictionary through untouched. The credential comes from the caller
    /// — see `handleVoIPPush` on the protocol.
    ///
    /// `TxServerConfiguration()` is the bare default on purpose: the SDK
    /// rebuilds it from the push metadata itself, keying the region off
    /// `voice_sdk_id` (`TxClient.swift:1474-1479`).
    func handleVoIPPush(metadata: [String: Any], credential: VoiceCredential) throws {
        // Kept so a later `connect()` and any re-login reuse the same
        // credential the push flow authenticated with.
        lock.withLock {
            _credential = credential
            _fromPush = true
        }
        do {
            try client.processVoIPNotification(
                txConfig: config(credential),
                serverConfiguration: TxServerConfiguration(),
                pushMetaData: metadata)
        } catch {
            lock.withLock {
                _lastError = error
                _fromPush = false
            }
            throw error
        }
    }

    // MARK: - Helpers

    /// 🔴 Must match the gateway the token was actually issued for. Telnyx
    /// sends the VoIP push itself, so getting this wrong means the push is
    /// delivered to the wrong APNs environment and dropped — the phone never
    /// rings and nothing anywhere reports an error.
    ///
    /// Derived from the provisioning profile rather than `#if DEBUG`: Xcode
    /// signs *Run* with the Development profile whatever the configuration, so
    /// a Release build on a device holds a sandbox token. See
    /// `APNSEnvironment`.
    private var pushEnvironment: PushEnvironment {
        APNSEnvironment.current == .sandbox ? .debug : .production
    }

    private func waitUntil(
        timeout: TimeInterval,
        _ satisfied: @Sendable @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if satisfied() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return satisfied()
    }
}

// MARK: - TxClientDelegate

extension TelnyxVoiceClient: TxClientDelegate {
    func onSocketConnected() {}

    func onSocketDisconnected() {
        lock.withLock { _isReady = false }
    }

    func onClientReady() {
        lock.withLock { _isReady = true }
    }

    func onClientError(error: Error) {
        lock.withLock {
            _lastError = error
            _isReady = false
        }
        // Only surfaced when a call is actually in flight. A socket blip while
        // idle is recovered by the SDK and is not the user's problem; an error
        // banner over an idle screen is noise that trains people to ignore it.
        if currentCall != nil {
            delegate?.voiceFailed(error.localizedDescription)
        }
    }

    func onPushDisabled(success: Bool, message: String) {}

    /// The websocket session, NOT the per-call session id. `sync-telnyx-cdr`
    /// matches on the latter — see `providerSessionId`.
    func onSessionUpdated(sessionId: String) {}

    func onCallStateUpdated(callState: CallState, callId: UUID) {
        switch callState {
        case .ACTIVE:
            // The SDK clears its own push state once an answered push call is
            // established (`TxClient.swift:1426`); ours has to follow, or
            // ending the call would take the decline path for a call that is
            // already up.
            lock.withLock { _fromPush = false }
            delegate?.voiceMediaConnected()
        case .DONE:
            lock.withLock { _fromPush = false }
            delegate?.voiceRemoteEnded()
        case .DROPPED:
            delegate?.voiceFailed(String(localized: "The call dropped."))
        default:
            break
        }
    }

    /// A call arriving over an already-open socket.
    ///
    /// 🔴 This used to ONLY stash the call, so nothing ever rang: CallKit was
    /// reached exclusively from the PushKit callback. Raise it here too, using
    /// the SDK's own call id so the CallKit UUID and the SDK's call are the
    /// same value — an end or answer action keyed on anything else matches
    /// nothing.
    func onIncomingCall(call: TelnyxRTC.Call) {
        currentCall = call
        guard let info = call.callInfo else { return }
        delegate?.voiceIncomingCall(
            id: info.callId,
            from: info.callerNumber ?? "",
            callerName: info.callerName ?? "")
    }

    func onPushCall(call: TelnyxRTC.Call) {
        currentCall = call
    }

    func onRemoteCallEnded(callId: UUID, reason: CallTerminationReason?) {
        delegate?.voiceRemoteEnded()
    }
}
