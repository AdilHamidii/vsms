import SwiftUI

struct WaitingScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api

    let order: Order
    @State private var elapsed: Int = 0
    @State private var copied = false

    private var reservation: Int { max(60, Int(order.expiresAt.timeIntervalSince(order.createdAt))) }
    private var remaining: Int { max(0, Int(order.expiresAt.timeIntervalSinceNow)) }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    topBar
                    serviceStrip
                    numberCard
                    waitingCard
                    refundReassurance
                    if state.showMetrics { metric }
                }
                .padding(.top, 6)
                .padding(.bottom, 60)
            }
            .scrollIndicators(.hidden)
        }
        .task {
            // Tick the elapsed timer once per second.
            let start = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                elapsed = Int(Date().timeIntervalSince(start))
            }
        }
        .task {
            // Poll the server for the SMS every 4s while we're on this screen.
            let ordersAPI = OrdersAPI(client: api)
            let walletAPI = WalletAPI(client: api)
            while !Task.isCancelled, state.flow == .waiting {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await state.pollActiveOrder(using: ordersAPI, wallet: walletAPI)
            }
        }
    }

    private var topBar: some View {
        HStack {
            Color.clear.frame(width: 36, height: 36)
            Spacer()
            Text("Active rental")
                .font(RFont.display(16, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(theme.text)
            Spacer()
            Button {
                Task {
                    await state.cancelWaiting(
                        using: OrdersAPI(client: api),
                        wallet: WalletAPI(client: api)
                    )
                }
            } label: {
                Image(systemName: RIcon.close)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text2)
                    .frame(width: 36, height: 36)
                    .background(theme.chipBg, in: .circle)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var serviceStrip: some View {
        HStack(spacing: 10) {
            ServiceLogo(service: order.service, size: 32, radius: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(order.service.name)
                    .font(RFont.display(15, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(theme.text)
                HStack(spacing: 6) {
                    Text(order.country.flag).font(.system(size: 12))
                    Text(order.country.name)
                        .font(RFont.text(12))
                        .foregroundStyle(theme.text2)
                }
            }
            Spacer()
            StatusBadge(status: .waiting)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var numberCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                Text("YOUR NUMBER")
                    .font(RFont.text(12, weight: .medium))
                    .tracking(0.2)
                    .foregroundStyle(theme.text2)
                MonoText(order.number, size: 30, weight: .medium, color: theme.text)
                    .padding(.top, 8)
                HStack(spacing: 8) {
                    Button(action: copy) {
                        HStack(spacing: 7) {
                            Image(systemName: copied ? RIcon.check : RIcon.copy)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(copied ? theme.live : theme.text)
                            Text(copied ? "Copied" : "Copy number")
                                .font(RFont.text(14, weight: .medium))
                                .foregroundStyle(copied ? theme.live : theme.text)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(theme.chipBg, in: .rect(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task {
                            await state.pollActiveOrder(
                                using: OrdersAPI(client: api),
                                wallet: WalletAPI(client: api)
                            )
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: RIcon.refresh)
                                .font(.system(size: 13, weight: .semibold))
                            Text("Check now")
                                .font(RFont.text(13, weight: .medium))
                        }
                        .foregroundStyle(theme.text)
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .background(theme.chipBg, in: .rect(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 16)

                rerollActions
                    .padding(.top, 10)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 22)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    /// The two ways a number dies, each with a one-tap recovery.
    ///
    /// "Rejected" is the common case for high-security services: the site
    /// refuses the number at its signup form within ~20 seconds, so no timer
    /// can detect it — only the user knows. That path must move to a DIFFERENT
    /// country, because a rejection usually means the whole range is flagged.
    private var rerollActions: some View {
        HStack(spacing: 8) {
            rerollButton(
                title: "\(order.service.name) rejected it",
                icon: RIcon.close,
                differentCountry: true
            )
            rerollButton(
                title: "Try another number",
                icon: RIcon.refresh,
                differentCountry: false
            )
        }
    }

    private func rerollButton(title: String, icon: String,
                              differentCountry: Bool) -> some View {
        Button {
            Task {
                await state.rerollNumber(
                    using: OrdersAPI(client: api),
                    wallet: WalletAPI(client: api),
                    differentCountry: differentCountry
                )
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(RFont.text(13, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(theme.text2)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(theme.chipBg, in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(state.isPlacingOrder)
        .opacity(state.isPlacingOrder ? 0.5 : 1)
    }

    private var waitingCard: some View {
        Card {
            VStack(spacing: 0) {
                VStack(spacing: 18) {
                    WaitingAnimationView(kind: state.waitingAnimation)
                    VStack(spacing: 4) {
                        Text("Waiting for \(order.service.name) code…")
                            .font(RFont.display(17, weight: .semibold))
                            .tracking(-0.3)
                            .foregroundStyle(theme.text)
                        Text("Usually arrives in \(order.service.etaSeconds)s.")
                            .font(RFont.text(13))
                            .tracking(-0.1)
                            .foregroundStyle(theme.text2)
                    }
                }
                .padding(.vertical, 6)

                Rectangle().fill(theme.sep).frame(height: 0.5)
                    .padding(.top, 22)

                HStack(spacing: 0) {
                    timerCell(label: "ELAPSED", seconds: elapsed)
                    Rectangle().fill(theme.sep).frame(width: 0.5)
                    timerCell(label: "EXPIRES IN", seconds: remaining)
                }
                .padding(.top, 16)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 24)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private func timerCell(label: String, seconds: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(RFont.text(11, weight: .medium))
                .tracking(0.2)
                .foregroundStyle(theme.text2)
            MonoText(formatMMSS(seconds), size: 20, weight: .medium, color: theme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }

    private func formatMMSS(_ s: Int) -> String {
        String(format: "%02d:%02d", s / 60, s % 60)
    }

    // No SMS provider delivers 100% of the time (numbers get flagged, some
    // services block non-native SIMs). Make the safety net explicit so an
    // undelivered code costs the user nothing and doesn't read as a scam —
    // cancelWaiting (the ✕ above) issues a full refund.
    private var refundReassurance: some View {
        HStack(spacing: 8) {
            Image(systemName: RIcon.shield)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.text3)
            Text("You only pay for a code that arrives. Trying another number is free.")
                .font(RFont.text(12))
                .tracking(-0.1)
                .foregroundStyle(theme.text3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
    }

    private var metric: some View {
        HStack(spacing: 8) {
            Image(systemName: RIcon.spark)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.text3)
            Text("\(order.service.successRate)% of \(order.service.name) codes arrive in under \(order.service.etaSeconds + 8)s.")
                .font(RFont.text(12))
                .tracking(-0.1)
                .foregroundStyle(theme.text3)
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
    }

    private func copy() {
        UIPasteboard.general.string = order.number
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            copied = false
        }
    }
}
