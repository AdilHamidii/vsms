import SwiftUI

struct HomeScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state

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

                if let purchased = state.creditPurchaseBanner {
                    creditBanner(
                        title: String(localized: "+\(purchased) credits added"),
                        sub: String(localized: "Your purchase is confirmed."),
                        dismiss: { state.creditPurchaseBanner = nil })
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else if let bonus = state.dailyCreditBanner {
                    creditBanner(
                        title: String(localized: "+\(bonus.credits) credit added"),
                        sub: bonus.streak >= 2
                            ? String(localized: "\(bonus.streak) days in a row — come back tomorrow for another.")
                            : String(localized: "Come back tomorrow for another."),
                        dismiss: { state.dailyCreditBanner = nil })
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

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

    /// Confirms credits actually landed — from the daily grant or a purchase.
    /// Without a visible acknowledgement, a successful buy looks exactly like a
    /// failed one, and a silent daily grant defeats the point of a daily reason
    /// to return.
    private func creditBanner(title: String, sub: String,
                              dismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            CoinIcon(size: 18, color: theme.live)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(RFont.text(14, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text(sub)
                    .font(RFont.text(12))
                    .foregroundStyle(theme.text2)
            }
            Spacer(minLength: 0)
            Button {
                withAnimation(.easeOut(duration: 0.2)) { dismiss() }
            } label: {
                Image(systemName: RIcon.close)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.text3)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.liveSoft, in: .rect(cornerRadius: 14))
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

    private var routeCost: Int? {
        state.cost(for: state.lastService, country: state.lastCountry)
    }

    private var routeRate: (rate: Int, isMeasured: Bool, sample: Int?)? {
        state.rateInfo(for: state.lastService, country: state.lastCountry)
    }

    /// A user who has never placed an order — show them a "start here" framing
    /// and, when their free credit covers the default, say so.
    private var isFirstRun: Bool { state.orders.isEmpty }

    /// The hero's primary action. Mirrors CheckoutScreen: a real "Buy credits"
    /// path when short, instead of a dead greyed-out button.
    @ViewBuilder
    private var heroCTA: some View {
        if let routeCost {
            if state.balance < routeCost {
                PrimaryButton(
                    label: "Buy credits",
                    sub: "Need \(routeCost - state.balance) more",
                    icon: RIcon.plus,
                    action: openCredits
                )
            } else {
                PrimaryButton(
                    label: "Get number",
                    sub: "\(routeCost) cr",
                    icon: RIcon.bolt,
                    action: onStart
                )
            }
        } else {
            PrimaryButton(
                label: "Unavailable",
                sub: "Pick another country",
                icon: RIcon.bolt,
                disabled: true,
                action: {}
            )
        }
    }

    private var freeCreditHint: some View {
        HStack(spacing: 8) {
            CoinIcon(size: 15, color: theme.live)
            Text("Your free credit covers this — first number's on us.")
                .font(RFont.text(12, weight: .medium))
                .tracking(-0.1)
                .foregroundStyle(theme.text2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.liveSoft, in: .rect(cornerRadius: 12))
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(label: isFirstRun ? "Start here" : "Last used")
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
                                FlagImage(country: state.lastCountry, size: 14, radius: 3)
                                Text(state.lastCountry.name)
                                    .font(RFont.text(13))
                                    .foregroundStyle(theme.text2)
                                Text("·").foregroundStyle(theme.text3)
                                MonoText(state.lastCountry.dialCode, size: 12, color: theme.text2)
                            }
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 4) {
                            if let routeCost {
                                HStack(alignment: .firstTextBaseline, spacing: 3) {
                                    Text("\(routeCost)")
                                        .font(RFont.display(22, weight: .semibold))
                                        .tracking(-0.5)
                                        .foregroundStyle(theme.text)
                                    Text("cr")
                                        .font(RFont.text(13, weight: .medium))
                                        .foregroundStyle(theme.text2)
                                }
                            } else {
                                Text("—")
                                    .font(RFont.display(22, weight: .semibold))
                                    .foregroundStyle(theme.text3)
                            }
                        }
                    }
                    if state.showMetrics {
                        Rectangle()
                            .fill(theme.sep)
                            .frame(height: 0.5)
                            .padding(.top, 16)
                        HStack(spacing: 8) {
                            // Measured p50, or "—" when we have no sample.
                            // Never the seed etaSeconds.
                            Metric(label: "Typical wait",
                                   value: state.lastService.typicalWaitShort ?? "—")
                            Spacer()
                            Metric(label: "No code", value: "Refunded", accent: theme.live)
                            Spacer()
                            if let routeRate {
                                // Same rule as SuccessBadge: colour signals
                                // CONFIDENCE. A seeded rate is a provider
                                // guess and stays muted however good it looks.
                                Metric(label: "Success",
                                       value: routeRate.isMeasured ? "\(routeRate.rate)%" : "~\(routeRate.rate)%",
                                       accent: routeRate.isMeasured
                                           ? (routeRate.rate >= 70 ? theme.live : theme.warn)
                                           : theme.text3)
                            } else {
                                Metric(label: "Held for", value: "8 min")
                            }
                        }
                        .padding(.top, 14)
                    }
                    heroCTA
                        .padding(.top, 16)
                }
                .padding(18)
            }
            if isFirstRun, let routeCost, state.balance >= routeCost {
                freeCreditHint
                    .padding(.top, 10)
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
                    FlagImage(country: state.lastCountry, size: 32, radius: 9)
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
            Text("No code in 8 minutes → refunded automatically.")
                .font(RFont.text(12))
                .tracking(-0.1)
                .foregroundStyle(theme.text3)
        }
    }
}
