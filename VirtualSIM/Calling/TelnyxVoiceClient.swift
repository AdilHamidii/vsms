import AVFoundation
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
    private var _voiceToken: String?
    private var _isReady = false
    private var _lastError: Error?

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

    func setDelegate(_ delegate: VoiceClientDelegate?) {
        self.delegate = delegate
    }

    // MARK: - Session

    func connect(token: String) async throws {
        if isReady { return }

        lock.withLock {
            _voiceToken = token
            _isReady = false
            _lastError = nil
        }

        let config = TxConfig(
            token: token,
            pushDeviceToken: lock.withLock { _pushToken },
            pushEnvironment: pushEnvironment,
            logLevel: .error)

        try client.connect(txConfig: config)

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

    func answer() async throws {
        guard let call = currentCall else { throw Fault.noActiveCall }
        call.answer()
    }

    func hangup() async {
        currentCall?.hangup()
        currentCall = nil
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

    func registerPushToken(_ token: String) {
        lock.withLock { _pushToken = token }
    }

    /// Hand the push to the SDK so it can attach to the ringing call.
    ///
    /// Telnyx nests what it needs under `metadata`; `CallController` passes
    /// that dictionary through untouched. A push that arrives before we ever
    /// held a voice token cannot be attached — the call still rings via
    /// CallKit, and answering it fails loudly rather than silently muting.
    func handleVoIPPush(metadata: [String: Any]) {
        let token = lock.withLock { _voiceToken }
        guard let token else { return }

        let config = TxConfig(
            token: token,
            pushDeviceToken: lock.withLock { _pushToken },
            pushEnvironment: pushEnvironment,
            logLevel: .error)

        do {
            try client.processVoIPNotification(
                txConfig: config,
                serverConfiguration: TxServerConfiguration(),
                pushMetaData: metadata)
        } catch {
            lock.withLock { _lastError = error }
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
            delegate?.voiceMediaConnected()
        case .DONE:
            delegate?.voiceRemoteEnded()
        case .DROPPED:
            delegate?.voiceFailed(String(localized: "The call dropped."))
        default:
            break
        }
    }

    func onIncomingCall(call: TelnyxRTC.Call) {
        currentCall = call
    }

    func onPushCall(call: TelnyxRTC.Call) {
        currentCall = call
    }

    func onRemoteCallEnded(callId: UUID, reason: CallTerminationReason?) {
        delegate?.voiceRemoteEnded()
    }
}
