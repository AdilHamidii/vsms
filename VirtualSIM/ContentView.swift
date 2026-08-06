import SwiftUI

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
    @Environment(\.scenePhase) private var scenePhase

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
                case .line:
                    LineScreen(onOpenSms: { state.tab = .home })
                case .home:
                    HomeScreen(
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
                        onSeeAllOrders: { state.tab = .orders },
                        onOpenEsim: { state.tab = .esim }
                    )
                case .esim:
                    EsimStoreScreen(openCredits: { sheet = .credits })
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
        .overlay {
            if calls.isLive {
                InCallOverlay()
                    .environment(\.theme, theme)
                    .environment(calls)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.22), value: calls.isLive)
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
            // Screenshots run offline against seeded data, so the cold-start
            // chain is skipped entirely — six sequential fetches would either
            // fail without a real token or make each frame depend on whatever
            // the catalog happens to hold today. See `ScreenshotMode`.
            if let shot = ScreenshotMode.screen {
                applyScreenshotState(shot)
                return
            }
            #endif
            // The whole cold-launch sequence, including which steps must finish
            // before the splash lifts. See AppState.coldStart.
            await state.coldStart(api: api)

            // StoreKit prices, BEHIND the reveal — nothing on Home waits for
            // them, but Home cannot render its money line without them.
            //
            // `iap.products` had exactly three writers, all inside CreditsSheet
            // or `purchase()`, and `IAPStore.attach` only restores. So the "5 cr
            // · about $2.50" line — which exists precisely because "cr" is
            // otherwise undefined anywhere on that screen — rendered nothing
            // until the user had opened the paywall at least once. `iap` is
            // `@State` in `AuthGate`, so that was true on EVERY cold launch,
            // not just the first: exactly the population for whom the unit is
            // meaningless.
            await iap.loadProducts()
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
                if state.intent == .line { state.intent = .sms }
            }
        }
        .onChange(of: scenePhase) { _, phase in
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
                }
            }
        }
        // Tapping an inbound-text push opens that conversation. Sets the tab
        // too: the thread cover renders over whatever tab is behind it, and
        // closing it should land the user on their number rather than back on
        // an unrelated product.
        .onChange(of: push.pendingLineThreadId) { _, newValue in
            guard let threadId = newValue else { return }
            push.pendingLineThreadId = nil
            Task {
                await state.loadLineThreads(using: LineAPI(client: api))
                state.tab = .line
                state.intent = .line
                state.openThreadId = threadId
                state.flow = .thread
            }
        }
        .onChange(of: push.pendingOrderId) { _, newValue in
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
                .modifier(EnvBundle(theme: theme, state: state, api: api, push: push, session: session, iap: iap, subs: subs, calls: calls))
                .presentationDetents(which.detents)
                .presentationDragIndicator(.visible)
                .presentationBackground(theme.bg)
        }
        .fullScreenCover(item: $state.flow) { stage in
            flowContent(stage)
                .modifier(EnvBundle(theme: theme, state: state, api: api, push: push, session: session, iap: iap, subs: subs, calls: calls))
                .preferredColorScheme(state.appearance.colorScheme)
                .overlay(alignment: .top) {
                    ErrorBanner()
                        .environment(\.theme, theme)
                        .environment(state)
                        .animation(.easeOut(duration: 0.25), value: state.lastError)
                }
                .sheet(item: $flowSheet) { which in
                    sheetContent(which)
                        .modifier(EnvBundle(theme: theme, state: state, api: api, push: push, session: session, iap: iap, subs: subs, calls: calls))
                        .presentationDetents(which.detents)
                        .presentationDragIndicator(.visible)
                        .presentationBackground(theme.bg)
                }
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
        case .lineCheckout:
            LineCheckoutScreen()
        case .lineProvisioning:
            LineProvisioningScreen()
        case .thread:
            ThreadScreen()
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
            ServiceSheet(onPick: { picked in
                // Show + steer: land the freshly-picked service on a country
                // we've SEEN deliver. Without evidence, bestCountry keeps the
                // current selection — the sheet priced every row for it, and a
                // silent swap made the buy button contradict the tapped row.
                // Via pickDestination, NOT bestCountry directly: the row the
                // user just tapped printed its answer ("5 cr in Romania"), and
                // the two must be the same call or the promise breaks.
                let best = state.pickDestination(for: picked)?.country
                if state.flow == .checkout {
                    state.checkoutService = picked
                    if let best { state.checkoutCountry = best }
                    // Real SIM is a per-ROUTE choice, so it is RECOMPUTED for
                    // the new route, never carried over. Left set across a
                    // route change it stranded checkout: the tier chips vanish
                    // when the new route has no premium price, the Cost row
                    // silently shows the STANDARD price, the receipt still
                    // claims "Real carrier", and Get number then fails with
                    // "Real-SIM numbers just sold out here. Try Standard" —
                    // with no Standard chip on screen to tap. The only escape
                    // was backing out of checkout entirely.
                    // `defaultPremium` returns false whenever the new route has
                    // no premium price, so that invariant still holds.
                    state.checkoutPremium = state.defaultPremium(
                        for: picked, country: best ?? state.configuringCountry)
                } else {
                    state.lastService = picked
                    if let best { state.lastCountry = best }
                }
            })
        case .country:
            CountrySheet(onPick: { picked in
                if state.flow == .checkout {
                    state.checkoutCountry = picked
                    // Recomputed for the new route — see note above.
                    state.checkoutPremium = state.defaultPremium(
                        for: state.configuringService, country: picked)
                } else { state.lastCountry = picked }
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

        case .lineStore, .linePaywall:
            state.tab = .line
            state.lines = []                   // not yet a subscriber
            if shot == .linePaywall {
                state.lineCity = "toronto"
                state.lineOffer = LineNumberOffer(phoneNumber: "+14375550128",
                                                  region: "Toronto, Ontario",
                                                  monthlyCents: 100,
                                                  upfrontCents: 100)
                state.flow = .lineCheckout
            }

        case .lineInbox:
            state.tab = .line
            state.lines = [ScreenshotMode.sampleLine]
            state.lineThreads = ScreenshotMode.sampleThreads

        case .home:
            state.tab = .home

        case .waiting, .code, .orders:
            state.tab = shot == .orders ? .orders : .home
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
            .environment(calls)
    }
}

#Preview("Home — Light") {
    ContentView()
}

#Preview("Home — Dark") {
    ContentView()
        .preferredColorScheme(.dark)
}
