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

    // Review-prompt gating (App Store 5.6.4: native prompt, no incentive).
    static let successfulCodes  = "review.successfulCodes"
    static let lastCountedOrder = "review.lastCountedOrder"
    static let lastPromptVer    = "review.lastPromptVersion"
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
    /// Guards one-time first-run selection seeding (see applyStartupSelection).
    @ObservationIgnored
    private var didSeedStartupSelection = false
    var lastService: Service
    var lastCountry: Country
    var orders: [Order] = []
    var filter: SortFilter = .all
    var profile: Profile?
    var maintenance: MaintenanceStatus = .off

    var flow: FlowStage?
    var checkoutService: Service?
    var checkoutCountry: Country?
    var activeOrder: Order?
    /// True while a create-order call is in flight — guards against double-tap
    /// double-charge and lets the checkout CTA show an in-progress state.
    var isPlacingOrder = false

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

    /// Whether to surface Apple's native review sheet now that a fresh code
    /// was delivered. Returns true at most once per app version, and only from
    /// the user's 2nd successful code onward — a genuinely positive moment.
    ///
    /// No credits or incentive are attached: App Store guideline 5.6.4 forbids
    /// paying for reviews. The system further throttles the actual sheet
    /// (~3 prompts/user/year), so we spend that quota only on happy outcomes.
    func shouldRequestReview(forOrderId id: String) -> Bool {
        let d = UserDefaults.standard
        // A re-render of the same delivery must not double-count.
        guard d.string(forKey: PrefKey.lastCountedOrder) != id else { return false }
        d.set(id, forKey: PrefKey.lastCountedOrder)

        let count = d.integer(forKey: PrefKey.successfulCodes) + 1
        d.set(count, forKey: PrefKey.successfulCodes)
        guard count >= 2 else { return false }

        let version = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard d.string(forKey: PrefKey.lastPromptVer) != version else { return false }
        d.set(version, forKey: PrefKey.lastPromptVer)
        return true
    }

    /// Returns the credit cost for (service, country), or nil when we don't
    /// have a confirmed retail price. nil means the pair is unavailable to
    /// book — UI should show "Unavailable" and disable the Get number button.
    /// We deliberately do NOT fall back to service.cost (a seed default), as
    /// undercharging vs the live SMSPVA price would burn margin per order.
    func cost(for service: Service, country: Country) -> Int? {
        guard let route = routeIndex["\(service.id)|\(country.id)"],
              route.status == "active",
              let credits = route.retailCredits else {
            return nil
        }
        return credits
    }

    /// Country picker shows every country in the catalog. A specific
    /// (service, country) pair may still be rejected at order time if
    /// SMSPVA is out of numbers — handled by create-order.
    var availableCountries: [Country] { countries }

    /// Credit shortfall for whatever the user is currently configuring (the
    /// checkout draft if present, else Home's selection). 0 when it's already
    /// affordable or the pair is unavailable. Drives CreditsSheet's pack
    /// preselection so the user is offered the smallest pack that unblocks them.
    var creditsShortfall: Int {
        let svc = checkoutService ?? lastService
        let cty = checkoutCountry ?? lastCountry
        guard let c = cost(for: svc, country: cty) else { return 0 }
        return max(0, c - balance)
    }

    /// Point the Home hero at something the user can actually act on, once per
    /// launch, after catalog + wallet + orders have loaded:
    ///  • returning user → mirror their most recent order as "Last used";
    ///  • brand-new user → default to an affordable, recognizable service the
    ///    welcome credit can buy, instead of WhatsApp/US (which costs far more
    ///    than the 1-credit grant and left every first-run CTA greyed out).
    func applyStartupSelection() {
        guard !didSeedStartupSelection else { return }
        didSeedStartupSelection = true

        if let recent = orders.first {
            lastService = services.first { $0.id == recent.service.id } ?? recent.service
            lastCountry = countries.first { $0.id == recent.country.id } ?? recent.country
            return
        }
        if let (svc, cty) = affordableStarter() {
            lastService = svc
            lastCountry = cty
        }
    }

    /// A recognizable service + country pair the current balance can afford.
    /// Prefers well-known services (in the given order); falls back to any
    /// affordable available pair. nil only when nothing is affordable yet
    /// (e.g. catalog not loaded), leaving the seed default in place.
    private func affordableStarter() -> (Service, Country)? {
        let preferred = ["telegram", "instagram", "tiktok", "discord", "google",
                         "whatsapp", "twitter-x", "uber", "openai", "amazon",
                         "signal", "facebook"]
        for id in preferred {
            if let svc = services.first(where: { $0.id == id }),
               let cty = cheapestAffordableCountry(for: svc) {
                return (svc, cty)
            }
        }
        for svc in services {
            if let cty = cheapestAffordableCountry(for: svc) {
                return (svc, cty)
            }
        }
        return nil
    }

    /// Cheapest available country whose route for `service` costs no more than
    /// the current balance, or nil when none is affordable.
    private func cheapestAffordableCountry(for service: Service) -> Country? {
        var best: (country: Country, cost: Int)?
        for c in countries {
            guard let cost = cost(for: service, country: c), cost <= balance else { continue }
            if best == nil || cost < best!.cost { best = (c, cost) }
        }
        return best?.country
    }

    // ─────────── Catalog / profile / wallet bootstrap ───────────

    func refreshWallet(using api: WalletAPI) async {
        do { balance = try await api.currentWallet().balance }
        catch { /* keep current */ }
    }

    func refreshProfile(using api: ProfileAPI) async {
        profile = try? await api.currentProfile()
    }

    func refreshMaintenance(using api: MaintenanceAPI) async {
        if let m = try? await api.current() { maintenance = m }
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
    ///
    /// @MainActor is load-bearing: AppState is @Observable but not otherwise
    /// actor-isolated, so without this the double-tap guard below is a racy
    /// check-then-set. Two taps spawn two Tasks that run off the main actor and
    /// can both read isPlacingOrder == false before either sets it, each placing
    /// a (charged) order. Pinning to the main actor makes guard+set atomic: the
    /// second tap runs only after the first has set the flag and suspended.
    @MainActor
    func confirmGetNumber(using orders: OrdersAPI, wallet: WalletAPI) async {
        guard let svc = checkoutService, let cty = checkoutCountry else { return }
        guard !isPlacingOrder else { return }   // no double-charge on double-tap
        isPlacingOrder = true
        defer { isPlacingOrder = false }
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
