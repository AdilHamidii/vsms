import SwiftUI
import StoreKit   // \.requestReview lives here. The ONLY call site is the
                 // foreground block below; OtpScreen and EmailCodeScreen
                 // both dropped the import when the prompt moved off the
                 // code screens.

enum ActiveSheet: String, Identifiable {
    case services, country, credits, emailDomain
    var id: String { rawValue }

    /// Height belongs to the SHEET, not to the presenter.
    ///
    /// Every sheet was presented `.large` from one place out here, which is
    /// right for a 265-row service list and wrong for the domain picker: that
    /// one typically renders two to four rows, so roughly 80% of a full-height
    /// sheet was empty. The domain sheet asked for its own detents from inside
    /// its body and it had no effect — an OUTER `.presentationDetents` wins
    /// over one applied to the content, so the fix has to live at the
    /// presentation site.
    var detents: Set<PresentationDetent> {
        switch self {
        case .emailDomain: [.medium, .large]
        default:           [.large]
        }
    }
}

struct ContentView: View {
    @Environment(APIClient.self) private var api
    @Environment(PushManager.self) private var push
    @Environment(Session.self) private var session
    @Environment(IAPStore.self) private var iap
    @Environment(SubscriptionStore.self) private var subs
    @Environment(CallController.self) private var calls
    /// The e-mail subscription's store, owned by `AuthGate` alongside
    /// `SubscriptionStore`.
    ///
    /// It used to be `@State` here, attached and registered in this view's task
    /// — i.e. after `coldStart`, and therefore after `IAPStore`'s
    /// unfinished-transaction sweep had already run and dropped anything it
    /// found. See the comment on `AuthGate.mailStore`. It still needs its own
    /// `EnvBundle` injection, because sheet/cover content does not inherit
    /// `@Observable` environment objects reliably.
    @Environment(MailSubscriptionStore.self) private var mailStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview

    @State private var state = AppState()
    /// Sheets presented from the TAB content (home / esim / orders / account).
    @State private var sheet: ActiveSheet?
    /// Sheets presented from INSIDE the fullScreenCover (checkout, eSIM
    /// checkout). Deliberately a separate binding: both `.sheet` modifiers
    /// used to observe `$sheet`, so opening a picker from the checkout screen
    /// made the covered content AND the root both try to present the same
    /// sheet. SwiftUI does not define that — the picker flickered, opened
    /// behind the cover, or refused to open, which is why changing service or
    /// country on the confirm screen felt broken. One binding per presenter.
    @State private var flowSheet: ActiveSheet?

    /// The DEVICE appearance. Read here rather than derived from
    /// `.preferredColorScheme` below: that modifier pushes a scheme DOWN to
    /// children, so the ambient value read at this level is still the system's
    /// — which is precisely what `.system` mode needs to resolve against.
    @Environment(\.colorScheme) private var systemScheme

    private var isDark: Bool { state.appearance.isDark(system: systemScheme) }

    private var theme: Theme {
        isDark ? .dark(state.accent) : .light(state.accent)
    }

    var body: some View {
        @Bindable var state = state
        ZStack(alignment: .bottom) {
            theme.bg.ignoresSafeArea()

            Group {
                switch state.tab {
                case .home:
                    // `openServices` is the SAME closure `TempScreen` gets, so
                    // Home's More tile and the Temp tab's picker raise one
                    // sheet rather than two that could drift apart.
                    HomeScreen(openCredits: { sheet = .credits },
                               openServices: { sheet = .services })
                case .line:
                    LineScreen(onOpenSms: { state.tab = .temp })
                case .temp:
                    TempScreen(
                        openServices: { sheet = .services },
                        openCountries: { sheet = .country },
                        openEmailDomains: { sheet = .emailDomain },
                        openCredits: { sheet = .credits },
                        onStart: { state.startCheckout() },
                        onStartEmail: {
                            Task {
                                await state.confirmGetEmail(
                                    using: EmailAPI(client: api),
                                    wallet: WalletAPI(client: api))
                            }
                        },
                        onTapOrder: { o in
                            if o.status == .waiting {
                                state.activeOrder = o
                                state.flow = .waiting
                            } else if o.otp != nil {
                                state.activeOrder = o      // rescued code — show it
                                state.flow = .otp
                            } else {
                                state.buyAgain(o)
                            }
                        },
                        onSeeAllOrders: { state.flow = .orders }
                    )
                case .orders:
                    OrdersScreen(openCredits: { sheet = .credits })
                case .account:
                    AccountScreen(openCredits: { sheet = .credits })
                }
            }

            VStack(spacing: 10) {
                // Sits above the tab bar on every tab. Closing a waiting screen
                // no longer cancels the order, so there has to be a way back —
                // otherwise a live order just vanishes from view and the user
                // reasonably assumes it died.
                ResumeBar()
                    .padding(.horizontal, 16)
                TabBar(tab: $state.tab, lineUnread: state.lineUnreadCount)
                    .padding(.horizontal, 12)
            }
            .padding(.bottom, 28)
            .animation(.easeOut(duration: 0.25), value: state.flow)
        }
        // Environment first, THEN overlay/sheet/cover — so banner + cover
        // content all see AppState in scope.
        .environment(\.theme, theme)
        .environment(state)
        .environment(mailStore)
        .preferredColorScheme(state.appearance.colorScheme)
        .overlay(alignment: .top) {
            ErrorBanner()
                .environment(\.theme, theme)
                .environment(state)
                .animation(.easeOut(duration: 0.25), value: state.lastError)
        }
        // A live call sits ABOVE the flow cover and BELOW maintenance/splash.
        //
        // It cannot be a `FlowStage`: a call can arrive while a
        // `fullScreenCover` is already open, `fullScreenCover(item:)` cannot
        // present a second cover, and swapping `flow` would destroy whatever
        // the user had in progress — including a half-finished checkout. The
        // environment is re-injected because a ZStack layer at this level does
        // not inherit reliably, the same reason `EnvBundle` exists.
        //
        // ⚠️ AN OVERLAY AT THIS LEVEL IS BELOW EVERY `fullScreenCover` AND
        // `sheet`, so this copy alone could never be seen while one was open —
        // which is exactly what happened when a call was placed from the
        // dialer (itself a cover): the keypad stayed up and the call screen
        // rendered underneath it, invisible. So this copy is scoped to "no
        // cover is open" and the cover carries its own, the same way
        // `ErrorBanner` is already duplicated into it. Sheets are detented, so
        // hosting a call screen inside one would render it at sheet height —
        // they are dismissed instead, below.
        .overlay {
            if calls.isLive, state.flow == nil {
                InCallOverlay()
                    .environment(\.theme, theme)
                    .environment(calls)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.22), value: calls.isLive)
        // A picker is not work worth preserving over a live call, and left
        // open it would sit on top of the call screen.
        .onChange(of: calls.isLive) { _, live in
            if live {
                sheet = nil
                flowSheet = nil
            }
        }
        .overlay {
            if state.maintenance.isActiveNow {
                MaintenanceView(
                    until: state.maintenance.until,
                    message: state.maintenance.message,
                    onRefresh: { Task { await state.refreshMaintenance(using: MaintenanceAPI(client: api)) } }
                )
                .environment(\.theme, theme)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.3), value: state.maintenance.isActiveNow)
        // Above the maintenance overlay, so a cold launch shows ONE cover, not
        // a splash that lifts onto a second full-screen takeover. Suppressed
        // once maintenance is known to be on: that screen is the honest answer
        // and should not wait behind five more fetches.
        .overlay {
            if state.bootPhase != .ready, !state.maintenance.isActiveNow {
                SplashScreen(
                    state: state.bootPhase == .failed
                        ? .failed : .progress(state.bootProgress),
                    onRetry:    { Task { await state.coldStart(api: api) } },
                    onContinue: { state.continueWithoutCatalog() }
                )
                .environment(\.theme, theme)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.35), value: state.bootPhase)
        .task {
            #if DEBUG
            // The cold-start chain is skipped entirely — six sequential
            // fetches would fail without a real token. See `ScreenshotMode`.
            //
            // ⚠️ This comment used to claim screenshots "run offline against
            // seeded data". They do not: `routes` carries a `public read` RLS
            // policy, so the scenePhase refresh below loads the LIVE catalog
            // with nothing but the publishable key. Verified 2026-08-06 — the
            // Home frame rendered whatsapp/us at 48 credits and 37%, matching
            // production to the digit. So prices and network rates in these
            // frames DO move when a provider reprices, and a frame captured
            // months apart will differ.
            if let shot = ScreenshotMode.screen {
                applyScreenshotState(shot)
                return
            }
            #endif
            // The whole cold-launch sequence, including which steps must finish
            // before the splash lifts. See AppState.coldStart.
            await state.coldStart(api: api)

            // `mailStore` is attached and its transaction handler registered in
            // `AuthGate`, before the restore sweep — doing it here meant the
            // sweep had already dropped the transaction. Do not move it back.

            // StoreKit prices, BEHIND the reveal.
            //
            // ⚠️ Home's "about $x" money line is GONE, so this no longer feeds
            // it. It stays because `CreditsSheet` is the only other reader and
            // it opens on a tap: without the preload the paywall renders its
            // ladder with no prices until StoreKit answers, on the one screen
            // where the price IS the content. Nothing waits for it either way.
            //
            // Historical, and the reason this call exists at all: `iap.products`
            // had exactly three writers, all inside CreditsSheet or
            // `purchase()`, and `IAPStore.attach` only restores — so anything
            // outside the paywall that quoted a price rendered nothing until
            // the user had opened the paywall at least once. `iap` is `@State`
            // in `AuthGate`, so that was true on EVERY cold launch.
            await iap.loadProducts()

            // 🔴 REGISTER WITH TELNYX AT LAUNCH WHEN THE USER HOLDS A NUMBER.
            //
            // Telnyx learns a device's VoIP token from a LOGIN and can only
            // push to a token it has seen — *"You will need to login at least
            // once to send your device token to Telnyx before start getting
            // Push notifications"* (`push-notification/app-setup.md`). Until
            // this existed the only logins in the app were `LineScreen.task`
            // and the dialer, so a subscriber who never opened the Number tab
            // could not be rung at all, and one who opened it once was
            // reachable only until their token rotated.
            //
            // Behind the reveal, like the other work here: it is a background
            // registration, not something Home waits for. `prepareVoice()` is
            // idempotent and returns immediately when the socket is already up,
            // so this is one mint on a cold launch and nothing on a warm one.
            await connectVoiceIfLineIsLive()
        }
        // A line that lapses, is released, or is signed away stops being
        // something we should hold a voice session for — the credential is
        // rent we no longer pay for. Keyed on the receiving line's identity, so
        // renting a number mid-session registers it too.
        .onChange(of: receivingLineId) { _, _ in
            Task { await connectVoiceIfLineIsLive() }
        }
        // Keep polling a live email activation even when no screen shows it.
        // check-email-order is the ONLY thing that ever fetches an email code
        // from the provider — no server cron polls email and no push exists for
        // it — so before this task, closing the waiting screen (or force-
        // quitting) permanently abandoned a code the user had paid for: the
        // provider auto-cancels at ~21 min and the code is gone. Keyed on
        // "any waiting email order exists" so it costs nothing otherwise.
        .task(id: state.emailOrders.contains { $0.status == .waiting }) {
            guard state.emailOrders.contains(where: { $0.status == .waiting }) else { return }
            while !Task.isCancelled {
                if state.activeEmailOrder == nil || state.activeEmailOrder?.status.isTerminal == true {
                    state.activeEmailOrder = state.emailOrders.first { $0.status == .waiting }
                }
                guard state.activeEmailOrder?.status == .waiting else { return }
                await state.refreshEmailOrder(using: EmailAPI(client: api))
                try? await Task.sleep(for: .seconds(10))
            }
        }
        // Stock is live and per (service, domain), so the picker has to be
        // re-quoted whenever either input changes — entering email mode, or
        // switching service while already in it. Cheap: one call, and only when
        // the user is actually looking at email.
        .onChange(of: state.emailMode) { _, on in
            guard on else {
                // Leaving email mode must clear the email draft. This scenario
                // runs entirely at flow == nil, so flow's didSet — the only
                // other place that clears intent — never fires, and a stale
                // .email intent made creditsShortfall size the pack for a
                // 1-credit address instead of the SMS route on screen (the
                // third instance of the PurchaseIntent bug class).
                state.emailDomain = nil
                state.intent = .sms
                // The paywall is the fourth instance of this same bug class —
                // reached and left entirely at flow == nil, from the domain
                // sheet, so nothing else clears it when the user backs out of
                // e-mail mode with it still open. `showMailPaywall`'s own
                // didSet clears `intent` for the ordinary "tap Restore /
                // dismiss the sheet" path; this covers the second way out.
                state.showMailPaywall = false
                return
            }
            // ENTERING email mode must declare the intent too — the exit branch
            // alone is only half the invariant. `loadEmailDomains` auto-selects
            // an in-stock domain without touching `intent`, and `intent` only
            // became `.email` when the user opened the domain sheet or actually
            // started a purchase. So between the toggle and either of those,
            // `creditsShortfall` still answered for the SMS route: Home renders
            // "Need N more" from the e-mail price while `CreditsSheet` sized the
            // pack from the stale SMS route behind it. Fourth instance of the
            // PurchaseIntent bug class, and the same root cause as the exit
            // branch below — this all happens at flow == nil, so flow's didSet
            // never runs.
            state.intent = .email
            Task { await state.loadEmailDomains(using: EmailAPI(client: api)) }
        }
        .onChange(of: state.lastService.id) { _, _ in
            guard state.emailMode else { return }
            Task { await state.loadEmailDomains(using: EmailAPI(client: api)) }
        }
        // The Number tab owns the held number and the quote behind it, and both
        // are read at `flow == nil` — so `flow`'s didSet cannot clear them
        // without throwing away the number the moment the paywall closes. They
        // are cleared on LEAVING the tab instead, which is also where `intent`
        // is set, mirroring `.onChange(of: state.emailMode)` above.
        .onChange(of: state.tab) { _, tab in
            if tab == .line {
                state.intent = .line
            } else {
                state.clearLineDraft()
                // `.call` belongs to the dialer, which lives inside this tab —
                // so leaving the tab must retire it exactly as it retires
                // `.line`. Resetting only `.line` would strand a `.call` intent
                // and let the credits pill on Home size its pack for an
                // abandoned international call.
                if state.intent == .line || state.intent == .call { state.intent = .sms }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // The one moment we know a session is ending. Fire-and-forget.
            if phase == .background { Analytics.shared.flushOnBackground() }
            if phase == .active {
                Task {
                    // Re-fetch catalog too so server-side sync-prices runs
                    // show up without an app reinstall / force-quit.
                    await state.refreshMaintenance(using: MaintenanceAPI(client: api))
                    // Foreground too, not just cold launch — an announcement is
                    // posted to reach people who are ALREADY using the app, and
                    // a notice that only lands on the next cold start is useless
                    // during the outage it was written for.
                    await state.refreshAppStatus(using: AppStatusAPI(client: api))
                    // Throttled: the routes payload is ~3 MB and prices move
                    // hourly at most, so refetching on every foreground burned
                    // the user's data plan for nothing.
                    await state.loadCatalog(using: CatalogAPI(client: api), minInterval: 600)
                    await state.refreshWallet(using: WalletAPI(client: api))
                    await state.loadOrders(using: OrdersAPI(client: api))
                    await state.loadEmailOrders(using: EmailAPI(client: api))

                    // The ONLY review-prompt call site in the app. It used to
                    // fire ~0.9s after a code rendered on `OtpScreen`/
                    // `EmailCodeScreen` — exactly when the user is rushing to
                    // paste it elsewhere, guaranteeing a reflex dismissal and
                    // burning one of Apple's ~3 prompts/year. Now it fires only
                    // here, on the user's next return to the app, whether they
                    // reopened the code screen or read it off a lock-screen
                    // push. `loadOrders` just recorded any code it noticed for
                    // the first time; `shouldRequestReview` (via
                    // `reviewableRecentDelivery`) owns every gate — once per
                    // version, per-order dedupe, session-level paywall
                    // suppression.
                    if state.reviewableRecentDelivery() {
                        try? await Task.sleep(for: .seconds(1))
                        requestReview()
                    }
                }
            }
        }
        // Tapping an inbound-text push opens that conversation. Sets the tab
        // too: the thread cover renders over whatever tab is behind it, and
        // closing it should land the user on their number rather than back on
        // an unrelated product.
        //
        // 🔴 `initial: true` IS LOAD-BEARING, ON BOTH THIS AND THE ORDER
        // HANDLER. A notification tapped from a TERMINATED app is already
        // pending before this view exists: `AuthGate` sets `AppDelegate.push`
        // inside its own `.task`, whose didSet flushes the buffered response —
        // and that runs BEFORE `session.bootstrap()`, therefore before
        // `ContentView` is constructed. `onChange` observes a CHANGE, and the
        // change had already happened, so a cold launch from a push landed on
        // Home with the deep link silently dropped. That covers the product's
        // highest-volume re-entry path — "Your code arrived", tapped from the
        // lock screen — and every inbound-text push.
        .onChange(of: push.pendingLineThreadId, initial: true) { _, newValue in
            guard let threadId = newValue else { return }
            push.pendingLineThreadId = nil
            Task {
                await state.loadLineThreads(using: LineAPI(client: api))
                // Never open a thread we could not load. `ThreadScreen`
                // resolves its peer from `lineThreads`, so an unresolvable id
                // renders an ENABLED composer over an empty peer whose send
                // button silently does nothing.
                guard state.lineThreads.contains(where: { $0.id == threadId }) else {
                    state.tab = .line
                    state.intent = .line
                    return
                }
                state.tab = .line
                state.intent = .line
                state.openThreadId = threadId
                state.flow = .thread
            }
        }
        .onChange(of: push.pendingOrderId, initial: true) { _, newValue in
            guard let orderId = newValue else { return }
            push.pendingOrderId = nil
            Task {
                await state.loadOrders(using: OrdersAPI(client: api))
                guard let order = state.orders.first(where: { $0.id == orderId }) else { return }
                // `otp is not null` wins over status, always — a rescued code
                // lives on a CANCELED row, and routing that row by status would
                // land the user on the refund screen while their code sits one
                // switch-case away. Same rule as onTapOrder and OrdersScreen.
                if order.otp != nil {
                    state.activeOrder = order
                    state.flow = .otp
                    return
                }
                switch order.status {
                case .received:
                    state.activeOrder = order
                    state.flow = .otp
                case .expired, .canceled, .refunded:
                    // "No code arrived" is the app's most-delivered push. It
                    // used to dump the user on Home — so the single highest
                    // volume re-entry path bypassed the refund receipt and the
                    // measured-best-country steer that exist for exactly this
                    // moment.
                    state.recovery = RecoveryContext(
                        service: order.service,
                        failedCountry: order.country,
                        reason: order.status == .canceled ? .canceled : .expired,
                        refundedCredits: order.costCredits)
                    state.activeOrder = nil
                    state.flow = .recovery
                case .waiting:
                    state.activeOrder = order
                    state.flow = .waiting
                }
            }
        }
        .sheet(item: $sheet) { which in
            sheetContent(which)
                .modifier(EnvBundle(theme: theme, state: state, api: api, push: push, session: session, iap: iap, subs: subs, mailStore: mailStore, calls: calls))
                .presentationDetents(which.detents)
                .presentationDragIndicator(.visible)
                .presentationBackground(theme.bg)
        }
        // Not an `ActiveSheet` case: it is reached from `confirmGetEmail`
        // refusing with `subscription_required`, which can happen at
        // `flow == nil` from the domain sheet — a plain Bool, like
        // `state.maintenance`, rather than something threaded through the
        // item-based sheet enum.
        .sheet(isPresented: $state.showMailPaywall) {
            MailPaywallScreen(source: "refused")
                .modifier(EnvBundle(theme: theme, state: state, api: api, push: push, session: session, iap: iap, subs: subs, mailStore: mailStore, calls: calls))
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(theme.bg)
        }
        .fullScreenCover(item: $state.flow) { stage in
            flowContent(stage)
                .modifier(EnvBundle(theme: theme, state: state, api: api, push: push, session: session, iap: iap, subs: subs, mailStore: mailStore, calls: calls))
                .preferredColorScheme(state.appearance.colorScheme)
                .overlay(alignment: .top) {
                    ErrorBanner()
                        .environment(\.theme, theme)
                        .environment(state)
                        .animation(.easeOut(duration: 0.25), value: state.lastError)
                }
                .sheet(item: $flowSheet) { which in
                    sheetContent(which)
                        .modifier(EnvBundle(theme: theme, state: state, api: api, push: push, session: session, iap: iap, subs: subs, mailStore: mailStore, calls: calls))
                        .presentationDetents(which.detents)
                        .presentationDragIndicator(.visible)
                        .presentationBackground(theme.bg)
                }
                // The cover's own copy of the call screen. Without it a call
                // arriving while ANY cover is open — a thread, a checkout, the
                // dialer itself — is rendered underneath that cover and cannot
                // be seen or ended.
                .overlay {
                    if calls.isLive {
                        InCallOverlay()
                            .environment(\.theme, theme)
                            .environment(calls)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.22), value: calls.isLive)
        }
    }

    @ViewBuilder
    private func flowContent(_ stage: FlowStage) -> some View {
        switch stage {
        case .checkout:
            CheckoutScreen(
                openServices: { flowSheet = .services },
                openCountries: { flowSheet = .country },
                openCredits: { flowSheet = .credits }
            )
        case .waiting:
            if let order = state.activeOrder {
                WaitingScreen(order: order)
            } else { emptyFlow }
        case .otp:
            if let order = state.activeOrder {
                OtpScreen(order: order)
            } else { emptyFlow }
        case .recovery:
            if let ctx = state.recovery {
                RecoveryScreen(context: ctx)
            } else { emptyFlow }
        case .esimCheckout:
            EsimCheckoutScreen(openCredits: { flowSheet = .credits })
        case .esimDetail:
            if let order = state.activeEsimOrder {
                EsimDetailScreen(order: order)
            } else { emptyFlow }
        case .emailWaiting:
            EmailWaitingScreen()
        case .emailCode:
            EmailCodeScreen()
        // The rented line's covers land with the purchase, messaging and voice
        // steps. They are routed rather than omitted because `ThreadRow`
        // already assigns `flow = .thread`, and because a cover with no case
        // presents `emptyFlow` — a blank screen with no way out, which is the
        // exact failure the eSIM empty state was rebuilt to avoid.
        case .lineStoreMore:
            // The same store, presented as a cover so it inherits EnvBundle —
            // covers do NOT reliably inherit @Observable env objects, which is
            // the trap this app wraps every cover for.
            LineStoreScreen(onOpenSms: { state.flow = nil; state.tab = .temp },
                            onClose: { state.flow = nil })
        case .lineCheckout:
            LineCheckoutScreen()
        case .lineProvisioning:
            LineProvisioningScreen()
        case .thread:
            ThreadScreen()
        case .compose:
            ComposeScreen()
        case .orders:
            // Was a tab until 2026-08-06. As a cover it needs its own way out,
            // which a tab never did — the tab bar WAS the way out.
            OrdersScreen(openCredits: { flowSheet = .credits },
                         onClose: { state.flow = nil })
        case .dialer:
            // Still gated on a real WebRTC client being attached, even though
            // `TelnyxVoiceClient` is now wired in `AuthGate`. The guard is what
            // keeps a build that loses the SDK — or any future path that falls
            // back to `NullVoiceClient` — from showing a keypad whose every
            // call fails. Ship the plumbing, never the dead button.
            if calls.isVoiceAvailable {
                DialerScreen()
            } else {
                // Calling SHIPPED on 2026-08-06, so "coming soon" would now be
                // wrong. This branch is doubly unreachable — `AuthGate` always
                // attaches a real client, and the button that sets
                // `flow = .dialer` is hidden when it has not — but a fallback
                // that lies is worse than no fallback.
                comingSoonFlow("Calling isn't available in this build.")
            }
        }
    }

    /// The line that can currently RECEIVE, if any.
    ///
    /// `canReceive`, not `canSend`: a `past_due` number still rings, and the
    /// user does not control who calls them. Identity rather than a Bool so
    /// swapping a number also re-registers.
    private var receivingLineId: String? {
        state.lines.first(where: { $0.status.canReceive })?.id
    }

    /// Hold a Telnyx session exactly while the user holds a number that rings.
    private func connectVoiceIfLineIsLive() async {
        guard calls.isVoiceAvailable, !calls.isLive else { return }
        guard let id = receivingLineId else {
            // Nothing to receive on. Drop the session and the stored
            // credential rather than remaining a push target for a number that
            // is no longer ours.
            await calls.releaseVoice()
            return
        }
        // Only when nothing has claimed it: `LineScreen` sets this to the line
        // actually on screen, and that choice must win.
        if calls.activeLineId == nil { calls.activeLineId = id }
        await calls.prepareVoice()
    }

    private var emptyFlow: some View {
        ZStack { theme.bg.ignoresSafeArea() }
    }

    /// A placeholder that SAYS what it is and can always be dismissed. Deleted
    /// case by case as each screen lands.
    private func comingSoonFlow(_ message: LocalizedStringKey) -> some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: RIcon.phone)
                    .font(.system(size: 30)).foregroundStyle(theme.text3)
                Text(message)
                    .font(RFont.text(15))
                    .foregroundStyle(theme.text2)
                    .multilineTextAlignment(.center)
                GhostButton(label: "Close", fillsWidth: false) { state.flow = nil }
            }
            .padding(.horizontal, 40)
        }
    }

    @ViewBuilder
    private func sheetContent(_ which: ActiveSheet) -> some View {
        @Bindable var s = state
        switch which {
        case .services:
            ServiceSheet(onPick: { picked in state.commitServicePick(picked) })
        case .country:
            CountrySheet(onPick: { picked in
                if state.flow == .checkout {
                    state.checkoutCountry = picked
                    // Recomputed for the new route — see the note in
                    // `AppState.commitServicePick`.
                    state.checkoutPremium = state.defaultPremium(
                        for: state.configuringService, country: picked)
                } else { state.lastCountry = picked }
                // The user has now CHOSEN a country. Until this fires the
                // Home row reads "Not selected" and `placeOrder` refuses —
                // see `AppState.needsCountryChoice`.
                state.needsCountryChoice = false
            })
        case .credits:
            CreditsSheet(balance: state.balance, needed: state.creditsShortfall, onPurchased: {
                // Awaited before the sheet dismisses, so the balance the user
                // returns to is the balance they just paid for.
                await state.refreshWallet(using: WalletAPI(client: api))
                if let n = iap.lastGrantedCredits, n > 0 {
                    state.creditPurchaseBanner = n
                }
            })
        case .emailDomain:
            EmailDomainSheet(onPick: { picked in
                state.emailDomain = picked
                // Declare the intent here too: the credits pill can be opened
                // from Home with flow == nil, and creditsShortfall must size for
                // the email price rather than the SMS route behind it.
                state.intent = .email
            })
        }
    }
}

#if DEBUG
extension ContentView {
    /// Puts the app directly into the state a given screenshot needs.
    ///
    /// One launch per screen, no taps: simulator UI automation is not available
    /// here, and a scripted tap sequence is the part of a screenshot pipeline
    /// that rots first. Each frame is instead reproducible from its launch
    /// argument alone.
    ///
    /// Compiled out of Release entirely — see `ScreenshotMode`.
    func applyScreenshotState(_ shot: ScreenshotMode.Screen) {
        // The catalog is seeded rather than fetched, so a frame does not change
        // because a provider repriced something this morning.
        state.continueWithoutCatalog()      // lifts the splash; bootPhase is private(set)
        state.balance = 42

        switch shot {
        case .onboarding:
            break                              // handled before the gate

        case .lineIntro, .lineStore, .linePaywall, .linePaywallYearly:
            state.tab = .line
            state.lines = []                   // not yet a subscriber
            // The pitch prices the switch from `app_config.line_swap_credits`,
            // which `simctl` never fetches. Fixture only — the LIVE value is
            // the server's; 8 is what it read on 2026-09-01.
            state.appStatus = AppStatus(announcement: nil, esimPaused: false, lineSwapCredits: 8)
            if shot == .lineStore {
                // The store prints the monthly price (see
                // `LineStoreScreen.priceNote`), and it renders NOTHING until
                // StoreKit answers — which `simctl` never makes it do, because
                // it does not apply the scheme's StoreKit configuration. Same
                // shim, same reason, as the paywall frames below.
                subs.screenshotPricing = .init()
                // The store is ONE screen as of 2026-09-03, so this frame is
                // the numbers themselves rather than a city list — and the
                // search that would fill them is skipped in screenshot mode
                // (see `LineStoreScreen`'s root task), so the offers are
                // seeded here or the frame renders its empty state.
                //
                // ⚠️ 555 numbers, as everywhere in this harness: a screenshot
                // is marketing, and a plausible real number would be both a
                // claim and, if it ever belonged to someone, a leak.
                // The US, country-wide, since 2026-09-06: that is what every
                // untouched store opens on (see `LineStoreScreen.defaultCountry`),
                // so the frame shows the state a real reader lands in. No city
                // — the US has no curated localities and sells country-wide.
                state.lineCountry = "US"
                // The three sellable countries, so the chip row above the
                // numbers renders all three; `simctl` never fetches the menu.
                state.lineCountries = LineCountry.seeded + [
                    .init(countryCode: "PR", countryName: "Puerto Rico",
                          supportsVoice: true, supportsSms: true, supportsMms: true,
                          supportsEmergency: true, available: true, sellReason: nil,
                          hasLocalities: true),
                ]
                // New York, as the live default search lands (first curated
                // US locality), so the label reads as it does for a real user.
                state.lineCities = [
                    .init(id: "new-york", label: "New York"),
                    .init(id: "los-angeles", label: "Los Angeles"),
                    .init(id: "chicago", label: "Chicago"),
                ]
                state.lineCity = "new-york"
                state.lineOffers = [
                    LineNumberOffer(phoneNumber: "+12125550128",
                                    region: "New York, NY",
                                    monthlyCents: 100, upfrontCents: 100,
                                    countryCode: "US"),
                    LineNumberOffer(phoneNumber: "+13105550164",
                                    region: "Los Angeles, CA",
                                    monthlyCents: 100, upfrontCents: 100,
                                    countryCode: "US"),
                    LineNumberOffer(phoneNumber: "+13125550193",
                                    region: "Chicago, IL",
                                    monthlyCents: 100, upfrontCents: 100,
                                    countryCode: "US"),
                ]
            }
            if shot == .linePaywall || shot == .linePaywallYearly {
                state.lineCity = "toronto"
                state.lineOffer = LineNumberOffer(phoneNumber: "+14375550128",
                                                  region: "Toronto, Ontario",
                                                  monthlyCents: 100,
                                                  upfrontCents: 100)
                state.flow = .lineCheckout
                // Without this the paywall renders its "temporarily
                // unavailable" state: `simctl` does not apply the scheme's
                // StoreKit configuration, so no products load. See
                // `SubscriptionStore.ScreenshotPricing`.
                subs.screenshotPricing = .init()
                subs.selectedPlan = shot == .linePaywallYearly ? .yearly : .monthly
            }

        case .mailPaywall, .mailPaywallYearly:
            // The e-mail line, not the number line, so the tab behind the
            // sheet is Temp in e-mail mode — the surface this paywall is
            // actually raised from (`confirmGetEmail` refusing a second free
            // address with `subscription_required`).
            state.tab = .temp
            state.emailMode = true
            // Presented as a plain `.sheet(isPresented:)` rather than through
            // `ActiveSheet`, because that is how the real screen is raised —
            // see the note at the presentation site.
            state.showMailPaywall = true
            // Without this the paywall renders its "isn't offering this
            // subscription right now" state with no plan rows and no CTA:
            // `simctl` does not apply the scheme's StoreKit configuration, so
            // no products load. Same shim, same reason, as the line paywall
            // above. See `MailSubscriptionStore.ScreenshotPricing` — the
            // figures in it are the LIVE App Store Connect prices, not
            // placeholders.
            mailStore.screenshotPricing = .init()
            mailStore.selectedPlan = shot == .mailPaywallYearly ? .yearly : .monthly

        case .lineInbox:
            state.tab = .line
            state.lines = [ScreenshotMode.sampleLine]
            state.lineThreads = ScreenshotMode.sampleThreads
            // "Switch number · N credits" renders only with a live price;
            // see the `.lineIntro` note above.
            state.appStatus = AppStatus(announcement: nil, esimPaused: false, lineSwapCredits: 8)

        case .thread:
            state.tab = .line
            state.lines = [ScreenshotMode.sampleLine]
            state.lineThreads = ScreenshotMode.sampleThreads
            state.lineMessages = ["t1": ScreenshotMode.sampleMessages]
            state.openThreadId = "t1"
            state.flow = .thread

        // The Home TAB, with no line: the three need-cards, the service grid,
        // How it works, and the invite card.
        case .homeRouter:
            state.tab = .home
            state.lines = []
            // Names the greeting and fills the invite card. Both halves are
            // needed: `HomeScreen.inviteCard` renders only when
            // `inviteMessage` AND `referralCode` are non-nil, and
            // `greetingName` refuses a name that is merely the e-mail handle,
            // so a profile without a real `displayName` shows the nameless
            // greeting instead.
            state.profile = ScreenshotMode.sampleProfile
            // `orders` stays EMPTY on purpose: this frame is the first-run
            // state, and it is the How-it-works branch that belongs in it.
            state.orders = []
            state.emailOrders = []
            // The number card prints the monthly price from StoreKit, and
            // `simctl` never applies the scheme's StoreKit configuration —
            // same shim, same reason, as the store and paywall frames.
            subs.screenshotPricing = .init()

        // The Home TAB for a subscriber: the line card on top, then the two
        // temp cards. The number card is absent by construction.
        case .homeLine:
            state.tab = .home
            state.lines = [ScreenshotMode.sampleLine]
            state.lineThreads = ScreenshotMode.sampleThreads
            // 🔴 Required, and its absence is INVISIBLE rather than empty:
            // `HomeScreen.hasLine` is gated on `linesLoaded` (the anti-flash
            // rule), so seeding `lines` alone renders the frame as if the user
            // had no number — the router state under the subscriber's name.
            // The other line frames do not need it; they read `lines` directly.
            state.linesLoaded = true
            state.profile = ScreenshotMode.sampleProfile
            // Recent, with one delivered code and one order still running —
            // the two states the trailing edge of that row can be in.
            //
            // 🔴 `resolve` binds the Service and Country ONCE, from whatever
            // catalog is loaded at THIS instant — and the cold-start chain is
            // skipped above, so that is `SeedData`. The live catalog arriving a
            // second later via the scenePhase refresh does not re-resolve these
            // rows. Every id here must therefore exist in BOTH, or the row
            // renders the fallback pair: a grey "Service" tile under a globe.
            //
            // ⚠️ `uk`, not `gb`. `gb` is the ISO code, and
            // `Country.flagImageCode` maps `uk` onto it for the flag PNG — but
            // the catalog's country ID is `uk` in `SeedData` AND in production
            // (queried 2026-09-10: `gb` returns no row).
            state.orders = [
                state.resolve(ScreenshotMode.sampleOrder(
                    status: .received, otp: "482913", id: "sample-1",
                    serviceId: "whatsapp", countryId: "us", ageSeconds: 7_200)),
                state.resolve(ScreenshotMode.sampleOrder(
                    status: .waiting, otp: nil, id: "sample-2",
                    serviceId: "google", countryId: "uk", ageSeconds: 40)),
            ]
            subs.screenshotPricing = .init()

        // ⚠️ NOT the Home tab. `.home` is the temp-SMS store's frame and its
        // raw value is a FILENAME that `scripts/screenshots/make-set.py`
        // filters on, so it keeps the name and keeps pointing at `.temp`.
        case .home:
            state.tab = .temp
            // Pin a pair that PUBLISHES a network rate, so the frame shows the
            // delivery figure the whole picker is built around. The default
            // pair may publish nothing, and a store screenshot with a blank
            // where the rate goes sells the opposite of the feature.
            //
            // leboncoin/Austria measured 5 credits at 87% on 2026-08-06 — a
            // real, bookable pair. The figure is NOT hardcoded here; it is
            // whatever the route publishes at capture time, so the frame
            // cannot claim a rate the catalog does not.
            //
            // ⚠️ leboncoin is not in `SeedData`, so this has to await the
            // fetch. Which is possible because the catalog is FETCHED here,
            // not seeded — `routes` carries a `public read` policy, so the
            // publishable key alone is enough. See the corrected note at the
            // call site.
            Task { @MainActor in
                await state.loadCatalog(using: CatalogAPI(client: api))
                if let svc = state.services.first(where: { $0.id == "leboncoin" }) {
                    state.lastService = svc
                }
                if let cty = state.countries.first(where: { $0.id == "at" }) {
                    state.lastCountry = cty
                }
                // Home's Recent section renders from `orders`, so without this
                // the frame collapsed it entirely and looked like the feature
                // was gone. Seeded AFTER the catalog so each row resolves its
                // real service logo and flag.
                //
                // 🔴 Seeded, never fetched. `loadOrders` is gated in screenshot
                // mode on purpose: the account these run against is the dev
                // account, and letting it through would publish real order
                // history — real numbers, real codes — into an App Store frame.
                state.orders = ScreenshotMode.sampleOrderRows.map(state.resolve)
            }

        // ⚠️ These three set REAL STATE now. Until 2026-08-06 the whole group
        // set only `tab`, so `waiting` and `code` were byte-identical captures
        // of the Home screen and `orders` was an empty state — three frames
        // that had never once shown what their names claim. Caught by checksum,
        // not by eye: the files looked plausible.
        case .waiting:
            state.tab = .temp
            state.activeOrder = state.resolve(
                ScreenshotMode.sampleOrder(status: .waiting, otp: nil))
            state.flow = .waiting

        case .code:
            state.tab = .temp
            state.activeOrder = state.resolve(
                ScreenshotMode.sampleOrder(status: .received, otp: "123456"))
            state.flow = .otp

        case .orders:
            state.tab = .temp
            state.orders = ScreenshotMode.sampleOrderRows.map(state.resolve)
            state.flow = .orders

        case .credits:
            state.tab = .temp
            // A modest balance, so the sheet leads with the balance card rather
            // than a shortfall context that would tie the frame to one route's
            // price. `creditsShortfall` is 0 here — the seeded catalog has no
            // route for the default pair — so no pack is preselected and the
            // sheet opens on MOST POPULAR, which is the frame we want.
            state.balance = 5
            // Without this every row renders "Unavailable" over a disabled CTA:
            // `simctl` does not apply the scheme's StoreKit configuration, so
            // no products load. It also keeps the `optional` credits.8 pack in
            // the ladder — an IAP review screenshot has to show the very pack
            // being reviewed, and that is exactly the one StoreKit would omit.
            //
            // ⚠️ The LIVE App Store Connect tiers, not placeholders. See
            // `IAPStore.screenshotPricing`.
            iap.screenshotPricing = [
                "com.anthersystems.VirtualSIM.credits.5":   "$2.99",
                "com.anthersystems.VirtualSIM.credits.8":   "$3.99",
                "com.anthersystems.VirtualSIM.credits.12":  "$5.49",
                "com.anthersystems.VirtualSIM.credits.30":  "$12.99",
                "com.anthersystems.VirtualSIM.credits.60":  "$24.99",
                "com.anthersystems.VirtualSIM.credits.150": "$59.99",
            ]
            sheet = .credits

        case .email:
            state.tab = .temp
            state.emailMode = true
            state.activeEmailOrder = ScreenshotMode.sampleEmailOrder
            // The real flow inserts the order into `emailOrders` before it
            // opens this screen, and `hasUsedFreeEmail` reads that list — so
            // without this the frame renders the "you still have a free one"
            // card instead of the state a user actually arrives in.
            state.emailOrders = [ScreenshotMode.sampleEmailOrder]
            // Same shim, same reason, as the paywall frames: `simctl` does not
            // apply the scheme's StoreKit configuration, so the plan price on
            // the card below Done would otherwise never load.
            mailStore.screenshotPricing = .init()
            state.flow = .emailCode

        case .emailStore:
            // The e-mail line's own screen, not its code screen. The delivered
            // code frame is nearly identical to the SMS one — same big digits,
            // same Done button — so on its own it does not show that a second
            // product exists at all.
            state.tab = .temp
            state.emailMode = true
            state.emailDomains = ScreenshotMode.sampleEmailDomains
            state.emailDomain = ScreenshotMode.sampleEmailDomains.first
            Task { @MainActor in
                await state.loadCatalog(using: CatalogAPI(client: api))
                if let svc = state.services.first(where: { $0.id == "leboncoin" }) {
                    state.lastService = svc
                }
            }
        }
    }
}
#endif

/// Bundles every environment object the app's screens read.
/// Applied to sheet + cover contents so they don't inherit-by-accident from
/// the presenter (which doesn't always work for @Observable in SwiftUI).
private struct EnvBundle: ViewModifier {
    let theme: Theme
    let state: AppState
    let api: APIClient
    let push: PushManager
    let session: Session
    let iap: IAPStore
    let subs: SubscriptionStore
    let mailStore: MailSubscriptionStore
    /// Required here specifically: the dialer is presented INSIDE the flow
    /// cover, and a cover's content does not inherit `@Observable` environment
    /// objects from its presenter — which is the whole reason this modifier
    /// exists. Omitting it crashes the dialer on presentation rather than
    /// failing gracefully.
    let calls: CallController

    func body(content: Content) -> some View {
        content
            .environment(\.theme, theme)
            .environment(state)
            .environment(api)
            .environment(push)
            .environment(session)
            .environment(iap)
            .environment(subs)
            .environment(mailStore)
            .environment(calls)
    }
}

#Preview("Temp — Light") {
    ContentView()
}

#Preview("Temp — Dark") {
    ContentView()
        .preferredColorScheme(.dark)
}
