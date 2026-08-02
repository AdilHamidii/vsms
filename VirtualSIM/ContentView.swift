import SwiftUI

enum ActiveSheet: String, Identifiable {
    case services, country, credits, emailDomain
    var id: String { rawValue }
}

struct ContentView: View {
    @Environment(APIClient.self) private var api
    @Environment(PushManager.self) private var push
    @Environment(Session.self) private var session
    @Environment(IAPStore.self) private var iap
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
                TabBar(tab: $state.tab)
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
            // The whole cold-launch sequence, including which steps must finish
            // before the splash lifts. See AppState.coldStart.
            await state.coldStart(api: api)
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
            Task { await state.loadEmailDomains(using: EmailAPI(client: api)) }
        }
        .onChange(of: state.lastService.id) { _, _ in
            guard state.emailMode else { return }
            Task { await state.loadEmailDomains(using: EmailAPI(client: api)) }
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
                .modifier(EnvBundle(theme: theme, state: state, api: api, push: push, session: session, iap: iap))
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(theme.bg)
        }
        .fullScreenCover(item: $state.flow) { stage in
            flowContent(stage)
                .modifier(EnvBundle(theme: theme, state: state, api: api, push: push, session: session, iap: iap))
                .preferredColorScheme(state.appearance.colorScheme)
                .overlay(alignment: .top) {
                    ErrorBanner()
                        .environment(\.theme, theme)
                        .environment(state)
                        .animation(.easeOut(duration: 0.25), value: state.lastError)
                }
                .sheet(item: $flowSheet) { which in
                    sheetContent(which)
                        .modifier(EnvBundle(theme: theme, state: state, api: api, push: push, session: session, iap: iap))
                        .presentationDetents([.large])
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
        }
    }

    private var emptyFlow: some View {
        ZStack { theme.bg.ignoresSafeArea() }
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

    func body(content: Content) -> some View {
        content
            .environment(\.theme, theme)
            .environment(state)
            .environment(api)
            .environment(push)
            .environment(session)
            .environment(iap)
    }
}

#Preview("Home — Light") {
    ContentView()
}

#Preview("Home — Dark") {
    ContentView()
        .preferredColorScheme(.dark)
}
