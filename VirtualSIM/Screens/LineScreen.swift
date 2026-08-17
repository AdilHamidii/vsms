import StoreKit
import SwiftUI

/// The Number tab. Routes between the store and a live line.
///
/// Three states, and each one SAYS which it is. A blank screen is what a failed
/// fetch looks like too, and blankness reads as "this app is broken" rather
/// than "there is nothing here" — the rule `EsimStoreScreen` was rebuilt around
/// after build 18 shipped a near-empty eSIM tab during the pause.
struct LineScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api

    var onOpenSms: () -> Void

    var body: some View {
        Group {
            if let line = state.line, line.status.isLive {
                LiveLineView(line: line)
            } else {
                // A RELEASED line falls here on purpose: the number is gone and
                // cannot come back, so the honest next step is the store. Its
                // history is still readable from the Number segment once a new
                // line exists.
                LineStoreScreen(onOpenSms: onOpenSms)
            }
        }
        .task {
            // Cheap (one row, RLS-scoped) and it must run on every visit: the
            // subscription can change state — renew, lapse, be refunded —
            // entirely outside the app.
            await state.loadLine(using: LineAPI(client: api))
        }
    }
}

/// A line that exists. Header, status, allowance, then the three segments.
private struct LiveLineView: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    @Environment(CallController.self) private var calling

    let line: Line

    private enum Seg: Hashable { case messages, calls, number }
    @State private var seg: Seg = .messages
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            LineStatusBanner(line: line)
                .padding(.horizontal, 20)
            VoiceReadinessNotice(readiness: calling.readiness)
                .padding(.horizontal, 20)

            if line.status.isSettingUp {
                provisioning
            } else {
                SegmentedTabs(selection: $seg, items: [
                    (.messages, String(localized: "Messages"),
                     unreadCount == 0 ? nil : unreadCount),
                    (.calls, String(localized: "Calls"), nil),
                    (.number, String(localized: "Number"), nil),
                ])
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)

                AllowanceStrip(line: line)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)

                // No blanket `.animation` here — `SegmentedTabs` already wraps
                // its selection change in `withAnimation`, which these
                // transitions pick up.
                ZStack {
                    switch seg {
                    case .messages: messages.transition(.opacity)
                    case .calls:    calls.transition(.opacity)
                    case .number:   NumberDetailView(line: line).transition(.opacity)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .background(theme.bg)
        .task {
            async let t: () = state.loadLineThreads(using: LineAPI(client: api))
            async let c: () = state.loadLineCalls(using: LineAPI(client: api))
            _ = await (t, c)

            // 🔴 INBOUND CALLING IS DEAD WITHOUT THIS. `registerForVoIPPushes()`
            // had no caller anywhere in the app (2026-08-07 audit), so
            // PKPushRegistry was never created, `pushRegistry(_:didUpdate:)`
            // never fired, no VoIP token was ever uploaded, and Telnyx had
            // nothing to push to. A real caller dialling the rented number
            // produced no ring and no error — indistinguishable from a dead
            // number. Third time this repo has shipped a reachable-looking
            // feature whose entry point had no caller; grep for one.
            //
            // Registered HERE rather than in the dialer because inbound has to
            // work for a user who never opens the dialer, and this body only
            // renders once a live line exists — which is the condition
            // `registerForVoIPPushes()`'s own doc comment asks for.
            calling.registerForVoIPPushes()
            await calling.prepareVoice()
        }
        // The allowance is spent by a call that happens OUTSIDE this view:
        // CallKit is a system overlay, not a navigation change, so `.task` does
        // not re-run when the call ends and the meter kept reading whatever it
        // read before — a user could talk for ten minutes and still see the
        // full 100 remaining until the next cold launch. The meter is the thing
        // they check to decide whether the plan is worth keeping.
        //
        // Keyed on the RETURN to `.idle` rather than on any particular end
        // path, because there are four of them (in-call button, remote hangup,
        // CallKit's own end action, and a failure) and one of them would
        // eventually be missed.
        .onChange(of: calling.phase) { _, phase in
            guard phase == .idle else { return }
            Task {
                // `report-line-call` settles the claim server-side; give it a
                // moment to land, otherwise this reads the pre-settlement row
                // and looks exactly like the bug it fixes.
                try? await Task.sleep(for: .seconds(2))
                await state.loadLine(using: LineAPI(client: api))
                await state.loadLineCalls(using: LineAPI(client: api))
            }
        }
        // Tell the call controller which number it is acting as. Without this
        // the dialer mints a credential for, and calls out from, whichever line
        // the server picks rather than the one on screen.
        .onAppear { calling.activeLineId = line.id }
        .onChange(of: line.id) { _, id in calling.activeLineId = id }
    }

    private var unreadCount: Int {
        state.threadsForSelectedLine.reduce(0) { $0 + $1.unreadCount }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                // The switcher REPLACES the static label when there is more
                // than one number, rather than sitting beside it. With a single
                // line this is byte-identical to what shipped — multi-number
                // must not make the common case busier.
                if state.hasMultipleLines {
                    lineSwitcher
                } else {
                    Text("Your number")
                        .font(RFont.text(13)).foregroundStyle(theme.text2)
                }
                Button {
                    UIPasteboard.general.string = line.e164
                    withAnimation(RMotion.select) { copied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        withAnimation(RMotion.select) { copied = false }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(PhoneFormat.national(line.e164))
                            .font(RFont.display(25, weight: .bold))
                            .tracking(-0.6)
                            .foregroundStyle(theme.text)
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                        Image(systemName: copied ? RIcon.check : RIcon.copy)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(copied ? theme.live : theme.text3)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    /// Pick which of your numbers the tab is showing.
    ///
    /// A Menu rather than a segmented control: the cap is 5 and the labels are
    /// full phone numbers, which will not fit across the width of an iPhone SE.
    /// Each row carries its own unread count, because the whole point of the
    /// switcher is noticing that the OTHER number has a message waiting.
    private var lineSwitcher: some View {
        Menu {
            ForEach(state.lines.filter { $0.status.isLive }) { l in
                Button {
                    RHaptic.select()
                    withAnimation(RMotion.select) { state.selectedLineId = l.id }
                } label: {
                    let unread = state.lineThreads
                        .filter { $0.lineId == l.id }
                        .reduce(0) { $0 + $1.unreadCount }
                    Label(
                        unread > 0
                            ? "\(PhoneFormat.national(l.e164))  (\(unread))"
                            : PhoneFormat.national(l.e164),
                        systemImage: l.id == line.id ? RIcon.check : "")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("Your number")
                    .font(RFont.text(13)).foregroundStyle(theme.text2)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.text3)
                // Unread on the numbers you are NOT looking at. Without this the
                // switcher is invisible when it matters most — a message
                // arriving on the other number looks like nothing happened.
                let elsewhere = state.lineThreads
                    .filter { $0.lineId != line.id }
                    .reduce(0) { $0 + $1.unreadCount }
                if elsewhere > 0 {
                    Text(verbatim: "\(elsewhere)")
                        .font(RFont.text(10, weight: .heavy))
                        .foregroundStyle(theme.onInk)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(theme.ink, in: .capsule)
                }
            }
            .frame(minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Provisioning

    /// The number exists at Telnyx but is not usable yet. Number orders are
    /// asynchronous (`pending` → `success`), so this is a real state rather
    /// than a spinner standing in for one.
    private var provisioning: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Setting up your number")
                .font(RFont.display(16, weight: .semibold))
                .foregroundStyle(theme.text)
            Text("This usually takes a few seconds. You can leave this screen, and we'll let you know when it's ready.")
                .font(RFont.text(13))
                .foregroundStyle(theme.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Messages

    /// The empty inbox is what a user who just paid $9.99 actually looks at for
    /// their first hour, so it is the screen that most deserves designing — and
    /// it was one grey glyph and "Give it out and see", which tells them
    /// nothing to DO. Sharing the number is the actual next step, so the empty
    /// state offers it rather than describing it.
    @ViewBuilder
    private var messages: some View {
        if state.threadsForSelectedLine.isEmpty {
            VStack(spacing: 14) {
                EmptyState(
                    icon: RIcon.message,
                    title: "Your number is ready",
                    message: "Texts sent to it land here. Share it with someone to get started."
                )
                composeButton
                ShareLink(item: PhoneFormat.national(line.e164)) {
                    Text("Share my number")
                        .font(RFont.text(15, weight: .medium))
                        .foregroundStyle(theme.text)
                        .frame(height: 48)
                        .padding(.horizontal, 22)
                        .background(theme.chipBg, in: Capsule())
                }
                .simultaneousGesture(TapGesture().onEnded { RHaptic.select() })
            }
            .padding(.top, 20)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    composeButton.padding(.bottom, 6)
                    ForEach(state.threadsForSelectedLine) { thread in
                        ThreadRow(thread: thread) {
                            state.openThreadId = thread.id
                            state.flow = .thread
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 120)
            }
        }
    }

    /// The one entry point to a NEW conversation, in both states — mirroring
    /// `dialButton`.
    ///
    /// Present in the empty state too, because that is where it is needed
    /// most: "Share my number" was the only affordance there, so a user whose
    /// number had never been texted could do nothing with it but wait. Unlike
    /// the dialer this has no capability gate — outbound SMS needs no client
    /// SDK, only the allowance, which the compose screen states rather than
    /// hiding behind a disabled button.
    private var composeButton: some View {
        Button {
            RHaptic.select()
            state.flow = .compose
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .semibold))
                Text("New message")
                    .font(RFont.text(15, weight: .medium))
            }
            .foregroundStyle(theme.text)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(theme.chipBg, in: Capsule())
        }
        .buttonStyle(PressScaleStyle())
    }

    // MARK: - Calls

    /// ⚠️ This segment said *"Calling is coming — your number can't make or
    /// take calls yet"* for as long as `flow = .dialer` was assigned nowhere.
    /// The rule that produced that copy still stands and is worth keeping in
    /// view: **sell what ships.** It is only correct to offer the keypad here
    /// because the SDK is now linked and `isVoiceAvailable` gates the flow.
    @ViewBuilder
    private var calls: some View {
        if state.callsForSelectedLine.isEmpty {
            VStack(spacing: 14) {
                EmptyState(
                    icon: RIcon.phone,
                    title: "No calls yet",
                    message: "Calls you make and receive on this number appear here."
                )
                dialButton
            }
            .padding(.top, 20)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    dialButton.padding(.bottom, 6)
                    ForEach(state.callsForSelectedLine) { call in
                        CallRow(call: call)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 120)
            }
        }
    }

    /// The one entry point to the dialer.
    ///
    /// Hidden — not disabled — when no voice client is attached. A disabled
    /// button still advertises the feature, and on a build without the SDK
    /// that is a promise the app cannot keep.
    @ViewBuilder
    private var dialButton: some View {
        if calling.isVoiceAvailable {
            Button {
                RHaptic.select()
                state.flow = .dialer
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: RIcon.phone)
                        .font(.system(size: 14, weight: .semibold))
                    Text("Make a call")
                        .font(RFont.text(15, weight: .medium))
                }
                .foregroundStyle(theme.text)
                .frame(height: 48)
                .padding(.horizontal, 22)
                .background(theme.chipBg, in: Capsule())
            }
            .buttonStyle(PressScaleStyle())
        }
    }

    // A private `emptyState(icon:title:body:)` lived here and was never called
    // — this screen already uses the shared `EmptyState` component, twice. Two
    // empty-state treatments in one file is how they drift apart, and the dead
    // one had already picked up different metrics from the live one.
}

// MARK: - Number detail

/// Plan, renewal, and the two things App Review will look for: a route to
/// Apple's own subscription management, and the emergency-calling disclosure.
private struct NumberDetailView: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(SubscriptionStore.self) private var subs
    let line: Line

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // The ONLY route to a second number. The tab shows the store
                // only when there is no line at all, so without this the
                // multi-number product cannot be reached by a user who already
                // has one — which is everyone who would want another.
                Button {
                    RHaptic.select()
                    state.flow = .lineStoreMore
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Rent another number")
                            .font(RFont.text(15, weight: .medium))
                    }
                    .foregroundStyle(theme.ink)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(theme.inkSoft.opacity(0.5), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 18)

                SectionHeader(label: String(localized: "Your plan"))
                    // An existing subscriber never passes through the store or
                    // the paywall, so nothing else would have loaded the
                    // product and the price would read as its fallback forever.
                    .task { await subs.loadProduct() }
                Card {
                    VStack(spacing: 0) {
                        row(label: "Number", value: PhoneFormat.national(line.e164))
                        divider
                        // ⚠️ NEVER a literal. This read "$9.99 / month" while
                        // the paywall's own button read StoreKit's localized
                        // price — so a euro subscriber saw "9,99 €/mo" to buy
                        // and "$9.99 / month" on the plan screen for the same
                        // subscription. Exactly the drift that put $4.99
                        // against €5.99 on the credit ladder's top product.
                        row(label: "Price",
                            value: subs.displayPrice.map { "\($0) / month" }
                                ?? String(localized: "Monthly"))
                        divider
                        row(label: renewLabel, value: renewValue)
                        divider
                        row(label: "Texts left",
                            value: "\(line.smsRemaining) of \(line.smsAllowance)")
                        divider
                        // Restored with the dialer. It was removed while
                        // calling was unreachable, because a plan row stating
                        // an unspendable balance is a promise — a subscriber
                        // tapping Calls saw "100 of 100 minutes" directly above
                        // "your number can't make or take calls yet".
                        row(label: "Minutes left",
                            value: "\(line.voiceSecondsRemaining / 60) of \(line.voiceAllowanceSeconds / 60)")
                    }
                    .padding(.vertical, 4)
                }

                // Apple's own sheet, never a custom cancel flow — a bespoke one
                // cannot actually cancel anything and reads as a dark pattern.
                GhostButton(label: "Manage subscription", icon: RIcon.gear) {
                    Task { await openManage() }
                }
                .padding(.top, 16)

                SectionHeader(label: String(localized: "Important")).padding(.top, 24)
                Card {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.warn)
                            .padding(.top, 1)
                        Text("This number can't call 911 or any other emergency service. Always use your phone's own number for emergencies.")
                            .font(RFont.text(13))
                            .foregroundStyle(theme.text2)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 120)
        }
    }

    /// Naming the state rather than always saying "Renews" — a subscription the
    /// user has already cancelled does not renew, and telling them it does is
    /// the kind of thing that turns into a refund request.
    private var renewLabel: String {
        switch line.status {
        case .grace, .pastDue: String(localized: "Payment due")
        case .suspended:       String(localized: "Held until")
        default:               String(localized: "Renews")
        }
    }

    private var renewValue: String {
        let date = line.status == .suspended ? line.holdUntil : line.currentPeriodEnd
        guard let date else { return String(localized: "—") }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    private func row(label: String, value: String) -> some View {
        HStack {
            Text(LocalizedStringKey(label))
                .font(RFont.text(14)).foregroundStyle(theme.text2)
            Spacer()
            Text(value)
                .font(RFont.text(14, weight: .medium))
                .foregroundStyle(theme.text)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var divider: some View {
        Rectangle().fill(theme.sep).frame(height: 0.5).padding(.leading, 16)
    }

    @MainActor
    private func openManage() async {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        else { return }
        try? await AppStore.showManageSubscriptions(in: scene)
    }
}

// MARK: - Status banner

/// What is wrong, and what the user can do about it.
///
/// Nothing at all when the line is healthy — a permanent banner is one the user
/// stops reading, which is exactly the state you need it to be read in.
struct LineStatusBanner: View {
    @Environment(\.theme) private var theme
    let line: Line

    var body: some View {
        if let copy = message {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: copy.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(copy.tint)
                    .padding(.top, 2)
                Text(copy.text)
                    .font(RFont.text(12, weight: .medium))
                    .foregroundStyle(theme.text)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(copy.tint.opacity(0.12), in: .rect(cornerRadius: 14))
            .padding(.top, 10)
        }
    }

    private struct Copy { let icon: String; let tint: Color; let text: LocalizedStringKey }

    private var message: Copy? {
        switch line.status {
        case .grace:
            // Service stays FULLY live during Apple's billing grace period.
            // That is the whole reason grace is enabled, and cutting the user
            // off would defeat it.
            Copy(icon: "creditcard", tint: theme.warn,
                 text: "There's a problem with your payment. Update it to keep your number. Everything still works for now.")
        case .pastDue:
            Copy(icon: "exclamationmark.circle", tint: theme.fail,
                 // The receive/send split is the point of this banner: inbound
                 // stays on because the user cannot control who contacts them,
                 // while outbound is what lapsing withdraws.
                 text: "Your subscription lapsed. You can still receive texts and calls, but you can't send or dial out until you renew.")
        case .suspended:
            Copy(icon: "lock", tint: theme.fail,
                 text: "Your number is on hold. Resubscribe to get it back before it's released for good.")
        case .failed:
            Copy(icon: "exclamationmark.triangle", tint: theme.fail,
                 text: "We couldn't finish setting up your number. You haven't been charged for a number you don't have.")
        default:
            nil
        }
    }
}

// MARK: - Rows

struct ThreadRow: View {
    @Environment(\.theme) private var theme
    let thread: LineThread
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(PhoneFormat.national(thread.peerE164))
                        .font(RFont.text(15, weight: .semibold))
                        .foregroundStyle(theme.text)
                    Text(thread.lastPreview ?? "")
                        .font(RFont.text(13))
                        .foregroundStyle(theme.text2)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 5) {
                    if let at = thread.lastMessageAt {
                        Text(at.formatted(.relative(presentation: .numeric)))
                            .font(RFont.text(11))
                            .foregroundStyle(theme.text3)
                            .lineLimit(1)
                    }
                    if thread.unreadCount > 0 {
                        Circle().fill(theme.ink).frame(width: 8, height: 8)
                    }
                }
            }
            .padding(14)
            .background(theme.elev, in: .rect(cornerRadius: 16))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

struct CallRow: View {
    @Environment(\.theme) private var theme
    let call: LineCall

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(call.status.isMissed ? theme.fail : theme.text3)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(PhoneFormat.national(call.peerE164))
                    .font(RFont.text(15, weight: .semibold))
                    .foregroundStyle(call.status.isMissed ? theme.fail : theme.text)
                Text(subtitle)
                    .font(RFont.text(12))
                    .foregroundStyle(theme.text2)
            }
            Spacer(minLength: 8)
            Text(call.createdAt.formatted(.relative(presentation: .numeric)))
                .font(RFont.text(11))
                .foregroundStyle(theme.text3)
                .lineLimit(1)
        }
        .padding(14)
        .background(theme.elev, in: .rect(cornerRadius: 16))
    }

    private var icon: String {
        if call.status.isMissed { return "phone.down" }
        return call.direction == .inbound ? "phone.arrow.down.left" : "phone.arrow.up.right"
    }

    private var subtitle: String {
        if call.status.isMissed { return String(localized: "Missed") }
        // A completed call with no duration yet is waiting on the CDR, which
        // arrives minutes later. Saying "0:00" would claim a zero-length call.
        guard let s = call.displaySeconds, s > 0 else {
            return call.direction == .inbound
                ? String(localized: "Incoming") : String(localized: "Outgoing")
        }
        return PhoneFormat.duration(s)
    }
}

/// Says out loud which half of calling is working.
///
/// 🔴 THE SIGNAL EXISTED AND NOTHING RENDERED IT. `mint-line-token` has always
/// returned `inbound_ready`, `LineModels` decoded it, `CallController` stored
/// it — and no view read it, so a number that could not ring looked identical
/// to one that could. Every line sold before 2026-08-17 was in that state, and
/// the only reason we found out was one customer bothering to send an e-mail.
///
/// Two rules this deliberately follows:
///
/// - **Silent when everything works.** A banner that is always present is
///   chrome nobody reads; this renders nothing for `.ready` and `.unknown`.
///   `.unknown` in particular means "not attempted yet", which is not the same
///   as broken and must not be drawn as a fault.
/// - **It never blames the user's connection for a server problem.** The
///   `.unavailable` reason comes from `APIError.userMessage`, which maps the
///   business codes; the fallback says what we could not do, not what they
///   should go and check.
struct VoiceReadinessNotice: View {
    @Environment(\.theme) private var theme
    let readiness: CallController.Readiness

    var body: some View {
        switch readiness {
        case .ready, .unknown:
            EmptyView()
        case .outboundOnly:
            // The user may already have given this number out, so the useful
            // sentence is what to DO, not merely that something is wrong.
            notice(icon: "phone.badge.waveform", tint: theme.warn,
                   text: Text("You can make calls, but your number can't receive them yet. Reopen this tab in a moment — we're still setting it up."))
        case .unavailable(let reason):
            notice(icon: "phone.down", tint: theme.fail, text: Text(reason))
        }
    }

    private func notice(icon: String, tint: Color, text: Text) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 2)
            text
                .font(RFont.text(12, weight: .medium))
                .foregroundStyle(theme.text)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(tint.opacity(0.12), in: .rect(cornerRadius: 14))
        .padding(.top, 10)
    }
}
