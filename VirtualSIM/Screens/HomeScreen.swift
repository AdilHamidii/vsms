import SwiftUI

struct HomeScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state

    var showMetrics: Bool = true
    var openServices: () -> Void = {}
    var openCountries: () -> Void = {}
    var openCredits: () -> Void = {}
    var onStart: () -> Void = {}
    var onTapOrder: (Order) -> Void = { _ in }
    var onSeeAllOrders: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 6)

                heroSection
                    .padding(.horizontal, 16)
                    .padding(.top, 22)

                pickersSection
                    .padding(.horizontal, 16)
                    .padding(.top, 22)

                if !state.orders.isEmpty {
                    recentSection
                        .padding(.horizontal, 16)
                        .padding(.top, 22)
                }

                trustFooter
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
            }
            .padding(.top, 8)
            .padding(.bottom, 140)
        }
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting)
                    .font(RFont.text(13))
                    .tracking(-0.1)
                    .foregroundStyle(theme.text2)
                Text("Get a number.")
                    .font(RFont.display(28, weight: .bold))
                    .tracking(-0.7)
                    .foregroundStyle(theme.text)
            }
            Spacer()
            CreditPill(value: state.balance, action: openCredits)
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<12:  return "Good morning"
        case 12..<18: return "Good afternoon"
        default:      return "Good evening"
        }
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(label: "Last used")
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 14) {
                        ServiceLogo(service: state.lastService, size: 52, radius: 14)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(state.lastService.name)
                                .font(RFont.display(18, weight: .semibold))
                                .tracking(-0.4)
                                .foregroundStyle(theme.text)
                            HStack(spacing: 6) {
                                Text(state.lastCountry.flag)
                                Text(state.lastCountry.name)
                                    .font(RFont.text(13))
                                    .foregroundStyle(theme.text2)
                                Text("·").foregroundStyle(theme.text3)
                                MonoText(state.lastCountry.dialCode, size: 12, color: theme.text2)
                            }
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text("\(state.lastService.cost)")
                                    .font(RFont.display(22, weight: .semibold))
                                    .tracking(-0.5)
                                    .foregroundStyle(theme.text)
                                Text("cr")
                                    .font(RFont.text(13, weight: .medium))
                                    .foregroundStyle(theme.text2)
                            }
                            StockPill(level: state.lastCountry.stock)
                        }
                    }
                    if showMetrics {
                        Rectangle()
                            .fill(theme.sep)
                            .frame(height: 0.5)
                            .padding(.top, 16)
                        HStack(spacing: 8) {
                            Metric(label: "Avg arrival", value: "\(state.lastService.etaSeconds)s")
                            Spacer()
                            Metric(label: "Delivered", value: "\(state.lastService.successRate)%", accent: theme.live)
                            Spacer()
                            Metric(label: "Last seen", value: "2m ago")
                        }
                        .padding(.top, 14)
                    }
                    PrimaryButton(
                        label: "Get number",
                        sub: "\(state.lastService.cost) cr",
                        icon: RIcon.bolt,
                        disabled: state.balance < state.lastService.cost,
                        action: onStart
                    )
                    .padding(.top, 16)
                }
                .padding(18)
            }
        }
    }

    private var pickersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(label: "Change")
            HStack(spacing: 10) {
                PickerCard(label: "Service", value: state.lastService.name, icon: {
                    ServiceLogo(service: state.lastService, size: 32, radius: 9)
                }, onTap: openServices)
                PickerCard(label: "Country", value: state.lastCountry.name, icon: {
                    FlagBox(flag: state.lastCountry.flag, size: 32, radius: 9)
                }, onTap: openCountries)
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(label: "Recent", action: "See all", onAction: onSeeAllOrders)
            Card {
                VStack(spacing: 0) {
                    let recent = Array(state.orders.prefix(3))
                    ForEach(Array(recent.enumerated()), id: \.element.id) { idx, order in
                        OrderRow(order: order,
                                 isLast: idx == recent.count - 1,
                                 onTap: { onTapOrder(order) })
                    }
                }
            }
        }
    }

    private var trustFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: RIcon.shield)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.text3)
            Text("Failed SMS auto-refund within 2 minutes.")
                .font(RFont.text(12))
                .tracking(-0.1)
                .foregroundStyle(theme.text3)
        }
    }
}
