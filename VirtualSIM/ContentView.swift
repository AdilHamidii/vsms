import SwiftUI

enum ActiveSheet: String, Identifiable {
    case services, country, credits
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

    private var theme: Theme {
        state.isDark ? .dark(state.accent) : .light(state.accent)
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
                        openCredits: { sheet = .credits },
                        onStart: { state.startCheckout() },
                        onTapOrder: { o in
                            if o.status == .waiting {
                                state.activeOrder = o
                                state.flow = .waiting
                            } else {
                                state.buyAgain(o)
                            }
                        },
                        onSeeAllOrders: { state.tab = .orders }
                    )
                case .esim:
                    EsimStoreScreen(openCredits: { sheet = .credits })
                case .orders:
                    OrdersScreen(openCredits: { sheet = .credits })
                case .account:
                    AccountScreen(openCredits: { sheet = .credits })
                }
            }

            TabBar(tab: $state.tab)
                .padding(.horizontal, 12)
                .padding(.bottom, 28)
        }
        // Environment first, THEN overlay/sheet/cover — so banner + cover
        // content all see AppState in scope.
        .environment(\.theme, theme)
        .environment(state)
        .preferredColorScheme(state.isDark ? .dark : .light)
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
        .task {
            await state.refreshMaintenance(using: MaintenanceAPI(client: api))
            await state.loadCatalog(using: CatalogAPI(client: api))
            await state.refreshWallet(using: WalletAPI(client: api))
            await state.refreshProfile(using: ProfileAPI(client: api))
            await state.loadOrders(using: OrdersAPI(client: api))
            // Cold launch only: hand back an order that was mid-flight when
            // the app was killed, instead of stranding a paid wait.
            state.resumeInFlightOrder()
            state.applyStartupSelection()
            await state.loadEsimCatalog(using: EsimPlansAPI(client: api))
            await state.loadEsimOrders(using: EsimOrdersAPI(client: api))
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    // Re-fetch catalog too so server-side sync-prices runs
                    // show up without an app reinstall / force-quit.
                    await state.refreshMaintenance(using: MaintenanceAPI(client: api))
                    await state.loadCatalog(using: CatalogAPI(client: api))
                    await state.refreshWallet(using: WalletAPI(client: api))
                    await state.loadOrders(using: OrdersAPI(client: api))
                }
            }
        }
        .onChange(of: push.pendingOrderId) { _, newValue in
            guard let orderId = newValue else { return }
            push.pendingOrderId = nil
            Task {
                await state.loadOrders(using: OrdersAPI(client: api))
                if let order = state.orders.first(where: { $0.id == orderId }) {
                    state.activeOrder = order
                    state.flow = .otp
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
                .preferredColorScheme(state.isDark ? .dark : .light)
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
                let best = state.bestCountry(for: picked,
                                             keeping: state.checkoutCountry ?? state.lastCountry)
                if state.flow == .checkout {
                    state.checkoutService = picked
                    if let best { state.checkoutCountry = best }
                } else {
                    state.lastService = picked
                    if let best { state.lastCountry = best }
                }
            })
        case .country:
            CountrySheet(onPick: { picked in
                if state.flow == .checkout { state.checkoutCountry = picked }
                else { state.lastCountry = picked }
            })
        case .credits:
            CreditsSheet(balance: state.balance, needed: state.creditsShortfall, onPurchased: {
                Task { await state.refreshWallet(using: WalletAPI(client: api)) }
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
