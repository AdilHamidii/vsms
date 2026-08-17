import CallKit
import Foundation
import Observation
import PushKit
import AVFoundation

/// Owns everything about a live call: CallKit, PushKit, and the WebRTC client.
///
/// ── Why this is not a `FlowStage` ────────────────────────────────────────
///
/// A call can arrive while a `fullScreenCover` is already open, and
/// `fullScreenCover(item:)` cannot present a second cover. Swapping `flow`
/// mid-checkout would also destroy the user's draft. So the in-call UI is a
/// `ZStack` layer in `ContentView` driven by this object, above the flow cover
/// and below the maintenance and splash overlays — and it must be added to
/// `EnvBundle`, or nothing presented in a cover can see it.
@Observable
@MainActor
final class CallController: NSObject {
    enum Phase: Equatable {
        case idle
        case dialing        // we placed it, not yet ringing at the other end
        case ringing        // inbound, not yet answered
        case connecting     // answered, media negotiating
        case active
        case ending
    }

    private(set) var phase: Phase = .idle
    private(set) var peer: String = ""
    private(set) var isOutbound = true
    private(set) var startedAt: Date?
    private(set) var isMuted = false
    private(set) var isSpeaker = false
    /// Surfaced rather than swallowed: a call that silently fails to start is
    /// indistinguishable from a dead button.
    var lastError: String?

    /// Seconds left this month, mirrored from the line so the dialer can refuse
    /// before a round trip. The SERVER is still the authority —
    /// `begin-line-call` reserves the allowance and can refuse independently.
    var remainingSeconds: Int?

    private let provider: CXProvider
    private let callControl = CXCallController()
    private var voice: VoiceClient
    private var pushRegistry: PKPushRegistry?

    /// The CallKit id for the call in flight. CallKit is keyed on UUID and the
    /// provider is keyed on ours, so they must be the same value or an end
    /// action will not match anything.
    private var currentUUID: UUID?
    /// Our own `line_calls` row, from `begin-line-call`.
    private(set) var currentCallId: String?

    private var apiClient: APIClient?
    private var lineE164: String?

    /// WHICH number this controller is acting as.
    ///
    /// A user may hold several, so "the user's line" is no longer a unique
    /// thing the server can infer. Set it from the screen the user is actually
    /// looking at; when nil the server falls back to a deterministic
    /// oldest-first pick, which never errors but will happily call out from a
    /// different number than the one on screen.
    var activeLineId: String?

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        // Generic handle: the peer is a phone number, and CallKit uses this to
        // decide what the system call log and the lock screen show.
        config.supportedHandleTypes = [.phoneNumber, .generic]
        // ⚠️ Deliberately NOT enabling `includesCallsInRecents` blindly — a
        // rented second number appearing in the system call log as if it were
        // the user's own line is exactly the confusion this product exists to
        // avoid. Left at the default so the entry is attributed to the app.
        self.provider = CXProvider(configuration: config)
        self.voice = NullVoiceClient()
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    func attach(api: APIClient, voice: VoiceClient? = nil) {
        self.apiClient = api
        if let voice {
            self.voice = voice
            voice.setDelegate(self)
            isVoiceAvailable = true
        }
    }

    /// Mint a credential and open the WebRTC session.
    ///
    /// Idempotent — `connect` returns immediately when the client is already
    /// registered — so the dialer can call it on appear and `placeCall` can
    /// call it again without paying for a second handshake. Doing it on appear
    /// means the socket is usually up before the user finishes typing, which
    /// is the difference between a call that rings and one that pauses first.
    @discardableResult
    func prepareVoice() async -> Bool {
        guard isVoiceAvailable, let api = apiClient else { return false }
        do {
            let grant = try await LineAPI(client: api).mintVoiceToken(lineId: activeLineId)
            lineE164 = grant.e164
            try await voice.connect(token: grant.token)
            inboundReady = grant.inboundReady
            return true
        } catch {
            return false
        }
    }

    /// Whether the number is attached to the voice application yet. Outbound
    /// calling works regardless; inbound does not ring until this is true.
    private(set) var inboundReady = false

    /// Whether a real WebRTC client is attached.
    ///
    /// ⚠️ **Every entry point to calling must gate on this.** Until the
    /// `TelnyxRTC` package is added, `NullVoiceClient` throws on every dial —
    /// so an ungated dialer would be a button that always fails, which is
    /// precisely the "advertise a function the app does not perform" problem
    /// the paywall copy was just fixed for. The plumbing ships; the entry point
    /// appears when the SDK does.
    private(set) var isVoiceAvailable = false

    /// Registers for VoIP pushes. Safe to call repeatedly.
    ///
    /// Only worth doing once a line exists — a user with no number can never
    /// receive a call, and registering earlier just asks for a token nothing
    /// will ever send to.
    func registerForVoIPPushes() {
        guard pushRegistry == nil else { return }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        pushRegistry = registry
    }

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    var isLive: Bool { phase != .idle }

    // MARK: - Outbound

    /// Gate, then dial.
    ///
    /// The server call happens FIRST and is allowed to refuse: it checks the
    /// line's status and reserves the voice allowance. Dialing before that
    /// would let a suspended or exhausted line place a call we then have to pay
    /// for and cannot bill.
    func placeCall(to number: String, from lineNumber: String) async {
        guard phase == .idle, let api = apiClient else { return }
        lastError = nil
        peer = number
        isOutbound = true
        phase = .dialing

        // 🔴 THE NUMBER WE DIAL MUST BE THE NUMBER THE SERVER AUTHORISED.
        // `DialerScreen` hands us the raw keypad string, so a US number arrived
        // here as "4054003316" — no `+`, no country code — and went straight to
        // both `CXHandle` and the WebRTC SDK. Every such call failed. Observed
        // live 2026-08-17: a subscriber dialled, failed, redialled the same
        // number with a leading 1 (still not E.164), failed again, and
        // cancelled their subscription four minutes later.
        //
        // `begin-line-call` now normalises to E.164 and echoes the canonical
        // value back, so we adopt ITS answer rather than re-deriving one. That
        // keeps a single definition of the dialled number across the client,
        // the `line_calls` row and the provider — which is also what lets
        // `sync-telnyx-cdr` match a detail record back to the call.
        let dialled: String
        do {
            let begun = try await LineAPI(client: api)
                .beginCall(to: number, lineId: activeLineId)
            currentCallId = begun.callId
            remainingSeconds = begun.remainingSeconds
            dialled = begun.to
            peer = begun.to
        } catch let err as APIError {
            phase = .idle
            lastError = err.userMessage
            RHaptic.warn()
            return
        } catch {
            phase = .idle
            lastError = String(localized: "Couldn't start the call. Please try again.")
            RHaptic.warn()
            return
        }

        // Tell CallKit before the SDK, so the system UI is up while media
        // negotiates. `CXStartCallAction` is what makes this a real call as far
        // as iOS is concerned — audio routing, the green pill, interruption
        // handling with the phone app.
        let uuid = UUID()
        currentUUID = uuid
        let handle = CXHandle(type: .phoneNumber, value: dialled)
        let action = CXStartCallAction(call: uuid, handle: handle)
        do {
            try await callControl.request(CXTransaction(action: action))
        } catch {
            await failCall(String(localized: "iOS wouldn't start the call."))
            return
        }

        do {
            // The socket is normally already up from `prepareVoice()` on the
            // dialer's appear; this covers the case where it timed out or
            // dropped between screens. `connect` returns immediately when the
            // client is registered, so the happy path pays nothing.
            _ = await prepareVoice()

            // ⚠️ The SDK's session id was DISCARDED here (`_ = try await …`),
            // and it is the only key `sync-telnyx-cdr` can match a detail
            // record against. Without it the call kept its whole 120-second
            // reservation forever and the allowance meant nothing.
            let session = try await voice.dial(to: dialled, from: lineNumber)
            report(sessionId: session, legId: voice.providerLegId, status: "ringing")
            provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
        } catch {
            await failCall(error.localizedDescription)
        }
    }

    /// Fire-and-forget, with one retry.
    ///
    /// Never awaited on the call path: a slow network must not delay the ring,
    /// and a failed report is not worth failing a call over. It is also not
    /// silently lost — `settle_stale_calls()` sweeps anything still unsettled
    /// after six hours, so the worst case of losing this is a call settled at
    /// this device's word instead of Telnyx's.
    private func report(
        sessionId: String? = nil,
        legId: String? = nil,
        status: String? = nil,
        answeredAt: Date? = nil,
        durationSeconds: Int? = nil
    ) {
        guard let api = apiClient, let callId = currentCallId else { return }
        Task.detached(priority: .utility) {
            let line = LineAPI(client: api)
            for attempt in 0..<2 {
                do {
                    try await line.reportCall(
                        callId: callId, sessionId: sessionId, legId: legId, status: status,
                        answeredAt: answeredAt, durationSeconds: durationSeconds)
                    return
                } catch {
                    if attempt == 0 { try? await Task.sleep(for: .seconds(2)) }
                }
            }
        }
    }

    // MARK: - Lifecycle

    private func failCall(_ message: String) async {
        lastError = message
        RHaptic.warn()
        await endCall()
    }

    func endCall() async {
        // Reported BEFORE the teardown, because `resetState` clears
        // `currentCallId` and the report needs it. A call that never reached
        // `.active` never connected, so it is `canceled`, not a zero-second
        // `completed` — the difference decides whether the user is billed for
        // it at all when the CDR never arrives.
        report(
            status: phase == .active ? "completed" : "canceled",
            durationSeconds: phase == .active ? Int(elapsed.rounded()) : 0)

        guard let uuid = currentUUID else {
            resetState()
            return
        }
        phase = .ending
        let action = CXEndCallAction(call: uuid)
        // If CallKit refuses, still tear our own state down — otherwise the
        // overlay is stuck over the app with no way out.
        try? await callControl.request(CXTransaction(action: action))
        await voice.hangup()
        resetState()
    }

    func toggleMute() async {
        isMuted.toggle()
        await voice.setMuted(isMuted)
        RHaptic.select()
    }

    func toggleSpeaker() async {
        isSpeaker.toggle()
        await voice.setSpeaker(isSpeaker)
        RHaptic.select()
    }

    func sendDigit(_ d: String) async {
        await voice.sendDTMF(d)
        RHaptic.select()
    }

    private func resetState() {
        phase = .idle
        peer = ""
        startedAt = nil
        isMuted = false
        isSpeaker = false
        currentUUID = nil
        currentCallId = nil
    }

    /// Called by the SDK once media is flowing.
    func mediaConnected() {
        guard phase != .active else { return }
        phase = .active
        let now = Date()
        startedAt = now
        RHaptic.success()
        // `answered_at` had no writer anywhere. It is what separates "they
        // picked up" from "it rang out" on the history row, and the CDR does
        // not carry our notion of it.
        //
        // The provider ids are re-read rather than assumed: Telnyx can assign
        // them after `dial`'s bounded wait gives up, and a row with no session
        // id never matches a detail record — so the call would keep its whole
        // 120-second reservation. Re-sending the SAME id is safe;
        // `attach_line_call_session` is write-once and only refuses a
        // DIFFERENT one.
        report(
            sessionId: voice.providerSessionId, legId: voice.providerLegId,
            status: "answered", answeredAt: now)
        if let uuid = currentUUID, isOutbound {
            provider.reportOutgoingCall(with: uuid, connectedAt: now)
        }
    }

    func remoteEnded() {
        Task { await endCall() }
    }
}

// MARK: - CallKit

extension CallController: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in
            await voice.hangup()
            resetState()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            phase = .connecting
            do {
                try await voice.answer()
                action.fulfill()
            } catch {
                // The phase MUST be reset. Leaving it on `.connecting` left the
                // in-call overlay showing "Connecting…" with no timer and no
                // explanation — `InCallOverlay` reads `phase` and never reads
                // `lastError`, so the only thing on screen was a spinner for a
                // call that had already failed. Reachable whenever the SDK has
                // not attached the call object yet (`answer()` throws
                // `noActiveCall`) or the caller hung up in the same instant.
                lastError = error.localizedDescription
                action.fail()
                await endCall()
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            // ⚠️ THIS FIRES FOR SYSTEM-INITIATED ENDS TOO — the Dynamic Island
            // pill, the lock screen, CarPlay, the Watch. Those never go through
            // `endCall()`, so without reporting here the server was told
            // nothing at all and settlement fell entirely to the CDR cron, or
            // to the 6-hour backstop if Telnyx never billed the call.
            //
            // `endCall()` deliberately reports BEFORE requesting the
            // transaction, so when the user ends from inside the app the report
            // has already been sent and `currentCallId` is nil by the time we
            // get here — `report()` guards on it, so this cannot double-report.
            report(
                status: phase == .active ? "completed" : "canceled",
                durationSeconds: phase == .active ? Int(elapsed.rounded()) : 0)
            await voice.hangup()
            resetState()
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor in
            isMuted = action.isMuted
            await voice.setMuted(action.isMuted)
            action.fulfill()
        }
    }

    /// ⚠️ **NEVER call `AVAudioSession.setActive(true)` yourself.** CallKit
    /// activates the session and hands it over here. Activating it manually is
    /// the classic "no audio on the first call, fine on every call after"
    /// bug — the session is already owned by the system by the time your code
    /// runs, and the second activation is what breaks it.
    ///
    /// 🔴 The SDK must be handed THIS session instance or there is no audio at
    /// all — the call connects, the timer runs, and neither side hears
    /// anything.
    ///
    /// ⚠️ This deliberately no longer calls `mediaConnected()`. CallKit
    /// activates audio moments after an OUTBOUND call starts, long before the
    /// callee answers, so treating it as "connected" started the billing clock
    /// and the on-screen timer on a phone that was still ringing. The SDK's own
    /// `.ACTIVE` state is the honest signal and now drives it.
    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task { @MainActor in voice.audioSessionActivated(audioSession) }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor in voice.audioSessionDeactivated(audioSession) }
    }
}

// MARK: - PushKit

extension CallController: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry,
                                  didUpdate credentials: PKPushCredentials,
                                  for type: PKPushType) {
        guard type == .voIP else { return }
        let token = credentials.token.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            // The SDK needs it too: Telnyx sends the VoIP push itself, and a
            // credential registered without this token can never ring.
            voice.registerPushToken(token)
            await uploadVoIPToken(token)
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry,
                                  didInvalidatePushTokenFor type: PKPushType) { }

    /// 🔴 **`reportNewIncomingCall` MUST be called synchronously, here, before
    /// any `await`.**
    ///
    /// iOS terminates the app if a `.voIP` push does not produce an incoming
    /// call report inside this callback — and on repeat offences it stops
    /// delivering VoIP pushes to the app entirely, which is not recoverable by
    /// shipping a fix. So the call is reported from the PAYLOAD alone, with no
    /// network round trip and no SDK involvement, and the SDK is handed the
    /// push afterwards.
    ///
    /// The completion handler is invoked in `reportNewIncomingCall`'s own
    /// completion, which is what tells iOS the obligation was met.
    nonisolated func pushRegistry(_ registry: PKPushRegistry,
                                  didReceiveIncomingPushWith payload: PKPushPayload,
                                  for type: PKPushType,
                                  completion: @escaping () -> Void) {
        guard type == .voIP else { completion(); return }

        let info = payload.dictionaryPayload
        let from = (info["from"] as? String) ?? (info["caller"] as? String) ?? ""
        let uuid = (info["uuid"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .phoneNumber, value: from)
        update.hasVideo = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsHolding = false

        // Telnyx nests what its SDK needs under `metadata`. Captured before the
        // report so the closure does not reach back into the payload.
        let metadata = info["metadata"] as? [String: Any]

        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            // Only AFTER the obligation is met do we touch our own state, or
            // hand anything to the SDK. Attaching first would put a network
            // round trip ahead of the one call iOS is waiting for.
            Task { @MainActor in
                guard let self, error == nil else { completion(); return }
                self.currentUUID = uuid
                self.peer = from
                self.isOutbound = false
                self.phase = .ringing
                if let metadata { self.voice.handleVoIPPush(metadata: metadata) }
                completion()
                // STRICTLY AFTER `completion()`. iOS is waiting on that call and
                // nothing may sit in front of it — registering the call is
                // bookkeeping, and bookkeeping never delays the obligation that
                // keeps VoIP push delivery alive for this app.
                await self.registerInboundCall(peer: from)
            }
        }
    }

    /// Create the server-side `line_calls` row for an INBOUND call.
    ///
    /// 🔴 Without this an inbound call did not exist as far as the backend was
    /// concerned. `record_line_call` had exactly one caller — `begin-line-call`
    /// on the outbound path — so `currentCallId` was never set for an inbound
    /// call, `report()` guards on it and silently no-opped, and the call left
    /// no history row and nothing for `sync-telnyx-cdr` to match its detail
    /// record against. The minutes Telnyx billed us were attributed to nobody.
    ///
    /// Registering does NOT bill the user: the server reserves zero for
    /// inbound, deliberately, because nobody controls who calls them.
    private func registerInboundCall(peer: String) async {
        guard let api = apiClient, currentCallId == nil, !peer.isEmpty else { return }
        do {
            // `activeLineId` is the line the app was last showing. For an
            // inbound call that is a guess: the push names the CALLER, not
            // which of our numbers was dialled. It is right for the common case
            // (one number, or the one you are looking at) and the server's
            // fallback is deterministic either way — but attributing an inbound
            // call to the wrong number of your own is a real defect, and fixing
            // it properly needs the callee in the push payload.
            let grant = try await LineAPI(client: api)
                .beginCall(to: peer, direction: "inbound", lineId: activeLineId)
            // The call can end while this round trip is in flight; adopting the
            // id then would attach it to whatever comes next.
            guard phase != .idle, currentUUID != nil else { return }
            currentCallId = grant.callId
        } catch {
            // Never fail a ringing call over bookkeeping. The consequence is a
            // missing history row, not a broken call — and the 6-hour sweep
            // still has nothing to mis-settle, because no row was created.
            lastError = nil
        }
    }

    private func uploadVoIPToken(_ token: String) async {
        guard let api = apiClient else { return }
        // Registered under its own kind so `_shared/apns.ts` can send a VoIP
        // push-type to the VoIP topic — an alert token and a VoIP token are
        // different tokens and are not interchangeable.
        try? await PushAPI(client: api).register(
            token: token,
            environment: pushEnvironment,
            bundleId: (Bundle.main.bundleIdentifier ?? "com.anthersystems.VirtualSIM") + ".voip"
        )
    }

    /// From the provisioning profile, never `#if DEBUG` — see
    /// `APNSEnvironment` for why the two disagree in this project.
    private var pushEnvironment: String { APNSEnvironment.current.rawValue }
}

// MARK: - VoiceClient events

/// The SDK delivers these on its own threads, so each one hops to the main
/// actor — the same shape as the `CXProviderDelegate` conformance above.
extension CallController: VoiceClientDelegate {
    nonisolated func voiceMediaConnected() {
        Task { @MainActor in mediaConnected() }
    }

    nonisolated func voiceRemoteEnded() {
        Task { @MainActor in remoteEnded() }
    }

    nonisolated func voiceFailed(_ message: String) {
        Task { @MainActor in await failCall(message) }
    }
}
