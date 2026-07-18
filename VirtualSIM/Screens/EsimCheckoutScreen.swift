import SwiftUI

struct EsimCheckoutScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    var openCredits: () -> Void

    private var plan: EsimPlan? { state.checkoutEsimPlan }
    private var cost: Int? { plan?.retailCredits }
    private var insufficient: Bool {
        guard let cost else { return false }
        return state.balance < cost
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    topBar
                    Text("Get eSIM")
                        .font(RFont.display(30, weight: .bold)).tracking(-0.8)
                        .foregroundStyle(theme.text)
                        .padding(.horizontal, 16).padding(.top, 4)
                    Text("Installs in seconds. Activate when you land.")
                        .font(RFont.text(15)).foregroundStyle(theme.text2)
                        .padding(.horizontal, 16).padding(.top, 2)
                    if let plan { receipt(plan) }
                    rules
                }
                .padding(.top, 6).padding(.bottom, 160)
            }
            .scrollIndicators(.hidden)
            cta
        }
    }

    private var topBar: some View {
        HStack {
            Button { state.flow = nil } label: {
                Image(systemName: RIcon.back).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text).frame(width: 36, height: 36)
                    .background(theme.chipBg, in: .circle)
            }.buttonStyle(.plain)
            Spacer()
            Text("Confirm").font(RFont.display(16, weight: .semibold)).foregroundStyle(theme.text)
            Spacer()
            CreditPill(value: state.balance, action: openCredits)
        }
        .padding(.horizontal, 16).padding(.bottom, 12)
    }

    private func receipt(_ plan: EsimPlan) -> some View {
        Card {
            VStack(spacing: 0) {
                row("Destination", value: "\(flagEmoji(plan.countryCode ?? ""))  \(plan.name)")
                row("Data", value: plan.dataLabel)
                row("Valid for", value: plan.validityLabel)
                row("Network", value: plan.speed ?? "—")
                Rectangle().fill(theme.sep).frame(height: 0.5).padding(.vertical, 4)
                HStack {
                    Text("Cost").font(RFont.text(14)).foregroundStyle(theme.text2)
                    Spacer()
                    if let cost {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(cost)").font(RFont.display(20, weight: .semibold)).foregroundStyle(theme.text)
                            Text("credits").font(RFont.text(13, weight: .medium)).foregroundStyle(theme.text2)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .padding(18)
        }
        .padding(.horizontal, 16).padding(.top, 18)
    }

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label).font(RFont.text(14)).foregroundStyle(theme.text2)
            Spacer()
            Text(value).font(RFont.text(14, weight: .medium)).foregroundStyle(theme.text)
        }
        .padding(.vertical, 11)
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: 0) {
            Bullet(text: "Delivered instantly as a QR code to install.")
            Bullet(text: "Validity starts when you activate the eSIM.")
            Bullet(text: "Keep your regular SIM for calls & texts.")
        }
        .padding(.horizontal, 20).padding(.top, 14)
    }

    private var cta: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [theme.bg.opacity(0), theme.bg], startPoint: .top, endPoint: .bottom).frame(height: 28)
            VStack {
                if let cost {
                    if insufficient {
                        PrimaryButton(label: "Buy credits", sub: "Need \(cost - state.balance) more",
                                      icon: RIcon.plus, action: openCredits)
                    } else {
                        PrimaryButton(label: state.isBuyingEsim ? "Getting eSIM…" : "Get eSIM",
                                      sub: state.isBuyingEsim ? nil : "\(cost) cr", icon: RIcon.bolt,
                                      disabled: state.isBuyingEsim) {
                            Task {
                                await state.confirmBuyEsim(using: EsimOrdersAPI(client: api),
                                                           wallet: WalletAPI(client: api))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 20).background(theme.bg)
        }
    }
}
