import SwiftUI

struct CheckoutScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api

    var openServices: () -> Void
    var openCountries: () -> Void
    var openCredits: () -> Void

    private var service: Service { state.checkoutService ?? state.lastService }
    private var country: Country { state.checkoutCountry ?? state.lastCountry }
    private var standardCost: Int? { state.cost(for: service, country: country) }
    private var premiumCost: Int? { state.premiumCost(for: service, country: country) }
    /// Price of the tier currently selected. Premium is only selectable when
    /// the route carries a premium price, so the fallback never actually
    /// charges standard for a premium pick — it just keeps the receipt sane
    /// while the catalog refreshes underneath an open checkout.
    private var routeCost: Int? {
        state.checkoutPremium ? (premiumCost ?? standardCost) : standardCost
    }
    private var insufficient: Bool {
        guard let routeCost else { return false }
        return state.balance < routeCost
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    topBar
                    titleBlock
                    receiptCard
                    DeliveryNotice(density: .full, service: service)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    rules
                }
                .padding(.top, 6)
                .padding(.bottom, 160)
            }
            .scrollIndicators(.hidden)

            stickyCTA
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                state.flow = nil
            } label: {
                Image(systemName: RIcon.back)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .frame(width: 36, height: 36)
                    .background(theme.chipBg, in: .circle)
            }
            .buttonStyle(.plain)
            Spacer()
            Text("Confirm")
                .font(RFont.display(16, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(theme.text)
            Spacer()
            CreditPill(value: state.balance, action: openCredits)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Get number")
                .font(RFont.display(30, weight: .bold))
                .tracking(-0.8)
                .foregroundStyle(theme.text)
            Text("Number is reserved for 8 minutes. You only pay if a code arrives.")
                .font(RFont.text(15))
                .tracking(-0.2)
                .foregroundStyle(theme.text2)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var receiptCard: some View {
        Card {
            VStack(spacing: 0) {
                ReceiptRow(label: "Service", onTap: openServices, leading: {
                    ServiceLogo(service: service, size: 32, radius: 9)
                }, trailing: {
                    ReceiptValue(primary: service.name, secondaryText: service.category, chev: true)
                })
                ReceiptRow(label: "Country", onTap: openCountries, leading: {
                    FlagImage(country: country, size: 32, radius: 9)
                }, trailing: {
                    ReceiptValue(primary: country.name, secondary: {
                        HStack(spacing: 4) {
                            MonoText(country.dialCode, size: 11, color: theme.text2)
                        }
                    }, chev: true)
                })
                if let premiumCost {
                    ReceiptRow(label: "Number type", leading: {
                        ReceiptIconBox(symbol: RIcon.shield)
                    }, trailing: {
                        HStack(spacing: 6) {
                            TierChip(title: "Standard",
                                     selected: !state.checkoutPremium) {
                                state.checkoutPremium = false
                            }
                            TierChip(title: "Real SIM",
                                     selected: state.checkoutPremium) {
                                state.checkoutPremium = true
                            }
                        }
                    })
                    .accessibilityHint(Text("Real SIM costs \(premiumCost) credits and has the best delivery rate"))
                }
                if state.showMetrics {
                    ReceiptRow(label: "Expected", leading: {
                        ReceiptIconBox(symbol: RIcon.clock)
                    }, trailing: {
                        ReceiptValue(primary: "~\(service.etaSeconds) sec",
                                     secondaryText: "Only charged if a code arrives")
                    })
                }
                if state.showMetrics, state.checkoutPremium {
                    // The measured rate describes the standard (random-pool)
                    // tier; quoting it under a Real-SIM pick would undersell
                    // the thing being paid for.
                    ReceiptRow(label: "Delivery", leading: {
                        ReceiptIconBox(symbol: RIcon.shield)
                    }, trailing: {
                        ReceiptValue(primary: "Real carrier number",
                                     secondaryText: "Best delivery — refunded if it fails")
                    })
                } else if state.showMetrics, let rate = state.successRate(for: service, country: country) {
                    ReceiptRow(label: "Delivery", leading: {
                        ReceiptIconBox(symbol: RIcon.shield)
                    }, trailing: {
                        ReceiptValue(primary: "\(rate)% delivered",
                                     secondaryText: rate >= 70 ? "Reliable route" : "Lower-success — refunded if it fails")
                    })
                }
                ReceiptRow(label: "Cost", last: true, leading: {
                    CoinIconBox()
                }, trailing: {
                    HStack(spacing: 8) {
                        VStack(alignment: .trailing, spacing: 1) {
                            if let routeCost {
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text("\(routeCost)")
                                        .font(RFont.display(17, weight: .semibold))
                                        .tracking(-0.3)
                                        .foregroundStyle(theme.text)
                                    Text("credits")
                                        .font(RFont.text(13, weight: .medium))
                                        .foregroundStyle(theme.text2)
                                }
                                Text("\(state.balance - routeCost) left after")
                                    .font(RFont.text(12))
                                    .foregroundStyle(theme.text2)
                            } else {
                                Text("Unavailable")
                                    .font(RFont.display(15, weight: .semibold))
                                    .foregroundStyle(theme.text2)
                                Text("Pick another country")
                                    .font(RFont.text(12))
                                    .foregroundStyle(theme.text3)
                            }
                        }
                    }
                })
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
    }

    private var rules: some View {
        VStack(spacing: 0) {
            Bullet(text: "No code in 8 min? Refunded in full, automatically.")
            Bullet(text: "Numbers are single-use, fresh.")
            Bullet(text: "No guarantee for services with security checks.")
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private var stickyCTA: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [theme.bg.opacity(0), theme.bg],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 28)
            VStack {
                if let routeCost {
                    if insufficient {
                        PrimaryButton(
                            label: "Buy credits",
                            sub: "Need \(routeCost - state.balance) more",
                            icon: RIcon.plus,
                            action: openCredits
                        )
                    } else {
                        PrimaryButton(
                            label: state.isPlacingOrder ? "Getting number…" : "Get number",
                            sub: state.isPlacingOrder ? nil : "\(routeCost) cr",
                            icon: RIcon.bolt,
                            disabled: state.isPlacingOrder,
                            action: {
                                Task {
                                    await state.confirmGetNumber(
                                        using: OrdersAPI(client: api),
                                        wallet: WalletAPI(client: api)
                                    )
                                }
                            }
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
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
            .background(theme.bg)
        }
    }

}

private struct CoinIconBox: View {
    @Environment(\.theme) private var theme
    var body: some View {
        CoinIcon(size: 14, color: theme.text2)
            .frame(width: 32, height: 32)
            .background(theme.chipBg, in: .rect(cornerRadius: 9))
    }
}

/// One option of the Standard / Real SIM tier toggle.
private struct TierChip: View {
    @Environment(\.theme) private var theme
    let title: LocalizedStringKey
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(RFont.text(13, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(selected ? theme.bg : theme.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(selected ? theme.text : theme.chipBg, in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
