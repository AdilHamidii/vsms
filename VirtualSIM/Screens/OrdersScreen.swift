import SwiftUI

enum OrdersTab: Hashable { case all, active, past }

struct OrdersScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api

    var openCredits: () -> Void

    @State private var tab: OrdersTab = .all

    /// Whether this screen has completed a fetch of its own.
    ///
    /// Without it an empty list during the very first load is byte-identical to
    /// having no orders at all — on the app's second-most-visited tab, the two
    /// answers are "wait a second" and "you have never bought anything", and
    /// showing the second while the first is true is the more damaging way to
    /// be wrong.
    @State private var loaded = false

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

                // `String(localized:)`, not bare literals. `SegmentedTabs`
                // takes a plain `String`, and a literal passed to a `String`
                // parameter is invisible to the string extractor — so it never
                // enters the catalog and cannot even be COUNTED as missing by a
                // "0 untranslated" audit. "All" and "Past" were absent for
                // exactly this reason while the other two call sites, which do
                // wrap, were fine. (The component localizes too; both halves
                // are needed.)
                SegmentedTabs(selection: $tab, items: [
                    (.all,    String(localized: "All"),    allItems.count),
                    (.active, String(localized: "Active"), active.count),
                    (.past,   String(localized: "Past"),   past.count),
                ])
                .padding(.horizontal, 16)
                .padding(.top, 14)

                Group {
                    if isLoading {
                        skeleton
                    } else if list.isEmpty {
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
                                        // `onTap` is nil for a row that leads
                                        // nowhere, so EmailOrderRow renders
                                        // plain content instead of a Button —
                                        // a terminal codeless row used to be a
                                        // Button whose action did nothing at
                                        // all: it pressed, and then nothing
                                        // happened, which reads as a broken
                                        // app rather than as a dead end.
                                        EmailOrderRow(order: mail,
                                                      isLast: idx == list.count - 1,
                                                      onTap: emailTap(mail))
                                    }
                                }
                            }
                        }
                    }
                }
                .animation(RMotion.content, value: isLoading)
                .padding(.horizontal, 16)
                .padding(.top, 14)
            }
            .padding(.top, 8)
            .padding(.bottom, 140)
        }
        .scrollIndicators(.hidden)
        .task {
            // Only fetches when there is genuinely nothing to show. Cold start
            // already loads both lists, so the common case is that this screen
            // opens straight onto real rows and never renders a skeleton.
            if allItems.isEmpty { await refresh() }
            loaded = true
        }
        .refreshable { await refresh() }
    }

    private var isLoading: Bool { !loaded && allItems.isEmpty }

    private func refresh() async {
        await state.loadOrders(using: OrdersAPI(client: api))
        // This screen renders BOTH products' history — pull-to-refresh
        // skipping email meant a waiting email row never updated here.
        await state.loadEmailOrders(using: EmailAPI(client: api))
        await state.refreshWallet(using: WalletAPI(client: api))
    }

    /// Placeholder rows with a travelling highlight.
    ///
    /// Motion is the entire signal that a placeholder is a placeholder — a
    /// static grey stack reads as a list of broken rows.
    private var skeleton: some View {
        Card {
            VStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { i in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: RRadius.xs, style: .continuous)
                            .fill(theme.track)
                            .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 6) {
                            Capsule().fill(theme.track).frame(width: 108, height: 11)
                            Capsule().fill(theme.track).frame(width: 74, height: 9)
                        }
                        Spacer(minLength: 0)
                        Capsule().fill(theme.track).frame(width: 56, height: 18)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)

                    if i < 3 {
                        Rectangle().fill(theme.sep).frame(height: 0.5)
                            .padding(.leading, 62)
                    }
                }
            }
            .shimmer()
        }
        .accessibilityLabel(Text("Loading your orders"))
    }

    private var header: some View {
        HStack {
            Text("Orders")
                .displayType(28)
                .foregroundStyle(theme.text)
            Spacer()
            CreditPill(value: state.balance, action: openCredits)
        }
    }

    /// Per-tab copy.
    ///
    /// One string — "No orders yet." at 14pt grey, centred, no icon, no
    /// explanation, no way out — served all three filters, so a user with six
    /// completed orders who tapped **Active** was told they had never ordered
    /// anything. That is not a thin empty state, it is a false one.
    @ViewBuilder
    private var empty: some View {
        switch tab {
        case .all:
            EmptyState(
                icon: RIcon.inbox,
                title: "No orders yet",
                message: "Numbers and email addresses you buy show up here — with the code, and the refund if one never arrived.",
                primary: (label: String(localized: "Get a number"),
                          action: { state.tab = .home })
            )
        case .active:
            EmptyState(
                icon: RIcon.clock,
                title: "Nothing in flight",
                message: allItems.isEmpty
                    ? "Orders waiting on a code appear here while they run."
                    : "None of your orders are waiting on a code right now. Finished ones are under Past.",
                secondary: allItems.isEmpty ? nil
                    : jump(to: .past, String(localized: "See past orders"))
            )
        case .past:
            EmptyState(
                icon: RIcon.check,
                title: "No finished orders",
                message: active.isEmpty
                    ? "Once an order ends — with a code or with a refund — it lands here."
                    : "Your orders are all still running. They move here as soon as they finish.",
                secondary: active.isEmpty ? nil
                    : jump(to: .active, String(localized: "See active orders"))
            )
        }
    }

    private func jump(to target: OrdersTab, _ label: String)
        -> (label: String, action: () -> Void) {
        (label: label, action: {
            RHaptic.select()
            withAnimation(RMotion.select) { tab = target }
        })
    }

    private func emailTap(_ mail: ServerEmailOrder) -> (() -> Void)? {
        guard let destination = emailDestination(mail) else { return nil }
        return { open(mail, destination) }
    }

    /// Where an email row leads, or **nil when it leads nowhere**.
    ///
    /// Returning nil is the whole point: `OrdersScreen` used to hand every
    /// email row an `onTap`, so `EmailOrderRow` wrapped every one in a Button
    /// — including terminal codeless rows, whose handler fell through all its
    /// branches and did nothing. The row looked tappable, pressed like a
    /// button, and produced no navigation and no feedback.
    ///
    /// Same rule as `tap`: a code that EXISTS wins over the status, so a code
    /// delivered onto a closed row is still reachable.
    private func emailDestination(_ mail: ServerEmailOrder) -> FlowStage? {
        if mail.hasCode { return .emailCode }
        if mail.status == .waiting { return .emailWaiting }
        // Terminal and codeless: nothing to reopen. Deliberately no "buy again"
        // here — the domain may be out of stock and the price is chosen in the
        // picker, so silently starting a purchase would be guessing.
        return nil
    }

    private func open(_ mail: ServerEmailOrder, _ destination: FlowStage) {
        // intent/activeEmailOrder are written ONLY when a flow actually opens.
        // Writing them unconditionally leaked `.email` intent from a tap on a
        // dead row — no flow opened, so flow.didSet (the only clearer) never
        // ran, and the credits sheet then sized for a 1-credit email.
        state.activeEmailOrder = mail
        state.intent = .email
        state.flow = destination
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
