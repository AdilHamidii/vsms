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
    var balance: Int = 7
    var lastService: Service
    var lastCountry: Country
    var orders: [Order]
    var filter: SortFilter = .all

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
        let svc = SeedData.services.first { $0.id == "mes" } ?? SeedData.services[0]
        let cty = SeedData.countries[0]
        self.lastService = svc
        self.lastCountry = cty
        self.orders = AppState.makeSeedOrders()

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

    /// Replace the local placeholder balance with the server-side wallet.
    /// Called after sign-in. Phase A: read-only; later phases will also push
    /// spend/refund through edge functions.
    func refreshWallet(using api: WalletAPI) async {
        do {
            let wallet = try await api.currentWallet()
            balance = wallet.balance
        } catch {
            // Keep the placeholder balance; Phase F will add proper error UI.
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

    private static func makeSeedOrders() -> [Order] {
        let s = SeedData.services
        let c = SeedData.countries
        return [
            Order(id: "o-1",
                  service: s.first { $0.id == "mes" }!, country: c[0],
                  number: "+1 (415) 555-0182", otp: "729384",
                  status: .received, ago: "2m ago"),
            Order(id: "o-2",
                  service: s.first { $0.id == "soc" }!, country: c[1],
                  number: "+44 7700 900423", otp: "481204",
                  status: .received, ago: "38m ago"),
            Order(id: "o-3",
                  service: s.first { $0.id == "eat" }!, country: c[4],
                  number: "+91 98765 43210", otp: nil,
                  status: .expired, ago: "2h ago"),
            Order(id: "o-4",
                  service: s.first { $0.id == "wal" }!, country: c[2],
                  number: "+49 1512 3456789", otp: nil,
                  status: .refunded, ago: "Yesterday"),
        ]
    }
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
