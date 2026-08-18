import SwiftUI

/// Start a conversation with someone who has never texted us.
///
/// ── Why this screen has to exist ──────────────────────────────────────────
///
/// `line_threads` rows are created by an inbound message or by an outbound
/// send, and every path to `ThreadScreen` went through a thread that already
/// existed. So the Messages segment could only ever REPLY — a rented number
/// you cannot text FROM is half a product, and the asymmetry was visible on
/// the screen itself: Calls has carried a "Make a call" button since the
/// dialer landed, Messages offered only "Share my number".
///
/// It sends through `AppState.sendLineMessage`, which already handles the
/// brand-new-conversation case (it falls back to the visible line when there
/// is no thread to take the line from) and already re-reads the thread list,
/// the messages and the allowance afterwards. Nothing here duplicates that.
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

    /// nil until the recipient could actually be dialled. This is what the
    /// send uses — never the raw field — because the server passes `to`
    /// straight to Telnyx.
    private var recipient: String? {
        isEmergency ? nil : PhoneFormat.e164(to)
    }

    private var remaining: Int? { state.line?.smsRemaining }

    /// 🔴 THIS SCREEN USED TO CHECK ONLY THE ALLOWANCE, and `ThreadScreen` —
    /// the other place a message can be sent — checked all four states through
    /// `Line.sendBlock`. So a past-due, suspended or not-yet-live line was
    /// blocked when REPLYING and allowed when STARTING a conversation, where
    /// the user typed a message, pressed send and got a raw server refusal
    /// instead of the sentence explaining what to do about it.
    ///
    /// The old default was wrong in the same direction: `(remaining ?? 1) <= 0`
    /// reported "not exhausted" when no line was loaded at all, where
    /// `sendBlock` correctly says `.notLive`.
    private var block: Line.SendBlock? { state.line?.sendBlock ?? .notLive }

    /// The carrier will not deliver this one, so say so before the user writes
    /// anything rather than spending a round trip to be refused.
    /// `send-line-message` enforces it either way; this is only the hint.
    private var unreachable: SmsReach.Refusal? {
        guard let recipient else { return nil }
        return SmsReach.refusal(from: state.line?.countryCode, to: recipient)
    }

    private var canSend: Bool {
        recipient != nil && unreachable == nil && block == nil
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !sending
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
                        // Ahead of the general notes: an undeliverable
                        // recipient makes "N texts left this month" beside the
                        // point.
                        if let unreachable {
                            Text(verbatim: SmsReach.explanation(unreachable))
                                .font(RFont.text(12))
                                .foregroundStyle(theme.warn)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 4)
                        } else if let note {
                            notice(note)
                        }
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
            .accessibilityLabel("Close")

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
                .font(RFont.text(16))
                .foregroundStyle(theme.text)
                .lineLimit(3...8)
                .focused($focus, equals: .body)
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
        }
    }

    /// One line, and only when there is something true to say. An always-on
    /// hint under a text field is noise; these are all states that change what
    /// the button will do.
    private var note: LocalizedStringKey? {
        if isEmergency { return "This number can't text emergency services. Use your phone's own number." }
        if let block { return block.message }
        if !to.isEmpty && recipient == nil { return "That doesn't look like a phone number yet." }
        if let remaining, remaining <= 10 { return "\(remaining) texts left this month." }
        return nil
    }

    private func notice(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(RFont.text(12))
            .foregroundStyle(isEmergency || block != nil ? theme.warn : theme.text2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    // MARK: - Send

    private func send() {
        guard let recipient else { return }
        Task {
            sending = true
            defer { sending = false }
            let ok = await state.sendLineMessage(
                using: LineAPI(client: api), to: recipient, text: text)
            if ok {
                RHaptic.success()
                // `sendLineMessage` set `openThreadId` from the server's
                // response, so the conversation the user just started is what
                // opens — not the list they came from.
                state.flow = .thread
            } else {
                RHaptic.warn()
            }
        }
    }
}
