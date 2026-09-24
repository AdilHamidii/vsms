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
    @Environment(SubscriptionStore.self) private var subs

    var onOpenSms: () -> Void

    var body: some View {
        @Bindable var state = state
        NavigationStack(path: $state.linePath) {
            root
                .containerBackground(theme.bg, for: .navigation)
                .toolbar(.hidden, for: .navigationBar)
                .lineRouteDestinations()
        }
        .task {
            // Cheap (one row, RLS-scoped) and it must run on every visit: the
            // subscription can change state — renew, lapse, be refunded —
            // entirely outside the app.
            await state.loadLine(using: LineAPI(client: api))
        }
        // One store VISIT per appearance of this stack with the store as its
        // root (a tab visit, or the root turning into the store). Hosted HERE,
        // not in `LineStoreScreen`, because the stack stays on screen while a
        // place page is pushed: a push and its pop are not a visit, and a push
        // cannot cancel the first search. See `LineStoreSearch.beginVisit`.
        .task(id: showsStore) {
            guard showsStore else { return }
            LineStoreSearch.beginVisit(state, api: api, subs: subs)
        }
        // A purchase (store → live line) or a lapse (live line → store)
        // replaces the stack's ROOT; a page pushed over the old root means
        // nothing over the new one.
        .onChange(of: state.line?.status.isLive ?? false) { _, _ in
            state.linePath = []
        }
    }

    /// The root is the store: the first line read has answered and there is
    /// no live line. Mirrors `root`'s branches.
    private var showsStore: Bool {
        state.linesLoaded && !(state.line?.status.isLive ?? false)
    }

    @ViewBuilder
    private var root: some View {
        if let line = state.line, line.status.isLive {
            LiveLineView(line: line)
                // The back-button label on pushed pages; the bar itself is hidden here.
                .navigationTitle(Text("My number"))
        } else if !state.linesLoaded {
            // Not asked yet. Rendering the store here is the one-frame
            // flash a subscriber saw before their number appeared: an
            // empty `lines` is not "no line" until the first read has
            // answered. `coldStart` answers it before the reveal, so this
            // branch is normally never on screen; it exists so the store
            // can only ever mean "we asked, and there is none".
            theme.bg.ignoresSafeArea()
        } else {
            // A RELEASED line falls here on purpose: the number is gone and
            // cannot come back, so the honest next step is the store. Its
            // history is still readable once a new line exists.
            LineStoreScreen(onOpenSms: onOpenSms,
                            push: { state.linePath.append($0) })
                .navigationTitle(Text("Your own number"))
        }
    }
}

extension View {
    /// Registers every `LineRoute` destination on the enclosing
    /// `NavigationStack` — the tab's and `LineStoreCover`'s.
    func lineRouteDestinations() -> some View {
        navigationDestination(for: LineRoute.self) { route in
            switch route {
            case .countries: LineCountriesPage()
            case .cities:    LineCitiesPage()
            }
        }
    }
}

/// A live line (spec §4.3): the title, the number card, the status banners,
/// and Messages · Calls · Number. No FAB — compose and the keypad are the
/// header's one trailing button, and the Switch capsule is on the card.
///
/// `LineStatusBanner` and `VoiceReadinessNotice` stay directly under the card
/// and never move into a segment: they are honesty surfaces, and a fault the
/// user has to go looking for is a fault they learn about from a stranger.
private struct LiveLineView: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    @Environment(SubscriptionStore.self) private var subs
    @Environment(CallController.self) private var calling
    /// Threaded through `LineEnv` for `PeerNameSheet`.
    @Environment(IAPStore.self) private var iap
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let line: Line

    enum Seg: CaseIterable, Hashable { case messages, calls, number }

    /// Opens on Messages: inbound SMS is the half that demonstrably works.
    @State private var seg: Seg = LiveLineView.initialSeg
    @State private var naming: PeerRef?
    @State private var swappedTo: String?
    /// +1 when the new segment is to the right of the old one, -1 to the
    /// left, so the content slides the way the capsule glides.
    @State private var segDirection: CGFloat = 1
    /// The thread list's entrance stagger (spec §3a), once per visit.
    @State private var listShown = false

    /// Screenshot harness: `lineCalls` / `lineNumber` open on their segment.
    private static var initialSeg: Seg {
        switch ScreenshotMode.screen {
        case .lineCalls:  .calls
        case .lineNumber: .number
        default:          .messages
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                LineNumberCard(line: line, swappedTo: $swappedTo)
                    .padding(.top, RSpace.lg)
                LineStatusBanner(line: line)
                VoiceReadinessNotice(readiness: calling.readiness)
                if line.status.isSettingUp {
                    provisioning
                } else {
                    CapsuleSegmentedControl(selection: segBinding, tags: Seg.allCases) { tag, _ in
                        segmentLabel(tag)
                    }
                    .padding(.top, RSpace.xl)
                    ZStack { segmentContent }
                        .padding(.top, RSpace.lg)
                }
            }
            .padding(.horizontal, RSpace.gutter)
            .padding(.bottom, RSpace.xxl)
        }
        .scrollIndicators(.hidden)
        // Pull to refresh reloads the line and its threads (and calls, which
        // the Calls segment reads).
        .refreshable {
            async let l: () = state.loadLine(using: LineAPI(client: api))
            async let t: () = state.loadLineThreads(using: LineAPI(client: api))
            async let c: () = state.loadLineCalls(using: LineAPI(client: api))
            _ = await (l, t, c)
        }
        .background(theme.bg.ignoresSafeArea())
        .sheet(item: $naming) { peer in
            PeerNameSheet(e164: peer.id)
                .modifier(LineEnv(theme: theme, state: state, api: api,
                                  subs: subs, calling: calling, iap: iap))
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(theme.bg)
        }
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
        .onChange(of: line.id) { _, id in
            calling.activeLineId = id
            swappedTo = nil
        }
        // A name sheet would sit above the call screen (telephony trap 5).
        .onChange(of: calling.isLive) { _, live in if live { naming = nil } }
    }

    private var unreadCount: Int {
        state.threadsForSelectedLine.reduce(0) { $0 + $1.unreadCount }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            Text("My number")
                .displayType(30)
                .foregroundStyle(theme.text)
            Spacer(minLength: RSpace.md)
            headerAction
        }
        // The button's height, held when Number shows none, so the card does
        // not jump up when that segment is selected.
        .frame(minHeight: 44)
        .padding(.top, RSpace.lg)
    }

    /// The segment's one action. 🔴 The keypad is HIDDEN, never disabled,
    /// without a voice client: a disabled button still advertises a
    /// capability the build lacks. Compose has no such gate — every refusal
    /// `send-line-message` can make is stated inside `ComposeScreen`.
    @ViewBuilder
    private var headerAction: some View {
        switch seg {
        case .messages:
            roundButton(icon: "square.and.pencil", label: Text("New message")) {
                state.flow = .compose
            }
        case .calls:
            if calling.isVoiceAvailable {
                roundButton(icon: "circle.grid.3x3.fill", label: Text("Make a call")) {
                    state.flow = .dialer
                }
            }
        case .number:
            EmptyView()
        }
    }

    private func roundButton(icon: String, label: Text,
                             action: @escaping () -> Void) -> some View {
        Button {
            RHaptic.select()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.text)
                .frame(width: 44, height: 44)
                .background(theme.chipBg, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(PressScaleStyle(scale: 0.92))
        .accessibilityLabel(label)
    }

    // MARK: Segments

    @ViewBuilder
    private func segmentLabel(_ tag: Seg) -> some View {
        switch tag {
        case .messages:
            HStack(spacing: 5) {
                Text("Messages")
                if unreadCount > 0 {
                    Text(verbatim: "\(unreadCount)")
                        .monospacedDigit()
                        .foregroundStyle(theme.text2)
                }
            }
        case .calls:  Text("Calls")
        case .number: Text("Number")
        }
    }

    /// Direction is set in the SAME transaction as the selection, so the
    /// insertion transition reads the new direction, not the previous one.
    private var segBinding: Binding<Seg> {
        Binding(get: { seg }, set: { new in
            let all = Seg.allCases
            segDirection = (all.firstIndex(of: new) ?? 0) > (all.firstIndex(of: seg) ?? 0) ? 1 : -1
            seg = new
        })
    }

    /// Crossfade plus a slight slide in the segment order's direction (spec
    /// §3a). `CapsuleSegmentedControl` changes the selection inside
    /// `withAnimation(RMotion.unlessReduced(RMotion.standard, …))`, so under
    /// Reduce Motion the swap is instant.
    private var segmentTransition: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(x: 8 * segDirection)),
                    removal: .opacity.combined(with: .offset(x: -8 * segDirection)))
    }

    @ViewBuilder
    private var segmentContent: some View {
        switch seg {
        case .messages:
            messages.transition(segmentTransition)
        case .calls:
            LineRecentsView(line: line).transition(segmentTransition)
        case .number:
            LineNumberSegment(line: line) { swappedTo = $0 }.transition(segmentTransition)
        }
    }

    // MARK: Provisioning

    /// The number exists but is not usable yet (orders are asynchronous).
    private var provisioning: some View {
        VStack(spacing: RSpace.sm) {
            ProgressView()
            Text("Setting up your number")
                .font(RFont.text(16, weight: .semibold))
                .foregroundStyle(theme.text)
            Text("This usually takes a few seconds. You can leave this screen, and we'll let you know when it's ready.")
                .font(RFont.text(13))
                .foregroundStyle(theme.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, RSpace.xxl)
    }

    // MARK: Messages

    /// One inset-grouped list (spec §4.3). The empty state names no service:
    /// the old proof-of-life card's "and most other apps" was unmeasured.
    /// Rendered only once the first read has answered (the 2026-09-06 flash).
    @ViewBuilder
    private var messages: some View {
        let threads = state.threadsForSelectedLine
        if threads.isEmpty {
            if state.lineThreadsLoaded {
                VStack(spacing: RSpace.sm) {
                    Image(systemName: RIcon.message)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(theme.text3)
                    Text("Codes and texts sent to this number appear here.")
                        .font(RFont.text(15))
                        .foregroundStyle(theme.text2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, RSpace.xxl)
            }
        } else {
            // Lazy: the thread list is uncapped, and the tab's ScrollView is
            // the scroll container, so rows off screen are not built.
            LazyVStack(spacing: 0) {
                ForEach(threads) { thread in
                    if thread.id != threads.first?.id {
                        RowRule(inset: RSpace.lg + 40 + RSpace.md)
                    }
                    ThreadRow(
                        thread: thread,
                        name: state.contactName(for: thread.peerE164),
                        onAddName: { naming = PeerRef(id: thread.peerE164) },
                        onCopy: { UIPasteboard.general.string = thread.peerE164
                                  RHaptic.select() },
                        onTap: {
                            state.openThreadId = thread.id
                            state.flow = .thread       // Task 6 turns this into a push
                        })
                    // Capped stagger on entry; a new thread (an inbound
                    // message from a new peer) drops in at the top.
                    .riseIn(listShown, index: threads.firstIndex(of: thread) ?? 0)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .background(theme.elev, in: .rect(cornerRadius: RRadius.group, style: .continuous))
            .animation(RMotion.unlessReduced(RMotion.standard, reduceMotion), value: threads.map(\.id))
            .onAppear { listShown = true }
        }
    }
}

// MARK: - Shared plumbing

/// A peer number, wrapped so it can drive `.sheet(item:)`.
struct PeerRef: Identifiable, Hashable {
    let id: String
}

/// The environment a line sheet needs, re-injected at the presentation site.
///
/// 🔴 Sheet and cover content does NOT inherit `@Observable` environment
/// objects from its presenter — the trap `ContentView.EnvBundle` exists for.
/// This is the same modifier scoped to the objects the line sheets read
/// (`PeerNameSheet` reads two), rather
/// than making the app-wide bundle reachable from here and dragging six more
/// objects through this file.
struct LineEnv: ViewModifier {
    let theme: Theme
    let state: AppState
    let api: APIClient
    let subs: SubscriptionStore
    let calling: CallController
    /// Added 2026-09-05: a line sheet can end on a credits top-up, and
    /// `CreditsSheet` reads `IAPStore` from the environment — a crash on
    /// presentation without it.
    let iap: IAPStore

    func body(content: Content) -> some View {
        content
            .environment(\.theme, theme)
            .environment(state)
            .environment(api)
            .environment(subs)
            .environment(calling)
            .environment(iap)
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
            .background(copy.tint.opacity(0.12), in: .rect(cornerRadius: RRadius.group))
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
                 // while outbound is what lapsing withdraws. Sending is named
                 // again since 2026-09-08 because `begin_outbound_message`
                 // genuinely refuses a `past_due` line — the banner has to
                 // match the refusal the composer will give.
                 text: "Your subscription lapsed. You can still receive texts and calls, but you can't send texts or call out until you renew.")
        case .suspended:
            Copy(icon: "lock", tint: theme.fail,
                 // 🔴 THIS MUST NOT PROMISE THE NUMBER BACK. The 7-day hold was
                 // retired on 2026-09-05 (`20260905130000`): `suspend_line_claim`
                 // sets `hold_until = now()` and ignores its argument, so a
                 // lapsed line goes suspended -> releasing in the SAME sweep and
                 // `release-lines` deletes it at Telnyx within ~30 minutes. And
                 // resubscribing provisions a DIFFERENT number
                 // (`reprovisionAfterRenewal`), so "get it back" was promising
                 // the one outcome the server guarantees cannot happen.
                 text: "Your subscription lapsed and this number has been released. Resubscribe and we'll set you up with a new one.")
        case .failed:
            Copy(icon: "exclamationmark.triangle", tint: theme.fail,
                 text: "We couldn't finish setting up your number. You haven't been charged for a number you don't have.")
        default:
            nil
        }
    }
}

// MARK: - Rows

/// A conversation, the way a messages app lists one: avatar, who, the last
/// thing they said, when.
///
/// The ROW still carries no compose affordance, and that is unchanged by the
/// 2026-09-08 return of outbound SMS: tapping a row opens the conversation,
/// which is where the composer is. The long-press menu stays limited to naming
/// and copying — both act on the peer, and a third "message" item would
/// duplicate the tap. Starting a NEW conversation is the header's compose
/// button.
struct ThreadRow: View {
    @Environment(\.theme) private var theme
    let thread: LineThread
    var name: String? = nil
    var onAddName: (() -> Void)? = nil
    var onCopy: (() -> Void)? = nil
    /// LAST, so a trailing-closure call site (`ThreadRow(thread: t) { … }`)
    /// binds the tap and not one of the optional menu actions.
    let onTap: () -> Void

    private var unread: Bool { thread.unreadCount > 0 }

    /// The first 4–8 digit group in a preview, with WhatsApp's "123-456"
    /// shape accepted. Display only — it decides nothing and copies nothing;
    /// the thread screen remains the place a code is copied from. Returns nil
    /// for a phone-number-shaped run (10+ digits) so a preview quoting a
    /// number is not dressed up as a code.
    static func code(in preview: String?) -> String? {
        guard let preview else { return nil }
        let pattern = #"(?<!\d)(\d{3}-\d{3}|\d{4,8})(?!\d)"#
        guard let range = preview.range(of: pattern, options: .regularExpression) else { return nil }
        return String(preview[range])
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                PeerAvatar(e164: thread.peerE164, name: name, size: 40, neutral: true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(verbatim: name ?? PhoneFormat.compact(thread.peerE164))
                            // Unread is carried by WEIGHT plus the dot, never by
                            // colour alone — the accent is the user's own choice
                            // and can be low-contrast on either background.
                            .font(RFont.text(15, weight: unread ? .bold : .semibold))
                            .foregroundStyle(theme.text)
                            .lineLimit(1)
                        if thread.blocked {
                            Text("Blocked")
                                .font(RFont.text(10, weight: .semibold))
                                .foregroundStyle(theme.text3)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(theme.chipBg, in: .capsule)
                        }
                    }
                    // The code first, when the last message carries one. A
                    // subscriber opening this list is almost always here for
                    // a verification code (2026-09-01: codes-first), and a
                    // 13pt truncated preview — "Your verification code is 1…"
                    // — hid the one thing they came for behind an ellipsis.
                    HStack(spacing: 6) {
                        if let code = ThreadRow.code(in: thread.lastPreview) {
                            Text(verbatim: code)
                                .numberStyle(size: 13, weight: .bold, color: theme.text)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(theme.chipBg, in: .rect(cornerRadius: 6))
                        }
                        Text(thread.lastPreview ?? "")
                            .font(RFont.text(13, weight: unread ? .medium : .regular))
                            .foregroundStyle(unread ? theme.text : theme.text2)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 5) {
                    if let at = thread.lastMessageAt {
                        Text(at.formatted(.relative(presentation: .numeric)))
                            .font(RFont.text(11))
                            .foregroundStyle(theme.text3)
                            .lineLimit(1)
                    }
                    if unread {
                        Circle().fill(theme.text).frame(width: 8, height: 8)
                    }
                }
            }
            // The list draws the group (one inset-grouped surface, spec §4.3).
            .padding(.horizontal, RSpace.lg)
            .padding(.vertical, RSpace.md)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onAddName {
                Button {
                    onAddName()
                } label: {
                    Label(name == nil
                          ? String(localized: "Add name")
                          : String(localized: "Rename"),
                          systemImage: "person.crop.circle.badge.plus")
                }
            }
            if let onCopy {
                Button {
                    onCopy()
                } label: {
                    Label(String(localized: "Copy number"), systemImage: RIcon.copy)
                }
            }
        }
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
        .background(tint.opacity(0.12), in: .rect(cornerRadius: RRadius.group))
        .padding(.top, 10)
    }
}
