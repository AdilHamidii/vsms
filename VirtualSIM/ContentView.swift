import SwiftUI

enum ActiveSheet: String, Identifiable {
    case services, country, credits
    var id: String { rawValue }
}

struct ContentView: View {
    @Environment(APIClient.self) private var api
    @Environment(PushManager.self) private var push
    @Environment(\.scenePhase) private var scenePhase

    @State private var state = AppState()
    @State private var sheet: ActiveSheet?

    private var theme: Theme { state.isDark ? .dark : .light }

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
        .overlay(alignment: .top) {
            ErrorBanner()
                .animation(.easeOut(duration: 0.25), value: state.lastError)
        }
        .environment(\.theme, theme)
        .environment(state)
        .preferredColorScheme(state.isDark ? .dark : .light)
        .task {
            await state.loadCatalog(using: CatalogAPI(client: api))
            await state.refreshWallet(using: WalletAPI(client: api))
            await state.refreshProfile(using: ProfileAPI(client: api))
            await state.loadOrders(using: OrdersAPI(client: api))
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
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
                .environment(\.theme, theme)
                .environment(state)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(theme.bg)
        }
        .fullScreenCover(item: $state.flow) { stage in
            flowContent(stage)
                .environment(\.theme, theme)
                .environment(state)
                .preferredColorScheme(state.isDark ? .dark : .light)
                .overlay(alignment: .top) {
                    ErrorBanner()
                        .animation(.easeOut(duration: 0.25), value: state.lastError)
                }
                .sheet(item: $sheet) { which in
                    sheetContent(which)
                        .environment(\.theme, theme)
                        .environment(state)
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
                openServices: { sheet = .services },
                openCountries: { sheet = .country },
                openCredits: { sheet = .credits }
            )
        case .waiting:
            if let order = state.activeOrder {
                WaitingScreen(order: order)
            } else { emptyFlow }
        case .otp:
            if let order = state.activeOrder {
                OtpScreen(order: order)
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
                if state.flow == .checkout { state.checkoutService = picked }
                else { state.lastService = picked }
            })
        case .country:
            CountrySheet(filter: state.filter, onPick: { picked in
                if state.flow == .checkout { state.checkoutCountry = picked }
                else { state.lastCountry = picked }
            })
        case .credits:
            CreditsSheet(balance: state.balance, onPurchased: {
                Task { await state.refreshWallet(using: WalletAPI(client: api)) }
            })
        }
    }
}

#Preview("Home — Light") {
    ContentView()
}

#Preview("Home — Dark") {
    ContentView()
        .preferredColorScheme(.dark)
}
