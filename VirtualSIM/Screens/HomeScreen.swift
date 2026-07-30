import SwiftUI

struct HomeScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api

    var openServices: () -> Void = {}
    var openCountries: () -> Void = {}
    var openEmailDomains: () -> Void = {}
    var openCredits: () -> Void = {}
    var onStart: () -> Void = {}
    var onStartEmail: () -> Void = {}
    var onTapOrder: (Order) -> Void = { _ in }
    var onSeeAllOrders: () -> Void = {}
    var onOpenEsim: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 6)

                // Today's credit, claimed by an explicit tap. Sits above the
                // hero so it's the first thing a returning user sees.
                if let daily = state.dailyCredit, daily.available {
                    dailyClaimCard(daily)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

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
                        title: String(localized: "+\(bonus.credits) credits added"),
                        // Name tomorrow's amount when it's bigger — the whole
                        // point of the ladder is having a next tier to reach.
                        sub: dailyBonusSub(bonus),
                        dismiss: { state.dailyCreditBanner = nil })
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                modeSwitch
                    .padding(.horizontal, 16)
                    .padding(.top, 18)

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

                // eSIM lived only behind the 2nd tab. It is the healthier of
                // the two product lines by every measure we have — 4x margin,
                // ~100% delivery, and 9 of its 12 buyers never ordered SMS at
                // all — so hiding it behind a tab was costing the line its
                // only discovery path.
                if !state.esimCountries.isEmpty {
                    esimTeaser
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

    private func claimDaily() async {
        await state.claimDailyCredit(using: WalletAPI(client: api))
        withAnimation(.easeOut(duration: 0.25)) { }
    }

    /// The daily claim. A button, not an automatic grant — collecting is the
    /// habit, and a balance that changes on its own is invisible.
    private func dailyClaimCard(_ daily: DailyCreditStatus) -> some View {
        HStack(spacing: 12) {
            CoinIcon(size: 20, color: theme.live)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(daily.credits ?? 1) free credits today")
                    .font(RFont.text(14, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text((daily.streak ?? 0) >= 1
                     ? String(localized: "Day \((daily.streak ?? 0) + 1) of your streak")
                     : String(localized: "Come back daily — it pays more each day"))
                    .font(RFont.text(12))
                    .foregroundStyle(theme.text2)
            }
            Spacer(minLength: 0)
            Button {
                Task { await claimDaily() }
            } label: {
                Group {
                    if state.isClaimingDaily {
                        ProgressView().tint(theme.onInk)
                    } else {
                        Text("Claim")
                            .font(RFont.display(14, weight: .semibold))
                            .tracking(-0.2)
                    }
                }
                .foregroundStyle(theme.onInk)
                .frame(width: 78, height: 38)
                .background(theme.ink, in: .rect(cornerRadius: 12))
            }
            .buttonStyle(PressScaleStyle())
            .disabled(state.isClaimingDaily)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(theme.liveSoft, in: .rect(cornerRadius: 14))
    }

    /// Streak line for the daily grant. Only promises a bigger tomorrow when
    /// the server says the next tier really is larger.
    private func dailyBonusSub(_ bonus: (credits: Int, streak: Int, next: Int?)) -> String {
        if let next = bonus.next, next > bonus.credits {
            return String(localized: "Day \(bonus.streak) — come back tomorrow for +\(next).")
        }
        if bonus.streak >= 2 {
            return String(localized: "\(bonus.streak) days in a row — come back tomorrow for +\(bonus.next ?? bonus.credits).")
        }
        return String(localized: "Come back daily — the streak pays more each day.")
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
                Text(state.emailMode ? "Get an email." : "Get a number.")
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

    /// Delivery record for the currently-selected route. Never nil — an
    /// untested route says so rather than showing nothing. See DeliveryRecord.
    private var routeRecord: DeliveryRecord {
        state.deliveryRecord(for: state.lastService, country: state.lastCountry)
    }

    /// A user who has never placed an order — show them a "start here" framing
    /// and, when their free credits cover the default, say so.
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
            Text("Your free credits cover this — first number's on us.")
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
                            // An email address has no country and no dial code,
                            // so the SMS subtitle would be inventing both.
                            if state.emailMode {
                                Text(verbatim: state.emailDomain?.displayName ?? "—")
                                    .font(RFont.text(13))
                                    .foregroundStyle(theme.text2)
                            } else {
                                HStack(spacing: 6) {
                                    FlagImage(country: state.lastCountry, size: 14, radius: 3)
                                    Text(state.lastCountry.name)
                                        .font(RFont.text(13))
                                        .foregroundStyle(theme.text2)
                                    Text("·").foregroundStyle(theme.text3)
                                    MonoText(state.lastCountry.dialCode, size: 12, color: theme.text2)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 4) {
                            if state.emailMode {
                                emailHeroPrice
                            } else if let routeCost {
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
                    // The metrics row is SMS-only ON PURPOSE. Typical wait,
                    // "No code → Refunded" and the delivery record are all
                    // measured for phone numbers on a specific route. Rendering
                    // them on an email purchase would restate another product's
                    // evidence as this one's — the same mistake as quoting the
                    // seed etaSeconds, and we have measured nothing for email
                    // yet. Silence is the honest answer until we have.
                    if state.showMetrics && !state.emailMode {
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
                            // Always a delivery record, never an omission.
                            // Colour still signals CONFIDENCE: "Not tested" is
                            // muted, and only a measured record earns green.
                            switch routeRecord {
                            case .notTested:
                                Metric(label: "Delivery", value: "Not tested", accent: theme.text3)
                            case let .measured(codes, attempts):
                                Metric(label: "Delivery",
                                       value: "\(codes) of \(attempts)",
                                       accent: attempts > 0 && 100 * codes / attempts >= 70
                                           ? theme.live
                                           : (attempts > 0 && 100 * codes / attempts >= 40
                                              ? theme.warn : theme.fail))
                            }
                        }
                        .padding(.top, 14)
                    }
                    Group {
                        if state.emailMode { emailCTA } else { heroCTA }
                    }
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

    /// Numbers / E-mails. A segmented control rather than a fifth tab: the two
    /// products share the service picker and differ only in what they deliver,
    /// so they belong on one screen.
    private var modeSwitch: some View {
        @Bindable var s = state
        return SegmentedTabs(
            selection: $s.emailMode,
            items: [(tag: false, label: String(localized: "Number"), count: nil),
                    (tag: true,  label: String(localized: "E-mail"), count: nil)]
        )
    }

    private var pickersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(label: "Change")
            HStack(spacing: 10) {
                PickerCard(label: "Service", value: state.lastService.name, icon: {
                    ServiceLogo(service: state.lastService, size: 32, radius: 9)
                }, onTap: openServices)
                if state.emailMode {
                    // The domain replaces the country: an email address has no
                    // country, and showing one would imply a choice that does
                    // not exist.
                    PickerCard(label: "Domain",
                               value: state.emailDomain?.displayName
                                   ?? String(localized: "Choose"),
                               icon: {
                        Image(systemName: "envelope.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.ink)
                            .frame(width: 32, height: 32)
                            .background(theme.inkSoft, in: .rect(cornerRadius: 9))
                    }, onTap: openEmailDomains)
                } else {
                    PickerCard(label: "Country", value: state.lastCountry.name, icon: {
                        FlagImage(country: state.lastCountry, size: 32, radius: 9)
                    }, onTap: openCountries)
                }
            }
        }
    }

    /// Price in the email hero. "Free" is a word, not a 0 — rendering "0 cr"
    /// reads as a broken price rather than a gift.
    @ViewBuilder
    private var emailHeroPrice: some View {
        if let dom = state.emailDomain {
            if dom.isFree {
                Text("Free")
                    .font(RFont.display(19, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(theme.live)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(dom.credits)")
                        .font(RFont.display(22, weight: .semibold))
                        .tracking(-0.5)
                        .foregroundStyle(theme.text)
                    Text("cr")
                        .font(RFont.text(13, weight: .medium))
                        .foregroundStyle(theme.text2)
                }
            }
        } else {
            Text("—")
                .font(RFont.display(22, weight: .semibold))
                .foregroundStyle(theme.text3)
        }
    }

    /// CTA for the email line.
    ///
    /// Three distinct states, and the differences matter: a service with no
    /// domain cannot offer email AT ALL (11 of 265), a domain can be out of
    /// stock, and the free tier must never render a credit price.
    @ViewBuilder
    private var emailCTA: some View {
        if !state.emailSupported {
            PrimaryButton(label: "Not available for this service",
                          sub: "Pick another service",
                          icon: RIcon.bolt, disabled: true, action: {})
        } else if let dom = state.emailDomain, dom.inStock {
            if dom.credits > 0 && state.balance < dom.credits {
                PrimaryButton(label: "Buy credits",
                              sub: "Need \(dom.credits - state.balance) more",
                              icon: RIcon.plus, action: openCredits)
            } else {
                PrimaryButton(
                    label: "Get email address",
                    sub: dom.isFree ? String(localized: "Free") : "\(dom.credits) cr",
                    icon: RIcon.bolt,
                    disabled: state.isBuyingEmail,
                    action: onStartEmail
                )
            }
        } else {
            PrimaryButton(label: "Choose a domain",
                          sub: "Tap Domain below",
                          icon: RIcon.bolt, disabled: true, action: {})
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

    /// Entry point into the eSIM line from Home.
    ///
    /// Quotes the CHEAPEST plan actually in the catalog rather than a made-up
    /// "from" price, and names the real country count. Both come from
    /// `state.esimCountries`, so an empty or unpriced catalog renders nothing
    /// instead of "from 0 credits".
    private var esimTeaser: some View {
        let cheapest = state.esimCountries.map(\.fromCredits).min() ?? 0
        let countries = state.esimCountries.count
        return Button(action: onOpenEsim) {
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(theme.text2)
                    .frame(width: 40, height: 40)
                    .background(theme.chipBg, in: .rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Travelling? Get data abroad")
                        .font(RFont.display(15, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(theme.text)
                    Text("eSIM plans in \(countries) countries — from \(cheapest) cr")
                        .font(RFont.text(12))
                        .foregroundStyle(theme.text2)
                }
                Spacer(minLength: 0)
                Image(systemName: RIcon.chev)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.text3)
            }
            .padding(14)
            .background(theme.elev, in: .rect(cornerRadius: 18))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var trustFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: RIcon.shield)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.text3)
            // The 8-minute window is the SMS order's. An email activation runs
            // ~20 minutes (measured), and a FREE one has nothing to refund —
            // so promising a refund there would be meaningless at best.
            Text(state.emailMode
                 ? (state.emailDomain?.isFree == true
                    ? String(localized: "Free addresses cost you nothing if no code arrives.")
                    : String(localized: "No code in 20 minutes → refunded automatically."))
                 : String(localized: "No code in 8 minutes → refunded automatically."))
                .font(RFont.text(12))
                .tracking(-0.1)
                .foregroundStyle(theme.text3)
        }
    }
}
