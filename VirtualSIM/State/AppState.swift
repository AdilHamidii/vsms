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
    /// O(1) lookup index built from `routes`. Rebuilt in loadCatalog so we
    /// don't linear-scan 17k+ rows on every cost() call.
    @ObservationIgnored
    private var routeIndex: [String: Route] = [:]
    var lastService: Service
    var lastCountry: Country
    var orders: [Order] = []
    var filter: SortFilter = .all
    var profile: Profile?

    var flow: FlowStage?
    var checkoutService: Service?
    var checkoutCountry: Country?
    var activeOrder: Order?

    /// Latest error string for UI banners. Phase F wires real banner UI.
    var lastError: String?

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

    /// Look up the route for (service, country). Routes are only sent down
    /// when they differ from defaults (price override or non-active status);
    /// any unlisted pair is treated as active at service.cost.
    func cost(for service: Service, country: Country) -> Int {
        if let route = routeIndex["\(service.id)|\(country.id)"] {
            if route.status != "active" { return service.cost }
            return route.retailCredits ?? service.cost
        }
        return service.cost
    }

    /// Country picker shows every country in the catalog. A specific
    /// (service, country) pair may still be rejected at order time if
    /// SMSPVA is out of numbers — handled by create-order.
    var availableCountries: [Country] { countries }

    // ─────────── Catalog / profile / wallet bootstrap ───────────

    func refreshWallet(using api: WalletAPI) async {
        do { balance = try await api.currentWallet().balance }
        catch { /* keep current */ }
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

            // Rebuild the lookup index — used by cost(for:country:).
            var idx: [String: Route] = [:]
            idx.reserveCapacity(catalog.routes.count)
            for r in catalog.routes {
                idx["\(r.serviceId)|\(r.countryId)"] = r
            }
            routeIndex = idx

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
            // keep current state
        }
    }

    func loadOrders(using api: OrdersAPI) async {
        do {
            let rows = try await api.list()
            orders = rows.compactMap { resolve($0) }
        } catch {
            // keep current
        }
    }

    /// Build a UI Order from a server row using the loaded catalog.
    /// Falls back to placeholder Service/Country so the order is still
    /// renderable if the catalog reference is stale.
    func resolve(_ s: ServerOrder) -> Order {
        let svc = services.first { $0.id == s.serviceId } ?? AppState.fallbackService
        let cty = countries.first { $0.id == s.countryId } ?? AppState.fallbackCountry
        return Order(server: s, service: svc, country: cty)
    }

    // ─────────── Checkout / waiting / OTP ───────────

    func startCheckout(service: Service? = nil, country: Country? = nil) {
        checkoutService = service ?? lastService
        checkoutCountry = country ?? lastCountry
        flow = .checkout
    }

    /// Calls create-order. On success, deducts credits and transitions to
    /// the Waiting flow. On failure, sets lastError and stays on Checkout.
    func confirmGetNumber(using orders: OrdersAPI, wallet: WalletAPI) async {
        guard let svc = checkoutService, let cty = checkoutCountry else { return }
        do {
            let server = try await orders.create(serviceId: svc.id, countryId: cty.id)
            let order = resolve(server)
            lastService = svc
            lastCountry = cty
            activeOrder = order
            self.orders.insert(order, at: 0)
            flow = .waiting
            await refreshWallet(using: wallet)
        } catch let apiErr as APIError {
            lastError = apiErr.userMessage
        } catch {
            lastError = "Something went wrong. Please try again."
        }
    }

    /// One-shot check for the active order. Called repeatedly from the
    /// Waiting screen's polling task and once from the "Skip wait" button.
    func pollActiveOrder(using orders: OrdersAPI, wallet: WalletAPI) async {
        guard let current = activeOrder else { return }
        do {
            let server = try await orders.check(orderId: current.id)
            let updated = resolve(server)
            activeOrder = updated
            if let idx = self.orders.firstIndex(where: { $0.id == updated.id }) {
                self.orders[idx] = updated
            }
            switch server.status {
            case .received:
                flow = .otp
            case .expired:
                await refreshWallet(using: wallet)
                lastError = "Number expired before a code arrived. Credits refunded."
                flow = nil
                activeOrder = nil
            default: break
            }
        } catch {
            // Transient — keep polling.
        }
    }

    func cancelWaiting(using orders: OrdersAPI, wallet: WalletAPI) async {
        guard let order = activeOrder else { flow = nil; return }
        do {
            let server = try await orders.cancel(orderId: order.id)
            let updated = resolve(server)
            if let idx = self.orders.firstIndex(where: { $0.id == updated.id }) {
                self.orders[idx] = updated
            }
            await refreshWallet(using: wallet)
        } catch let apiErr as APIError {
            lastError = apiErr.userMessage
        } catch {
            lastError = "Couldn't cancel that order. Please try again."
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

    // ─────────── Credits (will be replaced by IAP in Phase E) ───────────

    func buy(_ pack: CreditPack) {
        balance += pack.credits
    }

    // ─────────── Fallbacks ───────────

    private static let fallbackService = Service(
        id: "fallback", name: "Service", category: "Other",
        glyph: "S", icon: "questionmark", domain: nil,
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
