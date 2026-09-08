import SwiftUI

/// Start a conversation with someone who has never texted us.
///
/// ── Why this screen has to exist ──────────────────────────────────────────
///
/// `line_threads` rows are created by an inbound message or by an outbound
/// send, and every path to `ThreadScreen` goes through a thread that already
/// exists. So without this the Messages segment can only ever REPLY.
///
/// ── History, because it decides what this screen may claim ────────────────
///
/// Deleted 2026-08-18 when outbound SMS was retired, restored 2026-09-08 when
/// a US → CA send delivered. **That send was ON-NET** — both numbers are on
/// our own Telnyx account — and no number we own carries a 10DLC campaign, so
/// a real carrier may still reject a message this screen happily accepts. The
/// rejection arrives asynchronously as a delivery receipt, minutes later, and
/// shows up under the bubble in `ThreadScreen` rather than here.
///
/// Which is exactly why this screen promises nothing about delivery: it states
/// what the number can ADDRESS (US and Canada), refuses what it cannot, and
/// leaves the outcome to the transcript. Do not add reassurance here.
///
/// It sends through `AppState.sendLineMessage`, which already handles the
/// brand-new-conversation case (falling back to the visible line when there is
/// no thread to take the line from) and already re-reads the thread list, the
/// messages and the allowance afterwards. Nothing here duplicates that.
struct ComposeScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api

    @State private var to = ""
    @State private var text = ""
    @State private var sending = false
    @FocusState private var focus: Field?

    private enum Field { case to, body }

    /// Same set as the dialer and the server. A text to an emergency short
    /// code must never look like it worked — E911 is disabled on these
    /// numbers at the provider, so it would fail at the worst possible moment.
    private static let emergency: Set<String> = [
        "911", "112", "999", "000", "110", "119", "988",
    ]

    private var isEmergency: Bool {
        Self.emergency.contains(to.filter(\.isNumber))
    }

    /// nil until the recipient could actually be addressed. This is what the
    /// send uses — never the raw field — because the server passes `to`
    /// through to Telnyx once it has normalised it.
    private var recipient: String? {
        isEmergency ? nil : PhoneFormat.e164(to)
    }

    /// A recipient outside the +1 plan is refused by `send-line-message`
    /// (`international_sms`), because `features.sms.international_outbound`
    /// reads false on every number we own. Saying so on the field costs
    /// nothing; letting them type a message first and refusing it afterwards
    /// costs them the message.
    private var isOutsideNanp: Bool {
        guard let r = recipient else { return false }
        return !(r.hasPrefix("+1") && r.filter(\.isNumber).count == 11)
    }

    private var block: Line.SendBlock? { state.line?.sendBlock }
    private var remaining: Int? { state.line?.smsRemaining }

    private var canSend: Bool {
        recipient != nil && !isOutsideNanp && block == nil && !sending
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        toField
                        bodyField
                        if let note { notice(note, warning: isWarning) }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                }
                PrimaryButton(
                    label: String(localized: "Send"),
                    disabled: !canSend,
                    action: send
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
        }
        .task {
            // 🔴 Load-bearing. `sendLineMessage` takes the sending line from
            // the OPEN THREAD when there is one, which is correct for a reply
            // and wrong here — a stale `openThreadId` would send this new
            // message from whichever conversation was last on screen, and out
            // of that number's allowance.
            state.openThreadId = nil
            focus = .to
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 12) {
            Button { state.flow = nil } label: {
                Image(systemName: RIcon.close)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.text2)
                    .frame(width: 34, height: 34)
                    .background(theme.chipBg, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close"))

            VStack(alignment: .leading, spacing: 1) {
                Text("New message")
                    .font(RFont.display(19, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(theme.text)
                if let line = state.line {
                    Text("From \(PhoneFormat.national(line.e164))")
                        .font(RFont.text(12))
                        .foregroundStyle(theme.text2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var toField: some View {
        Card(elevation: .flat) {
            HStack(spacing: 12) {
                Text("To")
                    .font(RFont.text(14))
                    .foregroundStyle(theme.text2)
                    .frame(width: 30, alignment: .leading)
                TextField("Phone number", text: $to)
                    .font(RFont.mono(16, weight: .medium))
                    .foregroundStyle(theme.text)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .focused($focus, equals: .to)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    private var bodyField: some View {
        Card(elevation: .flat) {
            TextField("Message", text: $text, axis: .vertical)
                .onChange(of: text) { _, _ in clampBody() }
                .font(RFont.text(16))
                .foregroundStyle(theme.text)
                .lineLimit(3...8)
                .focused($focus, equals: .body)
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
        }
    }

    /// One line, and only when there is something true to say. An always-on
    /// hint under a text field is noise; every one of these changes what the
    /// button will do.
    ///
    /// Ordered by how badly the user needs it: a hard refusal first, the
    /// typo-in-progress next, the running count last.
    private var note: LocalizedStringKey? {
        if isEmergency { return "This number can't text emergency services. Use your phone's own number." }
        switch block {
        case .allowanceExhausted:
            return "You've used this month's texts. They reset when your subscription renews."
        case .pastDue:
            return "Renew your subscription to send messages again."
        case .suspended:
            // No hold since 2026-09-05 — the number is gone, and resubscribing
            // provisions a new one. See LineScreen's banner.
            return "This number has been released. Resubscribe to get a new one."
        case .notLive:
            return "Your number isn't ready yet."
        case nil:
            break
        }
        if isOutsideNanp { return "This number can only text US and Canadian numbers." }
        if !to.isEmpty && recipient == nil { return "That doesn't look like a phone number yet." }
        if let remaining, remaining <= 10 { return "\(remaining) texts left this month." }
        return nil
    }

    private var isWarning: Bool { isEmergency || isOutsideNanp || block != nil }

    private func notice(_ key: LocalizedStringKey, warning: Bool) -> some View {
        Text(key)
            .font(RFont.text(12))
            .foregroundStyle(warning ? theme.warn : theme.text2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    // MARK: - Send

    /// The server refuses a body over this and the refusal costs a round trip,
    /// so the text field clamps instead. Keep it in step with
    /// `send-line-message`'s own limit.
    private static let maxBodyLength = 1600

    private func clampBody() {
        if text.count > Self.maxBodyLength {
            text = String(text.prefix(Self.maxBodyLength))
        }
    }

    private func send() {
        // 🔴 SET BEFORE THE `Task`. Inside it, both taps of a double-tap pass
        // the check before either body runs, and `begin_outbound_message` has
        // no dedupe window — two rows, two allowance segments, the same text
        // delivered twice.
        guard !sending else { return }
        guard let recipient else { return }
        sending = true
        Task {
            defer { sending = false }
            let ok = await state.sendLineMessage(
                using: LineAPI(client: api), to: recipient, text: text)
            if ok {
                RHaptic.success()
                // `sendLineMessage` set `openThreadId` from the server's
                // response, so the conversation the user just started is what
                // opens — not the list they came from. It is also where the
                // delivery receipt will land, which is the only place the
                // send's real outcome is ever stated.
                //
                // ⚠️ DISMISS FIRST, THEN RAISE. Swapping one
                // `fullScreenCover(item:)` identity for another in a single
                // step is not a transition SwiftUI performs reliably — the
                // second stage can simply never appear, and a successful send
                // is the one moment the user must not land on a blank screen.
                // Same hop, and the same reason, as `ThreadScreen.callPeer()`.
                state.flow = nil
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(320))
                    state.flow = .thread
                }
            } else {
                RHaptic.warn()
            }
        }
    }
}
