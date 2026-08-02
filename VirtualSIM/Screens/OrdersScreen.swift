import SwiftUI

enum OrdersTab: Hashable { case all, active, past }

struct OrdersScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api

    var openCredits: () -> Void

    @State private var tab: OrdersTab = .all

    /// History holds two products now, so the list is a merged, date-sorted
    /// sequence rather than `[Order]`. Email activations were previously absent
    /// from history entirely — `loadEmailOrders` had no caller and this screen
    /// only ever read `state.orders`.
    private enum HistoryItem: Identifiable {
        case sms(Order)
        case email(ServerEmailOrder)

        // Prefixed so an SMS id and an email id can never collide in a ForEach.
        var id: String {
            switch self {
            case .sms(let o):   "sms-\(o.id)"
            case .email(let e): "email-\(e.id)"
            }
        }
        var isActive: Bool {
            switch self {
            case .sms(let o):   o.status == .waiting
            case .email(let e): e.status == .waiting
            }
        }
        var sortDate: Date {
            switch self {
            case .sms(let o): o.createdAt
            case .email(let e):
                // email_orders.created_at is an ISO string; distantPast keeps an
                // unparseable one at the bottom rather than at "now".
                // PostgREST emits timestamptz WITH fractional seconds, which a
                // default ISO8601DateFormatter rejects — so every email row
                // parsed nil and a minutes-old activation sorted below the
                // oldest SMS order, i.e. it looked like the order vanished.
                // Try the fractional form first, plain second (static: a
                // formatter per comparison per body evaluation is real cost).
                Self.isoFrac.date(from: e.createdAt ?? "")
                    ?? Self.iso.date(from: e.createdAt ?? "")
                    ?? .distantPast
            }
        }
        private static let isoFrac: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        private static let iso = ISO8601DateFormatter()
    }

    private var allItems: [HistoryItem] {
        (state.orders.map(HistoryItem.sms) + state.emailOrders.map(HistoryItem.email))
            .sorted { $0.sortDate > $1.sortDate }
    }
    private var active: [HistoryItem] { allItems.filter(\.isActive) }
    private var past:   [HistoryItem] { allItems.filter { !$0.isActive } }
    private var list:   [HistoryItem] {
        switch tab {
        case .all:    allItems
        case .active: active
        case .past:   past
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 6)

                SegmentedTabs(selection: $tab, items: [
                    (.all,    "All",    allItems.count),
                    (.active, "Active", active.count),
                    (.past,   "Past",   past.count),
                ])
                .padding(.horizontal, 16)
                .padding(.top, 14)

                Group {
                    if list.isEmpty {
                        empty
                    } else {
                        Card {
                            VStack(spacing: 0) {
                                ForEach(Array(list.enumerated()), id: \.element.id) { idx, item in
                                    switch item {
                                    case .sms(let order):
                                        OrderRow(order: order,
                                                 isLast: idx == list.count - 1,
                                                 onTap: { tap(order) })
                                    case .email(let mail):
                                        EmailOrderRow(order: mail,
                                                      isLast: idx == list.count - 1,
                                                      onTap: { tapEmail(mail) })
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
            }
            .padding(.top, 8)
            .padding(.bottom, 140)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            await state.loadOrders(using: OrdersAPI(client: api))
            // This screen renders BOTH products' history — pull-to-refresh
            // skipping email meant a waiting email row never updated here.
            await state.loadEmailOrders(using: EmailAPI(client: api))
            await state.refreshWallet(using: WalletAPI(client: api))
        }
    }

    private var header: some View {
        HStack {
            Text("Orders")
                .font(RFont.display(28, weight: .bold))
                .tracking(-0.7)
                .foregroundStyle(theme.text)
            Spacer()
            CreditPill(value: state.balance, action: openCredits)
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text("No orders yet.")
                .font(RFont.text(14))
                .foregroundStyle(theme.text2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    /// Same shape as `tap`, and the same rule: a code that EXISTS wins over the
    /// status, so a code delivered onto a closed row is still reachable.
    private func tapEmail(_ mail: ServerEmailOrder) {
        // intent/activeEmailOrder are written ONLY on the branches that open a
        // flow. Writing them unconditionally leaked `.email` intent from a tap
        // on a dead row — no flow opened, so flow.didSet (the only clearer)
        // never ran, and the credits sheet then sized for a 1-credit email.
        if mail.hasCode {
            state.activeEmailOrder = mail
            state.intent = .email
            state.flow = .emailCode
        } else if mail.status == .waiting {
            state.activeEmailOrder = mail
            state.intent = .email
            state.flow = .emailWaiting
        }
        // Terminal and codeless: nothing to reopen. Deliberately no "buy again"
        // here — the domain may be out of stock and the price is chosen in the
        // picker, so silently starting a purchase would be guessing.
    }

    private func tap(_ order: Order) {
        if order.status == .waiting {
            state.activeOrder = order
            state.flow = .waiting
        } else if order.otp != nil {
            // A code exists — show it. Covers rescued codes, which land on a
            // CANCELED row; without this the only copy the user ever had was a
            // notification, and tapping the row offered to sell them another
            // number instead.
            state.activeOrder = order
            state.flow = .otp
        } else {
            state.buyAgain(order)
        }
    }
}
