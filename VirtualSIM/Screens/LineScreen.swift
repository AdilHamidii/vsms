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

    let line: Line

    private enum Seg: Hashable { case messages, calls, number }
    @State private var seg: Seg = .messages
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            LineStatusBanner(line: line)
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
        }
    }

    private var unreadCount: Int {
        state.lineThreads.reduce(0) { $0 + $1.unreadCount }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your number")
                    .font(RFont.text(13)).foregroundStyle(theme.text2)
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
        if state.lineThreads.isEmpty {
            VStack(spacing: 14) {
                EmptyState(
                    icon: RIcon.message,
                    title: "Your number is ready",
                    message: "Texts sent to it land here. Share it with someone to get started."
                )
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
                    ForEach(state.lineThreads) { thread in
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

    // MARK: - Calls

    @ViewBuilder
    private var calls: some View {
        if state.lineCalls.isEmpty {
            // ⚠️ Must not imply calling works. There is no dialer — `flow =
            // .dialer` is assigned nowhere — so "calls appear here" reads as a
            // feature that is merely unused rather than one that does not
            // exist. Same rule as the paywall: sell what ships.
            EmptyState(
                icon: RIcon.phone,
                title: "Calling is coming",
                message: "Your number can't make or take calls yet. Texting works now, and calls arrive in a future update.",
                tint: theme.text3
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(state.lineCalls) { call in
                        CallRow(call: call)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 120)
            }
        }
    }

    private func emptyState(icon: String, title: LocalizedStringKey,
                            body: LocalizedStringKey) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 30)).foregroundStyle(theme.text3)
            Text(title)
                .font(RFont.display(16, weight: .semibold))
                .foregroundStyle(theme.text)
            Text(body)
                .font(RFont.text(13))
                .foregroundStyle(theme.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 44)
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
    }
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
                        // "Minutes left · 100 of 100" removed for the same
                        // reason as the gauge in `AllowanceStrip`: there is no
                        // dialer, so a plan row stating an unspendable balance
                        // is a promise. It was worse here than anywhere else —
                        // a subscriber tapping Calls saw this row directly
                        // above "Calling is coming — your number can't make or
                        // take calls yet." Restore with the dialer.
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
                 // "and calls" removed — there is no dialer, so this told a
                 // lapsed subscriber they still had a capability that has never
                 // existed. The receive/send split is real and is the point of
                 // the banner: inbound stays on because the user cannot control
                 // who texts them.
                 text: "Your subscription lapsed. You can still receive texts, but you can't send until you renew.")
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
