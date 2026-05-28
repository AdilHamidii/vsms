import SwiftUI

enum OrdersTab: Hashable { case all, active, past }

struct OrdersScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state

    var openCredits: () -> Void

    @State private var tab: OrdersTab = .all

    private var active: [Order] { state.orders.filter { $0.status == .waiting } }
    private var past:   [Order] { state.orders.filter { $0.status != .waiting } }
    private var list:   [Order] {
        switch tab {
        case .all:    state.orders
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
                    (.all,    "All",    state.orders.count),
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
                                ForEach(Array(list.enumerated()), id: \.element.id) { idx, order in
                                    OrderRow(order: order,
                                             isLast: idx == list.count - 1,
                                             onTap: { tap(order) })
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

    private func tap(_ order: Order) {
        if order.status == .waiting {
            state.activeOrder = order
            state.flow = .waiting
        } else {
            state.buyAgain(order)
        }
    }
}
