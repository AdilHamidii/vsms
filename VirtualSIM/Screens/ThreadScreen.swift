import SwiftUI

/// One conversation on the rented line.
///
/// A cover rather than a navigation push, and that is forced by the layout:
/// `TabBar` is a ZStack overlay pinned to the bottom of `ContentView` on every
/// tab, so a push would leave the floating tab bar sitting on top of the
/// composer.
struct ThreadScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api

    @State private var draft = ""
    @State private var isSending = false
    @State private var showActions = false
    @State private var reported = false
    @FocusState private var composerFocused: Bool

    private var thread: LineThread? {
        state.lineThreads.first { $0.id == state.openThreadId }
    }
    private var messages: [LineMessage] {
        state.openThreadId.flatMap { state.lineMessages[$0] } ?? []
    }

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

            VStack(alignment: .leading, spacing: 1) {
                Text(PhoneFormat.national(thread?.peerE164 ?? ""))
                    .font(RFont.display(17, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(theme.text)
                if thread?.blocked == true {
                    Text("Blocked")
                        .font(RFont.text(11, weight: .medium))
                        .foregroundStyle(theme.fail)
                } else if reported {
                    Text("Reported. Thanks, we'll take a look")
                        .font(RFont.text(11))
                        .foregroundStyle(theme.text3)
                }
            }
            Spacer(minLength: 0)

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

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(messages) { m in
                        MessageBubble(message: m).id(m.id)
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
    /// Two different blocks that must not be collapsed: "you have used your
    /// texts" and "your payment failed" send the user to two different places,
    /// and telling a past-due user to wait for a reset that is not coming is
    /// the worse of the two mistakes.
    private var composer: some View {
        VStack(spacing: 6) {
            // Below `blockReason` in precedence: a suspended line is the more
            // actionable problem, and stacking two warnings answers neither.
            if let unreachable, blockReason == nil {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 11, weight: .semibold))
                    Text(verbatim: SmsReach.explanation(unreachable))
                        .font(RFont.text(12))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(theme.warn)
                .padding(.horizontal, 4)
            }

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
                    .disabled(blockReason != nil || unreachable != nil)

                Button(action: send) {
                    Image(systemName: RIcon.send)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(canSend ? theme.onInk : theme.text3)
                        .frame(width: 38, height: 38)
                        .background(canSend ? theme.ink : theme.chipBg, in: .circle)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }

            if blockReason == nil, unreachable == nil, let left = state.line?.smsRemaining {
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
        !isSending && blockReason == nil && unreachable == nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The carrier will refuse this thread's peer. Common rather than exotic:
    /// inbound works from anywhere and outbound does not, so a conversation we
    /// cannot reply to is a state the product produces on its own.
    private var unreachable: SmsReach.Refusal? {
        guard let peer = thread?.peerE164 else { return nil }
        return SmsReach.refusal(from: state.line?.countryCode, to: peer)
    }

    private var blockReason: LocalizedStringKey? {
        if thread?.blocked == true { return "You've blocked this number. Unblock it to send." }
        // The four sentences live on `Line.SendBlock` so the compose screen
        // says the same thing — it used to check only the allowance and let a
        // suspended line through to a raw server refusal.
        guard let line = state.line else { return Line.SendBlock.notLive.message }
        return line.sendBlock?.message
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
            }
            if !message.isOutbound { Spacer(minLength: 50) }
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
