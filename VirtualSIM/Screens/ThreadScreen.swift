import SwiftUI

/// One conversation on the rented line.
///
/// A cover rather than a navigation push, and that is forced by the layout:
/// `TabBar` is a ZStack overlay pinned to the bottom of `ContentView` on every
/// tab, so a push would leave the floating tab bar sitting on top of the
/// composer.
///
/// ── The composer's history, because it governs what this screen may say ───
///
/// It was DELETED on 2026-08-18 with the outbound-SMS retirement, on the
/// reasoning that "a text field that accepts input and then fails at the
/// carrier is worse than no text field: the user types, waits, and gets a red
/// 'Not sent' they cannot act on." Restored 2026-09-08 (owner decision) after
/// a US → CA send delivered.
///
/// ⚠️ **That objection was never answered, only outweighed — so the failure
/// path is the part that has to be right.** The one measured delivery was
/// on-net between two of our own numbers and no number we own carries a 10DLC
/// campaign, so a carrier rejection remains entirely possible and arrives
/// ASYNCHRONOUSLY, minutes later, as a delivery receipt. `MessageBubble`
/// therefore renders a per-message failure with the reason
/// (`LineMessage.failureReason`) rather than a bare red mark, and the 6-second
/// poll below is what makes that reason appear without the user leaving.
/// Nothing on this screen may promise that a sent message will arrive.
struct ThreadScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    @Environment(CallController.self) private var calls

    @State private var draft = ""
    @State private var isSending = false
    @State private var showActions = false
    @State private var reported = false
    @State private var showNameSheet = false
    @FocusState private var composerFocused: Bool

    private var thread: LineThread? {
        state.lineThreads.first { $0.id == state.openThreadId }
    }
    private var messages: [LineMessage] {
        state.openThreadId.flatMap { state.lineMessages[$0] } ?? []
    }
    private var peer: String { thread?.peerE164 ?? "" }
    private var peerName: String? { state.contactName(for: peer) }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().overlay(theme.sep)
                transcript
                composer
            }
        }
        .task {
            guard let id = state.openThreadId else { return }
            await state.loadLineMessages(using: LineAPI(client: api), threadId: id)
            await state.markThreadRead(using: LineAPI(client: api), threadId: id)
        }
        // Inbound arrives by push, but a thread left open while the other side
        // replies must fill in on its own. Polling rather than Realtime, which
        // is used nowhere in this codebase and would be a second large bet in
        // one release.
        .task(id: state.openThreadId) {
            guard let id = state.openThreadId else { return }
            while !Task.isCancelled, state.flow == .thread {
                try? await Task.sleep(for: .seconds(6))
                guard state.flow == .thread else { return }
                await state.loadLineMessages(using: LineAPI(client: api), threadId: id)
            }
        }
        .confirmationDialog("Options", isPresented: $showActions, titleVisibility: .hidden) {
            if let t = thread {
                Button(t.blocked ? "Unblock this number" : "Block this number",
                       role: t.blocked ? nil : .destructive) {
                    Task {
                        await state.setThreadBlocked(
                            using: LineAPI(client: api), threadId: t.id, blocked: !t.blocked)
                    }
                }
                // Reporting is recorded, never auto-blocking: one tap should
                // not silence a number the user may still want.
                Button("Report spam") {
                    Task {
                        await state.reportThread(using: LineAPI(client: api), threadId: t.id)
                        reported = true
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        }
        // Presented from HERE, not from `ContentView`: this screen is itself a
        // `fullScreenCover`, and a sheet raised from the root while a cover is
        // up does not appear at all. The environment objects are injected
        // explicitly for the same reason `EnvBundle` exists — sheet content
        // does not reliably inherit `@Observable` objects from its presenter.
        .sheet(isPresented: $showNameSheet) {
            PeerNameSheet(e164: peer)
                .environment(\.theme, theme)
                .environment(state)
                .presentationDetents([.height(360)])
                .presentationDragIndicator(.visible)
                .presentationBackground(theme.bg)
        }
    }

    /// Hand this conversation to the keypad, pre-filled.
    ///
    /// `flow` drives a `fullScreenCover(item:)`, and swapping one identity for
    /// another while the cover is up is not a transition SwiftUI performs
    /// reliably — the second stage can simply never appear. So the cover is
    /// dismissed first and the dialer raised on the next runloop, once the
    /// dismissal has actually committed. The prefill is set BEFORE either, so
    /// the dialer can never come up empty if the hop is coalesced.
    private func callPeer() {
        RHaptic.select()
        state.dialerPrefill = peer
        state.flow = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            state.flow = .dialer
        }
    }

    // MARK: - Header

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

            // The identity is one tap target — avatar and name together, the
            // way every phone app opens a contact from its thread header.
            Button { showNameSheet = true } label: {
                HStack(spacing: 10) {
                    PeerAvatar(e164: peer, name: peerName, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        // The nickname when there is one, the number when there
                        // is not — never a guessed name, and never both stacked,
                        // which is what makes a header feel cluttered.
                        Text(verbatim: peerName ?? PhoneFormat.national(peer))
                            .font(RFont.display(17, weight: .semibold))
                            .tracking(-0.3)
                            .foregroundStyle(theme.text)
                            .lineLimit(1)
                        if thread?.blocked == true {
                            Text("Blocked")
                                .font(RFont.text(11, weight: .medium))
                                .foregroundStyle(theme.fail)
                        } else if reported {
                            Text("Reported. Thanks, we'll take a look")
                                .font(RFont.text(11))
                                .foregroundStyle(theme.text3)
                                .lineLimit(1)
                        } else if peerName != nil {
                            Text(verbatim: PhoneFormat.national(peer))
                                .font(RFont.mono(11))
                                .foregroundStyle(theme.text3)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Name this number"))

            // Hidden, not disabled, when no voice client is attached — the same
            // gate and the same reasoning as the Number tab's dial button: a
            // greyed control still advertises a capability the build lacks.
            if calls.isVoiceAvailable {
                Button(action: callPeer) {
                    Image(systemName: RIcon.phone)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.text2)
                        .frame(width: 34, height: 34)
                        .background(theme.chipBg, in: .circle)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Call this number"))
            }

            Button { showActions = true } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.text2)
                    .frame(width: 34, height: 34)
                    .background(theme.chipBg, in: .circle)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Transcript

    /// One message plus, when it opens a new calendar day, the label for that
    /// day. Computed once per render of the list rather than per row: the
    /// alternative is asking each bubble what the previous one's date was,
    /// which turns a linear walk into a quadratic one.
    private struct DatedMessage: Identifiable {
        let id: String
        let message: LineMessage
        let daySeparator: String?
    }

    private var dated: [DatedMessage] {
        let cal = Calendar.current
        var previous: Date?
        return messages.map { m in
            let day = cal.startOfDay(for: m.timestamp)
            let label = (previous.map { cal.isDate($0, inSameDayAs: day) } ?? false)
                ? nil : Self.dayLabel(day, calendar: cal)
            previous = day
            return DatedMessage(id: m.id, message: m, daySeparator: label)
        }
    }

    /// "Today" / "Yesterday" carry more than a date does — a timestamp the
    /// reader has to decode is a timestamp they skip. Anything older gets a
    /// real date, because "3 days ago" is arithmetic the reader then has to do.
    private static func dayLabel(_ day: Date, calendar cal: Calendar) -> String {
        if cal.isDateInToday(day) { return String(localized: "Today") }
        if cal.isDateInYesterday(day) { return String(localized: "Yesterday") }
        // Drop the year within the current one; a bare "12 March" reads faster.
        let sameYear = cal.component(.year, from: day) == cal.component(.year, from: Date())
        return day.formatted(sameYear
            ? .dateTime.weekday(.abbreviated).day().month(.abbreviated)
            : .dateTime.day().month(.abbreviated).year())
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(dated) { row in
                        if let day = row.daySeparator {
                            DaySeparator(label: day)
                        }
                        MessageBubble(message: row.message).id(row.id)
                    }
                    // Anchor for the scroll-to-bottom, so a new message does
                    // not require the user to chase it.
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation(RMotion.content) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    // MARK: - Composer

    /// Disabled WITH ITS REASON showing, never failing on send.
    ///
    /// The `blockReason` ladder is the load-bearing part and the reason this
    /// was rebuilt from the deleted original rather than reinvented: "you have
    /// used your texts" and "your payment failed" send the user to two
    /// different places, and telling a past-due user to wait for a reset that
    /// is not coming is the worse of the two mistakes.
    ///
    /// The peer-outside-NANP case is new (2026-09-08). `send-line-message`
    /// refuses a non-+1 recipient with `international_sms` because the
    /// number's own `international_outbound` is false — so a thread opened by
    /// an inbound message from abroad gets a stated reason instead of a text
    /// field that spends a round trip to say no.
    private var composer: some View {
        VStack(spacing: 6) {
            if let reason = blockReason {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 11, weight: .semibold))
                    Text(reason)
                        .font(RFont.text(12))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(theme.warn)
                .padding(.horizontal, 4)
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message", text: $draft, axis: .vertical)
                    .font(RFont.text(15))
                    .foregroundStyle(theme.text)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(theme.elev, in: .rect(cornerRadius: 18))
                    .disabled(blockReason != nil)

                Button(action: send) {
                    Image(systemName: RIcon.send)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(canSend ? theme.onInk : theme.text3)
                        .frame(width: 38, height: 38)
                        .background(canSend ? theme.ink : theme.chipBg, in: .circle)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel(Text("Send"))
            }

            if blockReason == nil, let left = state.line?.smsRemaining {
                Text("\(left) texts left this month")
                    .font(RFont.text(11))
                    .foregroundStyle(theme.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(theme.bg)
    }

    private var canSend: Bool {
        !isSending && blockReason == nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A peer this number cannot address at all. Not a fault and not a
    /// temporary state — the capability reads false at the carrier — so it
    /// belongs in the same ladder as the allowance and the lapse.
    private var peerOutsideNanp: Bool {
        guard !peer.isEmpty else { return false }
        return !(peer.hasPrefix("+1") && peer.filter(\.isNumber).count == 11)
    }

    private var blockReason: LocalizedStringKey? {
        if thread?.blocked == true { return "You've blocked this number. Unblock it to send." }
        if peerOutsideNanp { return "This number can only text US and Canadian numbers." }
        guard let line = state.line else { return "Your number isn't ready yet." }
        switch line.sendBlock {
        case .allowanceExhausted:
            return "You've used this month's texts. They reset when your subscription renews."
        case .pastDue:
            return "Renew your subscription to send messages again."
        case .suspended:
            return "Your number is on hold. Resubscribe to use it again."
        case .notLive:
            return "Your number isn't ready yet."
        case nil:
            return nil
        }
    }

    private func send() {
        guard let peer = thread?.peerE164 else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task {
            isSending = true
            defer { isSending = false }
            let ok = await state.sendLineMessage(using: LineAPI(client: api), to: peer, text: text)
            // Cleared only on success, so a refused send does not lose what the
            // user typed — retyping a message the app threw away is a worse
            // failure than the send itself.
            if ok { draft = "" }
        }
    }
}

/// The centred date chip between two calendar days.
///
/// A chip rather than a rule with text through it: the transcript already has
/// bubbles on both edges, and a full-width line adds a third horizontal
/// structure competing with them. Muted `chipBg`, so it reads as an index mark
/// rather than as a message anyone sent.
private struct DaySeparator: View {
    @Environment(\.theme) private var theme
    let label: String

    var body: some View {
        Text(verbatim: label)
            .font(RFont.text(11, weight: .semibold))
            .foregroundStyle(theme.text3)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(theme.chipBg, in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            .padding(.bottom, 6)
    }
}

/// One message. Inbound sits left on `elev`; outbound sits right on `ink`, the
/// standard "this one is from you" grammar.
struct MessageBubble: View {
    @Environment(\.theme) private var theme
    let message: LineMessage
    @State private var copiedCode = false

    var body: some View {
        HStack {
            if message.isOutbound { Spacer(minLength: 50) }
            VStack(alignment: message.isOutbound ? .trailing : .leading, spacing: 3) {
                Text(message.body ?? "")
                    .font(RFont.text(15))
                    .foregroundStyle(message.isOutbound ? theme.onInk : theme.text)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(
                        message.isOutbound ? theme.ink : theme.elev,
                        in: .rect(cornerRadius: 17))
                    .fixedSize(horizontal: false, vertical: true)

                // Receiving a verification code is most of why this line
                // exists, and until now the code was raw text to select by
                // hand — while both other product lines extract it and offer
                // one tap. Inbound only: a code we SENT is not a code to copy.
                if !message.isOutbound,
                   let code = VerificationCode.detect(in: message.body) {
                    Button {
                        UIPasteboard.general.string = code
                        withAnimation(RMotion.select) { copiedCode = true }
                        RHaptic.select()
                        Task {
                            try? await Task.sleep(for: .seconds(1.6))
                            withAnimation(RMotion.select) { copiedCode = false }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: copiedCode ? RIcon.check : "doc.on.doc")
                                .font(.system(size: 10, weight: .semibold))
                            Text(copiedCode ? "Copied" : "Copy \(code)")
                                .font(RFont.text(11, weight: .semibold))
                        }
                        .foregroundStyle(copiedCode ? theme.live : theme.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            (copiedCode ? theme.live : theme.ink).opacity(0.12),
                            in: .rect(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 4)
                }

                HStack(spacing: 4) {
                    Text(message.timestamp, format: .dateTime.hour().minute())
                        .font(RFont.text(10))
                        .foregroundStyle(theme.text3)
                    if message.isOutbound { statusMark }
                }
                .padding(.horizontal, 4)

                // 🔴 A SEND CAN FAIL MINUTES AFTER IT LOOKED SENT. The
                // delivery receipt is asynchronous, so this is the only place
                // the real outcome is ever stated — and "Not sent" alone
                // leaves the user retrying a message that will fail
                // identically every time. The reason comes from
                // `LineMessage.failureReason`, which is deliberately vague
                // where the provider's data is vague.
                if let reason = failureCopy {
                    Text(reason)
                        .font(RFont.text(10))
                        .foregroundStyle(theme.fail)
                        .multilineTextAlignment(message.isOutbound ? .trailing : .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
            }
            if !message.isOutbound { Spacer(minLength: 50) }
        }
    }

    /// Plain English for a carrier's diagnostic, or nil when the message did
    /// not fail.
    ///
    /// ⚠️ It never names 10DLC, the campaign, or the provider. The user has no
    /// part in a carrier registration programme and cannot act on its
    /// vocabulary; what they CAN act on is "this network refused it, the same
    /// message to a different number may go through". `unknown` deliberately
    /// says less rather than guessing between a spam filter, a wrong number
    /// and a block — Telnyx sends the same coarse status for all three.
    private var failureCopy: LocalizedStringKey? {
        switch message.failureReason {
        case .carrierBlocked:
            return "The recipient's network refused this message."
        case .badNumber:
            return "That number couldn't be reached."
        case .unknown:
            return "This message wasn't delivered."
        case nil:
            return nil
        }
    }

    /// Says what the server actually knows, and nothing more. A message sitting
    /// at `sent` has NOT been confirmed delivered — the carrier receipt arrives
    /// separately — so it must not wear a delivered mark.
    @ViewBuilder
    private var statusMark: some View {
        switch message.status {
        case .queued, .sending:
            Image(systemName: "clock")
                .font(.system(size: 9))
                .foregroundStyle(theme.text3)
        case .sent:
            Image(systemName: RIcon.check)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(theme.text3)
        case .delivered:
            HStack(spacing: -3) {
                Image(systemName: RIcon.check)
                Image(systemName: RIcon.check)
            }
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(theme.live)
        case .failed:
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Not sent")
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(theme.fail)
        default:
            EmptyView()
        }
    }
}
