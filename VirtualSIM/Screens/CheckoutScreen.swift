import SwiftUI

struct CheckoutScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state

    var openServices: () -> Void
    var openCountries: () -> Void
    var openCredits: () -> Void

    private var service: Service { state.checkoutService ?? state.lastService }
    private var country: Country { state.checkoutCountry ?? state.lastCountry }
    private var insufficient: Bool { state.balance < service.cost }

    var body: some View {
        ZStack(alignment: .bottom) {
            theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    topBar
                    titleBlock
                    receiptCard
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
            Text("Number is reserved for 20 minutes.")
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
                    FlagBox(flag: country.flag, size: 32, radius: 9)
                }, trailing: {
                    ReceiptValue(primary: country.name, secondary: {
                        HStack(spacing: 4) {
                            MonoText(country.code, size: 11, color: theme.text2)
                            Text("·").foregroundStyle(theme.text3)
                            Text(stockText(country.stock))
                                .font(RFont.text(12))
                                .foregroundStyle(theme.text2)
                        }
                    }, chev: true)
                })
                if state.showMetrics {
                    ReceiptRow(label: "Expected", leading: {
                        ReceiptIconBox(symbol: RIcon.clock)
                    }, trailing: {
                        ReceiptValue(primary: "~\(service.etaSeconds) sec",
                                     secondaryText: "\(service.successRate)% delivery success")
                    })
                }
                ReceiptRow(label: "Cost", last: true, leading: {
                    CoinIconBox()
                }, trailing: {
                    HStack(spacing: 8) {
                        VStack(alignment: .trailing, spacing: 1) {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("\(service.cost)")
                                    .font(RFont.display(17, weight: .semibold))
                                    .tracking(-0.3)
                                    .foregroundStyle(theme.text)
                                Text("credits")
                                    .font(RFont.text(13, weight: .medium))
                                    .foregroundStyle(theme.text2)
                            }
                            Text("\(state.balance - service.cost) left after")
                                .font(RFont.text(12))
                                .foregroundStyle(theme.text2)
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
            Bullet(text: "Auto-refund if no SMS within 20 min.")
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
                if insufficient {
                    PrimaryButton(
                        label: "Buy credits",
                        sub: "Need \(service.cost - state.balance) more",
                        icon: RIcon.plus,
                        action: openCredits
                    )
                } else {
                    PrimaryButton(
                        label: "Get number",
                        sub: "\(service.cost) cr",
                        icon: RIcon.bolt,
                        action: { state.confirmGetNumber() }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
            .background(theme.bg)
        }
    }

    private func stockText(_ level: StockLevel) -> String {
        switch level { case .high: "High stock"; case .medium: "Medium stock"; case .low: "Low stock" }
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
