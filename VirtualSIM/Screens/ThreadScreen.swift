import SwiftUI

/// One conversation on the rented line — READ ONLY since 2026-08-18.
///
/// A cover rather than a navigation push, and that is forced by the layout:
/// `TabBar` is a ZStack overlay pinned to the bottom of `ContentView` on every
/// tab, so a push would leave the floating tab bar sitting on top of the
/// content.
///
/// 🔴 **THE COMPOSER IS GONE, along with its allowance counter and its
/// past-due "renew to send again" prompt** (owner decision: outbound SMS is
/// dropped, not delayed — it is the only capability needing carrier approval
/// and lifetime outbound is 1 sent against 6 failed). A text field that
/// accepts input and then fails at the carrier is worse than no text field:
/// the user types, waits, and gets a red "Not sent" they cannot act on.
///
/// This screen now does what the product does — it shows what arrived, and
/// offers one tap to copy a verification code out of it.
struct ThreadScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    @Environment(CallController.self) private var calls

    @State private var showActions = false
    @State private var reported = false
    @State private var showNameSheet = false

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
                readOnlyNote
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

    // MARK: - Read-only note

    /// One quiet line where the composer used to be.
    ///
    /// Deleting the composer removed the failure, but it also removed the
    /// EXPLANATION: a user who opens a conversation and finds no text field
    /// hunts for it, decides the app is broken or the thread is somehow
    /// locked, and — measured — cancels. Saying it outright costs one line and
    /// turns a missing control into a stated limitation, which is the same
    /// choice the store pitch and the checkout ledger already make ("Sending
    /// texts — Not yet").
    ///
    /// Muted `text3` on the page background, NOT a banner: this is a permanent
    /// fact about the product, and a permanent tinted banner is chrome the eye
    /// stops seeing while training the user to ignore the real ones
    /// (`LineStatusBanner` sits in that role and only appears when something
    /// is actually wrong).
    ///
    /// ⚠️ "yet" is the owner's framing on every other surface and is kept for
    /// consistency — but do not turn it into a date or a promise. Outbound SMS
    /// is DROPPED, not scheduled: it needs 10DLC registration nobody is
    /// pursuing.
    private var readOnlyNote: some View {
        Text("This number receives texts. Replying isn't available yet.")
            .font(RFont.text(12))
            .foregroundStyle(theme.text3)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 18)
    }

    // The composer — text field, send button, `blockReason`, the "N texts left
    // this month" counter and `send()` — was DELETED on 2026-08-18. Its
    // `blockReason` ladder is worth remembering rather than resurrecting: it
    // distinguished "you have used your texts" from "your payment failed",
    // which was the right distinction while sending existed. It does not
    // exist now, and a disabled composer with an explanation would still be a
    // text field on screen advertising a capability that is never coming.
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
