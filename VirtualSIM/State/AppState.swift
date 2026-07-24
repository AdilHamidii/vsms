import SwiftUI

enum AppTab: String, Hashable, CaseIterable {
    case home, esim, orders, account
}

enum FlowStage: String, Hashable, Identifiable {
    case checkout, waiting, otp, recovery, esimCheckout, esimDetail
    var id: String { rawValue }
}

/// What the post-failure recovery card needs to know. Stored on AppState
/// (FlowStage is raw-value-backed, so cases can't carry payloads — same
/// pattern as checkoutService/checkoutCountry).
struct RecoveryContext {
    enum Reason { case expired, canceled }
    let service: Service
    let failedCountry: Country
    let reason: Reason
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
    /// Context for the `.recovery` flow stage; set wherever an order ends
    /// without a code, cleared by retry/dismiss.
    var recovery: RecoveryContext?

    // eSIM product line
    var esimPlans: [EsimPlan] = []
    var esimOrders: [EsimOrder] = []
    var checkoutEsimPlan: EsimPlan?
    var activeEsimOrder: EsimOrder?
    var isBuyingEsim = false
    @ObservationIgnored
    private var esimPlanIndex: [String: EsimPlan] = [:]
    var checkoutService: Service?
    var checkoutCountry: Country?
    /// True when the user picked the Real-SIM (premium) tier in checkout.
    /// Reset on every startCheckout so the pricier tier is always an explicit
    /// choice, never a sticky default.
    var checkoutPremium = false
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

    /// Credit cost of the Real-SIM (premium) tier for (service, country), or
    /// nil when the route has no pinned real carrier — the checkout hides the
    /// tier choice entirely in that case. Never falls back to the standard
    /// price: a nil here means "not sellable as premium", same contract as
    /// cost(for:country:).
    func premiumCost(for service: Service, country: Country) -> Int? {
        guard let route = routeIndex["\(service.id)|\(country.id)"],
              route.status == "active",
              route.retailCredits != nil else {
            return nil
        }
        return route.premiumCredits
    }

    /// Provider self-reported delivery success (0-100) for (service, country),
    /// or nil when we have no figure. Separate from `cost` on purpose — a
    /// missing rate hides the badge, it does NOT make the route unavailable.
    func successRate(for service: Service, country: Country) -> Int? {
        guard let route = routeIndex["\(service.id)|\(country.id)"],
              route.status == "active" else { return nil }
        return route.successRate
    }

    /// Rate plus provenance. `isMeasured` is true only when the backend marked
    /// the rate `measured` — the only case the UI may state as fact; anything
    /// else is a seeded estimate and must read as one.
    func rateInfo(for service: Service, country: Country) -> (rate: Int, isMeasured: Bool)? {
        guard let route = routeIndex["\(service.id)|\(country.id)"],
              route.status == "active", let rate = route.successRate else { return nil }
        return (rate, route.rateSource == "measured")
    }

    /// The country to land on when the user picks `service`. Ranks by
    /// evidence, but NEVER silently swaps a working selection:
    ///  1. A country we've measured delivering wins — real steering.
    ///  2. Otherwise KEEP `current` when the service is bookable there and not
    ///     measured-failing. The sheet just showed the user a price for that
    ///     country; the buy button must say the same number.
    ///  3. Otherwise the cheapest untested bookable country. The old rule took
    ///     the PRICIEST — a SMSPool-era heuristic where the cheapest pool
    ///     really was the worst inventory. With SMSPVA, per-country carrier
    ///     prices are flat and the cross-country spread is country cost, not
    ///     quality — "priciest" was quoting 40cr Thailand right after the list
    ///     showed 3cr Netherlands, on zero evidence.
    ///  4. Everything left is measured-failing; give back the cheapest.
    func bestCountry(for service: Service, keeping current: Country? = nil) -> Country? {
        let bookable = countries.filter { cost(for: service, country: $0) != nil }
        guard !bookable.isEmpty else { return nil }

        // 1) Anything we've actually seen deliver.
        let proven = bookable.compactMap { c -> (Country, Int)? in
            guard let r = successRate(for: service, country: c), r > 0 else { return nil }
            return (c, r)
        }
        if let best = proven.max(by: { $0.1 < $1.1 }) { return best.0 }

        // 2) No evidence anywhere — stay where the user already is.
        if let current,
           cost(for: service, country: current) != nil,
           (successRate(for: service, country: current) ?? 1) > 0 {
            return current
        }

        // 3) Cheapest untested.
        let untested = bookable.filter { successRate(for: service, country: $0) == nil }
        if let pick = untested.min(by: {
            (cost(for: service, country: $0) ?? .max) < (cost(for: service, country: $1) ?? .max)
        }) { return pick }

        // 4) Everything left is measured-failing; give back the cheapest.
        return bookable.min(by: {
            (cost(for: service, country: $0) ?? .max) < (cost(for: service, country: $1) ?? .max)
        })
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
        if flow == .esimCheckout, let plan = checkoutEsimPlan, let c = plan.retailCredits {
            return max(0, c - balance)
        }
        let svc = checkoutService ?? lastService
        let cty = checkoutCountry ?? lastCountry
        // Respect the tier being configured: a premium pick must preselect a
        // pack that covers the premium price, not the standard one.
        let selected = flow == .checkout && checkoutPremium
            ? premiumCost(for: svc, country: cty)
            : cost(for: svc, country: cty)
        guard let c = selected else { return 0 }
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
        // Ordered by MEASURED delivery, not by brand recognition. The previous
        // list led with telegram/instagram/google/whatsapp/facebook — which is
        // almost exactly the set that measures ~9% delivered, versus ~52% for
        // everything else. Every new user was being defaulted onto the worst
        // part of the catalog, and most never saw a code at all.
        //
        // Meta and the messengers stay fully browsable; they're just no longer
        // the first thing a brand-new user is pointed at.
        let preferred = ["leboncoin", "deliveroo", "glovo", "whatnot", "walmart",
                         "vinted", "wallapop", "subito", "olx", "uber",
                         "tiktok", "discord"]
        for id in preferred {
            if let svc = services.first(where: { $0.id == id }),
               let cty = bestAffordableCountry(for: svc) {
                return (svc, cty)
            }
        }
        for svc in services {
            if let cty = bestAffordableCountry(for: svc) {
                return (svc, cty)
            }
        }
        return nil
    }

    /// Affordable country for `service`, chosen by the same evidence-first rule
    /// as `bestCountry(for:)` rather than by lowest price.
    private func bestAffordableCountry(for service: Service) -> Country? {
        guard let best = bestCountry(for: service),
              let c = cost(for: service, country: best), c <= balance
        else { return cheapestAffordableCountry(for: service) }
        return best
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

    // ─────────── eSIM ───────────

    func loadEsimCatalog(using api: EsimPlansAPI) async {
        guard let plans = try? await api.fetch() else { return }
        esimPlans = plans
        var idx: [String: EsimPlan] = [:]
        for p in plans { idx[p.id] = p }
        esimPlanIndex = idx
        // Re-resolve any already-loaded orders against the fresh catalog.
        esimOrders = esimOrders.map { EsimOrder(server: $0.server, plan: idx[$0.server.planId ?? ""]) }
    }

    func loadEsimOrders(using api: EsimOrdersAPI) async {
        guard let rows = try? await api.list() else { return }
        esimOrders = rows.map { EsimOrder(server: $0, plan: esimPlanIndex[$0.planId ?? ""]) }
    }

    /// eSIM plans grouped by country (cheapest tier per country), for the store.
    var esimCountries: [(code: String, name: String, from: Int)] {
        var byCode: [String: (name: String, minCr: Int)] = [:]
        for p in esimPlans {
            let code = p.countryCode ?? "??"
            let cr = p.retailCredits ?? Int.max
            if let ex = byCode[code] { if cr < ex.minCr { byCode[code] = (ex.name, cr) } }
            else { byCode[code] = (p.name, cr) }
        }
        return byCode.map { (code: $0.key, name: $0.value.name, from: $0.value.minCr) }
            .sorted { $0.name < $1.name }
    }
    func esimPlans(forCountry code: String) -> [EsimPlan] {
        esimPlans.filter { $0.countryCode == code }
            .sorted { ($0.retailCredits ?? 0) < ($1.retailCredits ?? 0) }
    }

    func startEsimCheckout(_ plan: EsimPlan) {
        checkoutEsimPlan = plan
        flow = .esimCheckout
    }
    func openEsimDetail(_ order: EsimOrder) {
        activeEsimOrder = order
        flow = .esimDetail
    }

    /// @MainActor for the same atomic double-tap guard reasoning as confirmGetNumber.
    @MainActor
    func confirmBuyEsim(using api: EsimOrdersAPI, wallet: WalletAPI) async {
        guard let plan = checkoutEsimPlan, !isBuyingEsim else { return }
        isBuyingEsim = true
        defer { isBuyingEsim = false }
        do {
            let server = try await api.create(planId: plan.id)
            let order = EsimOrder(server: server, plan: esimPlanIndex[server.planId ?? ""] ?? plan)
            esimOrders.insert(order, at: 0)
            activeEsimOrder = order
            flow = .esimDetail
            await refreshWallet(using: wallet)
        } catch let apiErr as APIError {
            lastError = apiErr.userMessage
        } catch {
            lastError = "Couldn't buy that eSIM. Please try again."
        }
    }

    func refreshEsimUsage(using api: EsimOrdersAPI) async {
        guard let current = activeEsimOrder else { return }
        guard let server = try? await api.checkUsage(orderId: current.id) else { return }
        let updated = EsimOrder(server: server, plan: current.plan)
        activeEsimOrder = updated
        if let idx = esimOrders.firstIndex(where: { $0.id == updated.id }) { esimOrders[idx] = updated }
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
        checkoutPremium = false
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
            let server = try await orders.create(serviceId: svc.id, countryId: cty.id,
                                                 premium: checkoutPremium)
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
                // Not a dead-end banner: the user still wants their code.
                // Swap the cover to the recovery card (refund reassurance +
                // measured-best retry) instead of dumping them on Home.
                recovery = RecoveryContext(service: current.service,
                                           failedCountry: current.country,
                                           reason: .expired)
                flow = .recovery
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
            // The backend does a last-chance poll before canceling: if the
            // code was already in flight, the "cancel" comes back as a
            // delivered order. Show the code — it's what they paid for.
            if updated.status == .received {
                activeOrder = updated
                flow = .otp
                return
            }
            await refreshWallet(using: wallet)
            // Refund confirmed — offer a steer instead of a dead end (72 of
            // the last 122 orders were re-orders; the demand doesn't vanish
            // with the number).
            recovery = RecoveryContext(service: order.service,
                                       failedCountry: order.country,
                                       reason: .canceled)
            flow = .recovery
        } catch let apiErr as APIError {
            // Cancel FAILED: the refund reassurance would be a lie here, so
            // keep the old banner-and-home behavior.
            lastError = apiErr.userMessage
            flow = nil
        } catch {
            lastError = "Couldn't cancel that order. Please try again."
            flow = nil
        }
        activeOrder = nil
    }

    /// Swap the current number for a fresh one without leaving the wait screen.
    ///
    /// This is already how people use the app — 72 of the last 122 orders were
    /// re-orders placed within 10 minutes of the previous one, median gap 19
    /// seconds — but until now it took six taps (✕ → home → picker → country →
    /// checkout → get). It's also economically free: cancelling refunds the
    /// credits in full and the new order charges the same, so the user only
    /// ever pays for the number that actually delivers.
    ///
    /// `differentCountry` matters when a platform rejected the number outright:
    /// the whole range is usually flagged, so another number from it will fail
    /// the same way. Falls back to the same route when there's no alternative.
    func rerollNumber(using orders: OrdersAPI, wallet: WalletAPI,
                      differentCountry: Bool) async {
        guard let order = activeOrder, !isPlacingOrder else { return }
        let svc = order.service

        var next = order.country
        if differentCountry {
            let alternatives = countries.filter {
                $0.id != order.country.id
                && cost(for: svc, country: $0) != nil
                && (cost(for: svc, country: $0) ?? .max) <= balance + order.costCredits
            }
            // Prefer a route we've measured delivering; otherwise avoid the
            // cheapest pool for the same reason bestCountry(for:) does.
            next = alternatives.max {
                (successRate(for: svc, country: $0) ?? -1, cost(for: svc, country: $0) ?? 0)
                < (successRate(for: svc, country: $1) ?? -1, cost(for: svc, country: $1) ?? 0)
            } ?? order.country
        }

        isPlacingOrder = true
        defer { isPlacingOrder = false }

        // Release the old number first so its credits are back before we spend
        // again — a reroll must never need a bigger balance than the original.
        if let server = try? await orders.cancel(orderId: order.id) {
            let updated = resolve(server)
            if let idx = self.orders.firstIndex(where: { $0.id == updated.id }) {
                self.orders[idx] = updated
            }
        }
        await refreshWallet(using: wallet)

        do {
            let server = try await orders.create(serviceId: svc.id, countryId: next.id)
            let fresh = resolve(server)
            lastService = svc
            lastCountry = next
            activeOrder = fresh
            self.orders.insert(fresh, at: 0)
            flow = .waiting               // stay put; only the number changes
            await refreshWallet(using: wallet)
        } catch let apiErr as APIError {
            // The old number is already released and refunded — recover, don't
            // dead-end. The banner still explains why this attempt failed.
            lastError = apiErr.userMessage
            recovery = RecoveryContext(service: svc, failedCountry: next, reason: .canceled)
            flow = .recovery
            activeOrder = nil
        } catch {
            lastError = "Couldn't get another number. Please try again."
            recovery = RecoveryContext(service: svc, failedCountry: next, reason: .canceled)
            flow = .recovery
            activeOrder = nil
        }
    }

    func finishOtp() {
        flow = nil
        activeOrder = nil
        tab = .orders
    }

    /// Best country for `service` by MEASURED evidence only — the sole basis
    /// on which the recovery card may state a rate as fact. nil when nothing
    /// measured ≥ 40% is bookable (below that, "delivers best" is technically
    /// honest but useless advice). Highest rate wins; ties go to the cheaper.
    func bestMeasuredCountry(for service: Service) -> (country: Country, rate: Int)? {
        let candidates = countries.compactMap { c -> (country: Country, rate: Int, price: Int)? in
            guard let info = rateInfo(for: service, country: c), info.isMeasured,
                  info.rate >= 40, let price = cost(for: service, country: c) else { return nil }
            return (c, info.rate, price)
        }
        guard let best = candidates.max(by: { ($0.rate, -$0.price) < ($1.rate, -$1.price) })
        else { return nil }
        return (best.country, best.rate)
    }

    /// Retry from the recovery card. Lands on Checkout (not straight into an
    /// order) so price/balance are confirmed the normal way; the backend's
    /// retry steering makes the new attempt draw a fresh number on a rotated
    /// carrier. Steers to the measured-best country when one exists, else the
    /// same route.
    func retryFromRecovery() {
        guard let r = recovery else { return }
        let suggested = bestMeasuredCountry(for: r.service)?.country ?? r.failedCountry
        recovery = nil
        startCheckout(service: r.service, country: suggested)
    }

    func dismissRecovery() {
        recovery = nil
        flow = nil
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
