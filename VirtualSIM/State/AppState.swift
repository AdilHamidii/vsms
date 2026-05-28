import SwiftUI

enum AppTab: String, Hashable, CaseIterable {
    case home, orders, account
}

enum FlowStage: String, Hashable, Identifiable {
    case checkout, waiting, otp
    var id: String { rawValue }
}

private enum PrefKey {
    static let isDark           = "pref.isDark"
    static let waitingAnimation = "pref.waitingAnimation"
    static let otpAnimation     = "pref.otpAnimation"
    static let showMetrics      = "pref.showMetrics"
}

@Observable
final class AppState {
    var tab: AppTab = .home
    var balance: Int = 0
    var services: [Service] = SeedData.services
    var countries: [Country] = SeedData.countries
    var routes: [Route] = []
    var lastService: Service
    var lastCountry: Country
    var orders: [Order] = []
    var filter: SortFilter = .all
    var profile: Profile?

    var flow: FlowStage?
    var checkoutService: Service?
    var checkoutCountry: Country?
    var activeOrder: Order?

    var isDark: Bool {
        didSet { UserDefaults.standard.set(isDark, forKey: PrefKey.isDark) }
    }
    var waitingAnimation: WaitingAnimation {
        didSet { UserDefaults.standard.set(waitingAnimation.rawValue, forKey: PrefKey.waitingAnimation) }
    }
    var otpAnimation: OtpAnimation {
        didSet { UserDefaults.standard.set(otpAnimation.rawValue, forKey: PrefKey.otpAnimation) }
    }
    var showMetrics: Bool {
        didSet { UserDefaults.standard.set(showMetrics, forKey: PrefKey.showMetrics) }
    }

    init() {
        self.lastService = SeedData.services.first ?? AppState.fallbackService
        self.lastCountry = SeedData.countries.first ?? AppState.fallbackCountry

        let defaults = UserDefaults.standard
        self.isDark = defaults.bool(forKey: PrefKey.isDark)
        self.waitingAnimation = WaitingAnimation(
            rawValue: defaults.string(forKey: PrefKey.waitingAnimation) ?? ""
        ) ?? .pulse
        self.otpAnimation = OtpAnimation(
            rawValue: defaults.string(forKey: PrefKey.otpAnimation) ?? ""
        ) ?? .cascade
        self.showMetrics = defaults.object(forKey: PrefKey.showMetrics) as? Bool ?? true
    }

    var deliveredCount: Int { orders.filter { $0.status == .received }.count }

    func buy(_ pack: CreditPack) {
        balance += pack.credits
    }

    func refreshWallet(using api: WalletAPI) async {
        do {
            balance = try await api.currentWallet().balance
        } catch {
            // Phase F adds proper error UI.
        }
    }

    func refreshProfile(using api: ProfileAPI) async {
        profile = try? await api.currentProfile()
    }

    func loadCatalog(using api: CatalogAPI) async {
        do {
            let catalog = try await api.fetch()
            services = catalog.services
            countries = catalog.countries
            routes = catalog.routes

            if let match = services.first(where: { $0.id == lastService.id }) {
                lastService = match
            } else if let first = services.first {
                lastService = first
            }
            if let match = countries.first(where: { $0.id == lastCountry.id }) {
                lastCountry = match
            } else if let first = countries.first {
                lastCountry = first
            }
        } catch {
            // Keep seed fallbacks visible if catalog fetch fails.
        }
    }

    func startCheckout(service: Service? = nil, country: Country? = nil) {
        checkoutService = service ?? lastService
        checkoutCountry = country ?? lastCountry
        flow = .checkout
    }

    func confirmGetNumber() {
        guard let svc = checkoutService, let cty = checkoutCountry else { return }
        guard balance >= svc.cost else { return }
        balance -= svc.cost
        lastService = svc
        lastCountry = cty
        let order = Order(
            id: "o-live-\(Int(Date().timeIntervalSince1970 * 1000))",
            service: svc, country: cty,
            number: NumberGenerator.phoneNumber(for: cty),
            otp: nil, status: .waiting, ago: "now"
        )
        activeOrder = order
        orders.insert(order, at: 0)
        flow = .waiting
    }

    func simulateArrival() {
        guard var order = activeOrder else { return }
        let otp = NumberGenerator.otp()
        order.otp = otp
        order.status = .received
        order.ago = "just now"
        activeOrder = order
        if let idx = orders.firstIndex(where: { $0.id == order.id }) {
            orders[idx] = order
        }
        flow = .otp
    }

    func cancelWaiting() {
        guard let order = activeOrder else {
            flow = nil
            return
        }
        balance += order.service.cost
        if let idx = orders.firstIndex(where: { $0.id == order.id }) {
            orders[idx].status = .refunded
            orders[idx].ago = "now"
        }
        flow = nil
        activeOrder = nil
    }

    func finishOtp() {
        flow = nil
        activeOrder = nil
        tab = .orders
    }

    func buyAgain(_ order: Order) {
        startCheckout(service: order.service, country: order.country)
    }

    private static let fallbackService = Service(
        id: "fallback", name: "Service", category: "Other", glyph: "S",
        tintHex: "#1B2330", smspvaCode: "opt0",
        cost: 1, successRate: 95, etaSeconds: 30, sortOrder: 100
    )
    private static let fallbackCountry = Country(
        id: "fallback", name: "Country", flag: "🌐",
        dialCode: "+0", smspvaCode: "XX",
        stock: .high, avgSeconds: 30, sortOrder: 100
    )
}

extension WaitingAnimation {
    var displayName: String {
        switch self { case .pulse: "Pulse"; case .breathe: "Breathe"; case .orbit: "Orbit" }
    }
}

extension OtpAnimation {
    var displayName: String {
        switch self { case .cascade: "Cascade"; case .reveal: "Reveal"; case .flip: "Flip" }
    }
}
