import SwiftUI

/// The code arrived at a temporary address.
///
/// Mirrors `OtpScreen`'s job for the email line. The review prompt no longer
/// fires from here — see `ContentView`'s foreground handler.
///
/// Its old failure state was `Text(code.isEmpty ? "—" : code)` in 34pt bold
/// with the card `.disabled` and nothing anywhere saying why. An em dash where
/// the code should be, on a screen titled "Code received", is a contradiction
/// the user has to resolve themselves — and the two ways to get here (the code
/// has not decoded yet, or this row genuinely carries none) call for opposite
/// responses.
struct EmailCodeScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    @Environment(IAPStore.self) private var iap
    @Environment(MailSubscriptionStore.self) private var mailStore

    @State private var copied = false
    @State private var appeared = false
    @State private var revealed = false
    @State private var showCredits = false
    @State private var showPaywall = false

    private var order: ServerEmailOrder? { state.activeEmailOrder }
    /// `hasCode` is the authority, never `status == .received` — a code can
    /// land on a row the provider already closed.
    private var code: String { order?.code ?? "" }
    private var hasCode: Bool { !code.isEmpty }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                badge
                codeCard
                    .padding(.top, 22)
                if let email = order?.email, !email.isEmpty {
                    Text(verbatim: email)
                        .font(RFont.mono(13))
                        .foregroundStyle(theme.text3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.top, 14)
                }
                Spacer()
                if hasCode {
                    Text("Paste it into \(order?.site ?? "") to finish verifying.")
                        .font(RFont.text(13))
                        .foregroundStyle(theme.text2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 12)
                }
                PrimaryButton(label: String(localized: "Done"), icon: RIcon.check) {
                    state.flow = nil
                }

                // Below Done, never above it: the code is what they came for.
                nextAddressCard
                    .padding(.top, 12)
                    .riseIn(revealed, index: 1)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .task(id: code) { await arrive() }
        // Both sheets are presented from HERE, not from `ContentView`. This
        // screen is a `fullScreenCover`, and a second modal raised from the
        // root while a cover is up does not appear at all — which is why
        // writing `state.showMailPaywall` from this screen would have looked
        // like a dead button. The env objects are injected explicitly for the
        // same reason `EnvBundle` exists: cover/sheet content does not
        // reliably inherit @Observable environment objects.
        .sheet(isPresented: $showCredits) {
            CreditsSheet(balance: state.balance, needed: creditShortfall) {
                await state.refreshWallet(using: WalletAPI(client: api))
                if let n = iap.lastGrantedCredits, n > 0 {
                    state.creditPurchaseBanner = n
                }
            }
            .environment(\.theme, theme)
            .environment(state)
            .environment(api)
            .environment(iap)
            .presentationDragIndicator(.visible)
            .presentationBackground(theme.bg)
        }
        .sheet(isPresented: $showPaywall) {
            MailPaywallScreen()
                .environment(\.theme, theme)
                .environment(state)
                .environment(mailStore)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(theme.bg)
        }
    }

    // MARK: - What the NEXT address costs

    /// The e-mail line's highest-volume moment, and until now it said nothing
    /// about money at all — below Done the screen was empty.
    ///
    /// Rules it keeps, inherited from `OtpScreen.balanceCard`:
    ///  • Secondary, below Done. Done stays this screen's primary action.
    ///  • Only over a DELIVERED code. Asking for money on a mailbox that never
    ///    received anything is selling a failure.
    ///  • States facts only — the balance, the live domain price, and
    ///    StoreKit's own `displayPrice`. Nothing price-related renders when
    ///    the products have not loaded.
    ///  • Never says "unlimited": `app_config.email_sub_daily_cap` refuses a
    ///    subscriber at `MailProduct.dailyAddressCap` a day and gmail is not
    ///    part of the subscription. Same honesty rule as `MailPaywallScreen`,
    ///    whose header explains why a bare "unlimited" is App Store 2.3.1.
    ///  • A subscriber is told nothing and asked for nothing.
    @ViewBuilder
    private var nextAddressCard: some View {
        if hasCode, let order {
            if order.costCredits > 0 {
                creditsCard
            } else if mailStore.isEntitled {
                subscriberLine
            } else {
                mailPlanCard(spent: freeAccess == .subscription)
            }
        }
    }

    /// What a free domain costs THIS account, from the one shared definition
    /// Home and the domain sheet also read.
    private var freeAccess: FreeEmailAccess {
        FreeEmailAccess.resolve(isEntitled: mailStore.isEntitled,
                                hasUsedFree: state.hasUsedFreeEmail)
    }

    /// StoreKit's own localized monthly price, nil until the products load.
    /// Never hardcoded — an assumed price is what drifted the credit ladder to
    /// $4.99-vs-€5.99 on its top product.
    private var monthlyPrice: String? { mailStore.displayPrice(for: .monthly) }

    private func mailPlanCard(spent: Bool) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(spent ? "That was your free address." : "Your first address is free.")
                        .font(RFont.text(14, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Group {
                        if spent {
                            Text("The next one needs the vSMS Mail plan.")
                        } else if let price = monthlyPrice {
                            Text("After that, up to \(MailProduct.dailyAddressCap) addresses a day is \(price)/mo.")
                        } else {
                            Text("After that, more addresses come with the vSMS Mail plan.")
                        }
                    }
                    .font(RFont.text(12))
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                }

                GhostButton(label: planButtonLabel, icon: RIcon.inbox) {
                    RHaptic.select()
                    // The same declaration the refused-order path makes, so
                    // the paywall and anything sized from `intent` agree about
                    // which product is being bought.
                    state.intent = .mailSubscription
                    showPaywall = true
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    /// The price only appears once StoreKit has answered.
    private var planButtonLabel: String {
        guard let price = monthlyPrice else {
            return String(localized: "See the Mail plan")
        }
        return String(localized: "See the Mail plan · \(price)/mo")
    }

    /// A subscriber gets a confirmation, not an ask.
    private var subscriberLine: some View {
        HStack(spacing: 7) {
            Image(systemName: RIcon.check)
                .font(.system(size: 11, weight: .bold))
            Text("vSMS Mail · up to \(MailProduct.dailyAddressCap) addresses a day")
                .font(RFont.text(12, weight: .medium))
        }
        .foregroundStyle(theme.text3)
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    /// Live price of another address on the same domain. gmail.com is a credit
    /// purchase for everyone, subscriber or not, which is why that path gets
    /// the credits card instead of the subscription ask.
    private var nextEmailCost: Int? {
        guard let domain = order?.domain else { return nil }
        return state.emailDomains.first { $0.domain == domain }?.credits
    }

    private var creditShortfall: Int {
        guard let nextEmailCost else { return 0 }
        return max(0, nextEmailCost - state.balance)
    }

    /// Renders only when they cannot already afford another one, and only when
    /// the live catalog carries a price for that domain — quoting what THIS
    /// order happened to cost as the price of the next one is an assumption,
    /// not a fact.
    @ViewBuilder
    private var creditsCard: some View {
        if let nextEmailCost, creditShortfall > 0, let domain = order?.domain {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        CoinIcon(size: 16, color: theme.text2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("You have \(state.balance) credits left")
                                .font(RFont.text(14, weight: .semibold))
                                .foregroundStyle(theme.text)
                            Text("Another \(domain) address costs \(nextEmailCost) credits.")
                                .font(RFont.text(12))
                                .foregroundStyle(theme.text2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }

                    GhostButton(label: String(localized: "Top up credits"),
                                icon: RIcon.plus) {
                        RHaptic.select()
                        // Declare the product before opening the sheet — its
                        // context card and preselected pack are both sized
                        // from `intent`.
                        state.intent = .email
                        showCredits = true
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
    }

    /// Auto-copy + haptic, on the same reasoning as `OtpScreen`: a verification
    /// code has one use and one destination, so making the user tap to move it
    /// is ceremony. Keyed on `code` rather than fired once on appear, because
    /// this screen can be opened *before* the code decodes and the digits then
    /// arrive underneath it.
    private func arrive() async {
        // Drives the entrance of everything below Done. Set here rather than
        // in `onAppear` so it also replays when the digits land underneath a
        // screen that was opened before the code decoded.
        withAnimation(RMotion.content) { revealed = true }
        guard hasCode else { return }
        if !appeared {
            appeared = true
            UIPasteboard.general.string = code
            copied = true
            RHaptic.success()
            Task {
                try? await Task.sleep(nanoseconds: 2_400_000_000)
                withAnimation(RMotion.content) { copied = false }
            }
        }
    }

    private var badge: some View {
        HStack(spacing: 7) {
            Image(systemName: hasCode ? RIcon.check : RIcon.clock)
                .font(.system(size: 12, weight: .bold))
            Text(hasCode ? "Code received" : "No code on this one")
                .font(RFont.text(13, weight: .semibold))
        }
        .foregroundStyle(hasCode ? theme.live : theme.text2)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(hasCode ? theme.liveSoft : theme.chipBg, in: .capsule)
    }

    @ViewBuilder
    private var codeCard: some View {
        if hasCode {
            Button {
                UIPasteboard.general.string = code
                RHaptic.copied()
                withAnimation(RMotion.content) { copied = true }
            } label: {
                VStack(spacing: 12) {
                    Text(verbatim: code)
                        .font(RFont.mono(34, weight: .bold))
                        .tracking(2)
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        Image(systemName: copied ? RIcon.check : RIcon.copy)
                            .font(.system(size: 12, weight: .semibold))
                        Text(copied ? "Copied" : "Tap to copy")
                            .font(RFont.text(13, weight: .medium))
                    }
                    .foregroundStyle(copied ? theme.live : theme.text2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
                .background(theme.elev, in: .rect(cornerRadius: RRadius.lg))
                .contentShape(.rect)
            }
            .pressable()
        } else {
            // Says which of the two situations this is, instead of rendering an
            // em dash and disabling itself. `wasRefunded` is only true for a
            // PAID activation that ended codeless, so the free tier is never
            // told about a refund it did not receive.
            Card {
                VStack(spacing: 8) {
                    Text(isSettled ? "This address never got a code" : "Fetching the code…")
                        .font(RFont.display(17, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(theme.text)
                        .multilineTextAlignment(.center)
                    Text(explanation)
                        .font(RFont.text(13))
                        .foregroundStyle(theme.text2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 30)
            }
        }
    }

    /// The order has reached a terminal state, so no code is coming.
    private var isSettled: Bool { order?.status.isTerminal ?? false }

    private var explanation: String {
        guard isSettled else {
            return String(localized: "One moment. Pulling it from the mailbox.")
        }
        return order?.wasRefunded == true
            ? String(localized: "The window closed before anything arrived, so your \(order?.costCredits ?? 0) credits went back to your balance.")
            : String(localized: "The window closed before anything arrived. Nothing was charged.")
    }
}
