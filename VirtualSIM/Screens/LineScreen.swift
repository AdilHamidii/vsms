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
                // history is still readable once a new line exists.
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

/// A line that exists — shaped like a phone app (2026-08-27).
///
/// It used to open with a 34pt centred hero: the number, Copy and Share
/// capsules, a status line, and only then a three-way segmented control whose
/// third segment was the billing screen. That is a product page, not a tool.
/// A phone app has TWO places you live in — recents and conversations — and a
/// settings screen you visit twice a year, so:
///
/// - the hero collapses into one slim bar (flag, number, live dot, gear),
///   keeping tap-to-copy and Share as an icon,
/// - the segments are **Recents | Messages**,
/// - everything the Number segment held moved behind the gear into
///   `LineSettingsScreen`,
/// - a floating dial FAB sits over both segments, so the keypad is reachable
///   from wherever you are rather than only from inside Calls.
///
/// `LineStatusBanner` and `VoiceReadinessNotice` stay directly under the header
/// and did NOT move into settings. They are honesty surfaces — "your payment
/// failed", "your number cannot receive calls yet" — and a fault the user has
/// to go looking for is a fault they find out about from a stranger who could
/// not reach them.
private struct LiveLineView: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    @Environment(SubscriptionStore.self) private var subs
    @Environment(CallController.self) private var calling

    let line: Line

    private enum Seg: Hashable { case recents, messages }
    /// Opens on Messages, deliberately unchanged: inbound SMS is the half of
    /// this product that demonstrably works, and the empty-inbox card is the
    /// one instruction a new subscriber needs in their first minute.
    @State private var seg: Seg = .messages
    @State private var copied = false
    @State private var showingSettings = false
    /// Set by the settings sheet, acted on once it has actually gone. Assigning
    /// `state.flow` from inside a sheet asks SwiftUI to present a
    /// `fullScreenCover` from a view that is being torn down — sometimes it
    /// works, sometimes the cover never appears, and nothing logs a reason.
    @State private var pendingRentAnother = false
    @State private var naming: PeerRef?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
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
                        (.recents, String(localized: "Recents"), nil),
                        (.messages, String(localized: "Messages"),
                         unreadCount == 0 ? nil : unreadCount),
                    ])
                    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)

                    // No blanket `.animation` here — `SegmentedTabs` already
                    // wraps its selection change in `withAnimation`, which
                    // these transitions pick up.
                    ZStack {
                        switch seg {
                        case .recents:  LineRecentsView(line: line).transition(.opacity)
                        case .messages: messages.transition(.opacity)
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            // Hidden on a build with no voice client — see `dialFAB`.
            if !line.status.isSettingUp { dialFAB }
        }
        .background(theme.bg)
        .sheet(isPresented: $showingSettings, onDismiss: openStoreIfRequested) {
            LineSettingsScreen(line: line,
                               onRentAnother: { pendingRentAnother = true })
                // 🔴 Sheet content does NOT inherit `@Observable` environment
                // objects from its presenter. `SubscriptionStore` in
                // particular is a crash on presentation, not a blank screen.
                .modifier(LineEnv(theme: theme, state: state, api: api,
                                  subs: subs, calling: calling))
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(theme.bg)
        }
        .sheet(item: $naming) { peer in
            PeerNameSheet(e164: peer.id)
                .modifier(LineEnv(theme: theme, state: state, api: api,
                                  subs: subs, calling: calling))
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
        .onChange(of: line.id) { _, id in calling.activeLineId = id }
    }

    private var unreadCount: Int {
        state.threadsForSelectedLine.reduce(0) { $0 + $1.unreadCount }
    }

    private func openStoreIfRequested() {
        guard pendingRentAnother else { return }
        pendingRentAnother = false
        state.flow = .lineStoreMore
    }

    // MARK: - Header

    /// One slim bar: whose number this is, whether it is live, and the way into
    /// settings.
    ///
    /// The number is still the first thing on the screen and still copies on
    /// tap — that muscle memory is cheap to keep and it is what a subscriber
    /// came here to do. What it no longer does is take a third of the viewport
    /// to say it, above two lists that are the actual product.
    private var header: some View {
        HStack(spacing: 11) {
            CodeFlag(code: line.countryCode, size: 28, style: .circle)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Button { copyNumber() } label: {
                        HStack(spacing: 7) {
                            Circle().fill(statusTint).frame(width: 7, height: 7)
                            Text(verbatim: PhoneFormat.national(line.e164))
                                .font(RFont.mono(17, weight: .semibold))
                                .foregroundStyle(theme.text)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(PressScaleStyle())

                    // Only when there is a choice to make. One number must look
                    // exactly as it did before multi-number existed.
                    if state.hasMultipleLines { lineSwitcher }
                }
                subtitle
            }

            Spacer(minLength: 8)

            // Sharing the number is genuinely the next step for a new
            // subscriber, so it keeps a permanent affordance — as an icon now
            // rather than a full-width capsule.
            ShareLink(item: PhoneFormat.national(line.e164)) {
                iconChip("square.and.arrow.up")
            }
            .simultaneousGesture(TapGesture().onEnded { RHaptic.select() })

            Button {
                RHaptic.select()
                showingSettings = true
            } label: {
                iconChip(RIcon.gear)
            }
            .buttonStyle(.plain)
            .pressable(0.9)
            .accessibilityLabel(Text("Number settings"))
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func iconChip(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(theme.text2)
            .frame(width: 36, height: 36)
            .background(theme.chipBg, in: .circle)
            .contentShape(.circle)
    }

    /// The dot's colour, matching what `LineStatusBanner` says in a sentence
    /// underneath. Two components describing the same fault must at least agree
    /// on whether there is one.
    private var statusTint: Color {
        switch line.status {
        case .active:            theme.live
        case .grace, .pastDue:   theme.warn
        case .suspended, .failed: theme.fail
        default:                 theme.text3
        }
    }

    /// One quiet line under the number: copied, or when it renews.
    ///
    /// Deliberately says nothing about a PROBLEM state — `LineStatusBanner`
    /// sits directly below and explains grace, past-due and suspension in a
    /// full sentence. Two components describing the same fault, one in three
    /// words and one in thirty, is how they drift apart.
    @ViewBuilder
    private var subtitle: some View {
        if copied {
            Text("Copied")
                .font(RFont.text(12, weight: .medium))
                .foregroundStyle(theme.live)
        } else if line.status == .active, let end = line.currentPeriodEnd {
            Text("Active · renews \(end.formatted(.dateTime.day().month(.abbreviated)))")
                .font(RFont.text(12))
                .foregroundStyle(theme.text3)
        } else {
            Text("Tap the number to copy it")
                .font(RFont.text(12))
                .foregroundStyle(theme.text3)
        }
    }

    private func copyNumber() {
        UIPasteboard.general.string = line.e164
        RHaptic.select()
        withAnimation(RMotion.select) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(RMotion.select) { copied = false }
        }
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
            .frame(minWidth: 28, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Dial FAB

    /// The one entry point to the keypad, on BOTH segments.
    ///
    /// It was a capsule inside the Calls list, so dialling required first
    /// finding the segment that holds the keypad — and on the empty state it
    /// competed with the empty-state copy for the same 200 points of screen.
    ///
    /// 🔴 HIDDEN, never disabled, when no voice client is attached. A disabled
    /// button still advertises the feature, and on a build without the SDK that
    /// is a promise the app cannot keep. Same rule as the removed "New message"
    /// button, and as `RecentRow`'s call-back glyph.
    @ViewBuilder
    private var dialFAB: some View {
        if calling.isVoiceAvailable {
            Button {
                RHaptic.select()
                state.flow = .dialer
            } label: {
                Image(systemName: "circle.grid.3x3.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(theme.onInk)
                    .frame(width: 60, height: 60)
                    .background(theme.ink, in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .pressable(0.94)
            .accessibilityLabel(Text("Make a call"))
            .padding(.trailing, 20)
            // Clears the floating tab bar, which is 28pt off the bottom and
            // ~56pt tall. Same clearance the scrolling lists reserve.
            .padding(.bottom, 108)
        }
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
    /// their first hour, so it is the screen that most deserves designing.
    ///
    /// 🔴 IT IS THE CANCELLATION SCREEN. Every subscriber so far killed
    /// auto-renew at a median of 3.9 minutes after paying, and lifetime inbound
    /// is 8 messages across 13 subscriptions — so what they bought, looked at,
    /// and cancelled is this exact view with nothing in it. Silence on a screen
    /// that is supposed to receive reads as "the number is dead", and nothing
    /// here ever told them how to find out otherwise.
    ///
    /// So it is ONE instruction, not an invitation to share and wait: **text
    /// the number from your own phone.** Inbound SMS is the half that
    /// demonstrably works (3 of 3 lifetime), it costs the user nothing, it
    /// needs no second person, and it answers the only question they have in
    /// seconds.
    ///
    /// ⚠️ It must NOT say "call it and see". Inbound CALLING has never
    /// connected once, so half the instruction would be a broken promise on the
    /// same card — and this is the surface the product's credibility rests on.
    @ViewBuilder
    private var messages: some View {
        if state.threadsForSelectedLine.isEmpty {
            proofOfLife
                .padding(.horizontal, 20)
                .padding(.top, 24)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(state.threadsForSelectedLine) { thread in
                        ThreadRow(
                            thread: thread,
                            name: state.contactName(for: thread.peerE164),
                            onAddName: { naming = PeerRef(id: thread.peerE164) },
                            onCopy: { UIPasteboard.general.string = thread.peerE164
                                      RHaptic.select() },
                            onTap: {
                                state.openThreadId = thread.id
                                state.flow = .thread
                            })
                    }
                }
                .padding(.horizontal, 20)
                // Clears the tab bar AND the dial FAB in the same corner.
                .padding(.bottom, 140)
            }
        }
    }

    /// The one card the empty inbox shows: how to prove the number works.
    ///
    /// A `Card` rather than the shared `EmptyState`, deliberately. `EmptyState`
    /// is centred chrome that says "there is nothing here" — which is the
    /// reading that gets this product cancelled. This is an instruction, so it
    /// is left-aligned, raised, and reads as something to act on.
    private var proofOfLife: some View {
        Card(elevation: .raised) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    // The live dot is the same grammar as the header's status
                    // dot: this is a state, not a decoration.
                    Circle().fill(theme.live).frame(width: 7, height: 7)
                    Text("Your number is live")
                        .font(RFont.display(17, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(theme.text)
                }
                Text("Text it from your own phone — the message appears here within seconds.")
                    .font(RFont.text(14))
                    .lineSpacing(2)
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                // Points at the header rather than repeating it — one number
                // per screen, so a swap has one place to be correct.
                Text("Your number is at the top of this screen — tap it to copy.")
                    .font(RFont.text(12))
                    .foregroundStyle(theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // 🔴 A "New message" button lived here, in both states, and is GONE
    // (owner decision, 2026-08-18: outbound SMS is dropped, not delayed).
    // Every send this product ever attempted to a US number came back
    // `40010 — the sending number is not 10DLC-registered`, and registration
    // is not being pursued. HIDDEN rather than disabled, which is the rule the
    // dial FAB also follows: a disabled button still advertises the feature,
    // and here the feature is never coming back.
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
/// This is the same modifier scoped to the four objects the line sheets read
/// (`LineSettingsScreen` reads all four; `PeerNameSheet` reads two), rather
/// than making the app-wide bundle reachable from here and dragging six more
/// objects through this file.
struct LineEnv: ViewModifier {
    let theme: Theme
    let state: AppState
    let api: APIClient
    let subs: SubscriptionStore
    let calling: CallController

    func body(content: Content) -> some View {
        content
            .environment(\.theme, theme)
            .environment(state)
            .environment(api)
            .environment(subs)
            .environment(calling)
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
                 // The receive/dial split is the point of this banner: inbound
                 // stays on because the user cannot control who contacts them,
                 // while outbound is what lapsing withdraws. It said "send or
                 // dial out" — sending is gone product-wide, so naming it here
                 // would advertise a capability by describing its loss.
                 text: "Your subscription lapsed. You can still receive texts and calls, but you can't call out until you renew.")
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

/// A conversation, the way a messages app lists one: avatar, who, the last
/// thing they said, when.
///
/// 🔴 THERE IS NO COMPOSE AFFORDANCE ANYWHERE ON THIS LIST, and adding one back
/// is a regression. Outbound SMS was dropped product-wide on 2026-08-18 —
/// `send-line-message` refuses every send with `outbound_sms_retired`. The
/// long-press menu is deliberately limited to naming and copying: both act on
/// the peer, neither promises a message.
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

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                PeerAvatar(e164: thread.peerE164, name: name, size: 44)
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
                    Text(thread.lastPreview ?? "")
                        .font(RFont.text(13, weight: unread ? .medium : .regular))
                        .foregroundStyle(unread ? theme.text : theme.text2)
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
                    if unread {
                        Circle().fill(theme.ink).frame(width: 8, height: 8)
                    }
                }
            }
            .padding(14)
            .background(theme.elev, in: .rect(cornerRadius: 16))
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
        .background(tint.opacity(0.12), in: .rect(cornerRadius: 14))
        .padding(.top, 10)
    }
}
