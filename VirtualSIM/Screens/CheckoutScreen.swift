import SwiftUI

/// The last screen before a credit is spent.
///
/// ── What the 2026-08 audit found here ────────────────────────────────────
///
/// **It contradicted itself about whether you are charged.** The title block
/// said *"You only pay if a code arrives"* and the Cost row, 117 lines later,
/// said *"N left after"*. The second one is true: `begin_order` debits inside
/// the same transaction that inserts the row, and the refund lands only when
/// the window closes with no code. Selling that as "you only pay on success"
/// means the balance drops in front of a user who was told it would not, which
/// is the single most trust-destroying thing a purchase screen can do. It is
/// now described as what it is — a **hold**.
///
/// **The refund was promised six times on one screen** (title, Expected row,
/// two Delivery rows, the Real-SIM row and a bullet). A guarantee repeated six
/// times reads as anxiety, not as reassurance, and it crowded out the
/// information each of those rows was supposed to carry. It is stated once,
/// next to the button that triggers the charge.
///
/// **The tier choice was two chips in a row's trailing edge** with its
/// reasoning hidden in an `.accessibilityHint`. It is the only control on the
/// screen that changes the price. It is now two full-width `OptionCard`s that
/// say what they buy.
struct CheckoutScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api

    var openServices: () -> Void
    var openCountries: () -> Void
    var openCredits: () -> Void

    @State private var appeared = false

    // Identical to the draft here (this screen only exists inside `.checkout`),
    // but routed through the one accessor so the raw `?? last…` shape — the one
    // that mispriced both pickers — has no remaining foothold to be copied from.
    private var service: Service { state.configuringService }
    private var country: Country { state.configuringCountry }
    private var standardCost: Int? { state.cost(for: service, country: country) }
    private var premiumCost: Int? { state.premiumCost(for: service, country: country) }
    private var realSimOnly: Bool { state.realSimOnly(for: service, country: country) }
    private var record: DeliveryRecord {
        state.deliveryRecord(for: service, country: country)
    }

    /// Why Real SIM is preselected here. Shown ONLY on measured evidence — the
    /// same rule the delivery badges follow. It says what was observed, not
    /// what Real SIM will achieve: we have never sold a premium order on this
    /// provider, so a rate promise would be unearned.
    private var tierAdvice: String? {
        if realSimOnly {
            return String(localized: "\(service.name) rejects internet numbers, so only Real SIM works here.")
        }
        guard premiumCost != nil else { return nil }
        if country.deliversPoorly {
            return String(localized: "Standard numbers in \(country.name) have been failing. We recommend Real SIM.")
        }
        if service.deliversPoorly {
            return String(localized: "\(service.name) often rejects standard numbers. We recommend Real SIM.")
        }
        return nil
    }
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

            VStack(spacing: 0) {
                topBar

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        titleBlock
                            .riseIn(appeared, index: 0)
                        receiptCard
                            .padding(.top, 20)
                            .riseIn(appeared, index: 1)
                        if premiumCost != nil {
                            tierSection
                                .padding(.top, 26)
                                .riseIn(appeared, index: 2)
                        }
                        DeliveryNotice(density: .full, service: service)
                            .padding(.top, 22)
                            .riseIn(appeared, index: 3)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)

                BottomBar { ctaBlock }
            }
        }
        .task { withAnimation(RMotion.content) { appeared = true } }
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
            .pressable(0.92)
            Spacer()
            CreditPill(value: state.balance, action: openCredits)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    /// Names the thing being bought, then states the billing mechanic ONCE and
    /// accurately.
    ///
    /// ⚠️ Do not restore "you only pay if a code arrives". Credits leave the
    /// wallet the moment the order row is written; a hold that is returned is
    /// what actually happens, and it is the version the Cost row below already
    /// agrees with.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            MicroLabel("Confirm")
            Text("Get a \(country.name) number")
                .displayType(30)
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text("We hold your credits for 8 minutes while the code comes through.")
                .font(RFont.text(15))
                .tracking(-0.2)
                .foregroundStyle(theme.text2)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var receiptCard: some View {
        Card(elevation: .lifted) {
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
                // Only render the wait row when it's MEASURED. With no sample
                // there is nothing honest to put here.
                //
                // The secondary states the SCOPE rather than repeating the
                // refund: `arrival_scope` distinguishes this service's own band
                // from the global one, and phrasing a global band as
                // service-specific is the exact overclaim `typicalWaitSentence`
                // exists to avoid.
                if state.showMetrics, let wait = service.typicalWaitShort {
                    // `String(localized:)` rather than a bare literal because
                    // ReceiptRow/ReceiptValue take `String`: Xcode's extractor
                    // sees String(localized:) but cannot see a plain literal
                    // handed to a String parameter, so the latter never reaches
                    // the catalog at all.
                    ReceiptRow(label: String(localized: "Typical wait"), leading: {
                        ReceiptIconBox(symbol: RIcon.clock)
                    }, trailing: {
                        ReceiptValue(primary: wait,
                                     secondaryText: service.arrivalScope == "service"
                                        ? String(localized: "Median for this service")
                                        : String(localized: "Median across all services"))
                    })
                }
                if state.showMetrics {
                    ReceiptRow(label: "Delivery", leading: {
                        ReceiptIconBox(symbol: RIcon.shield)
                    }, trailing: {
                        deliveryValue
                    })
                }
                ReceiptRow(label: "Cost", last: true, leading: {
                    CoinIconBox()
                }, trailing: {
                    VStack(alignment: .trailing, spacing: 1) {
                        if let routeCost {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("\(routeCost)")
                                    .font(RFont.display(19, weight: .bold))
                                    .tracking(-0.4)
                                    .foregroundStyle(theme.text)
                                    .monospacedDigit()
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
                })
            }
        }
    }

    /// Our own record for this exact route, as the one shared badge.
    ///
    /// A Real-SIM pick deliberately does NOT show it: every order we have ever
    /// placed was standard tier, so the measured number describes the random
    /// pool and quoting it under a premium pick would misattribute it. What it
    /// shows instead is what the tier buys — no rate, because there is no
    /// premium order on record to derive one from.
    @ViewBuilder
    private var deliveryValue: some View {
        if state.checkoutPremium, premiumCost != nil {
            ReceiptValue(primary: String(localized: "Named carrier"),
                         secondaryText: String(localized: "Never substituted"))
        } else {
            VStack(alignment: .trailing, spacing: 4) {
                SuccessBadge(record: record)
                // Stated as two separate literals rather than one ternary so
                // both reach the string catalog as `Text` keys.
                if record == .notTested {
                    Text("No orders on this route yet")
                        .font(RFont.text(12))
                        .foregroundStyle(theme.text3)
                } else {
                    // The window, exposed once per screen — a bare "3 of 7"
                    // has no timeframe and no owner.
                    Text("Our own orders, last 30 days")
                        .font(RFont.text(12))
                        .foregroundStyle(theme.text3)
                }
            }
        }
    }

    // MARK: - Number type

    /// Two full-width cards, each stating what it buys.
    ///
    /// ⚠️ **Real SIM may not claim a delivery rate.** No premium order has ever
    /// been placed on the current provider, so "Best delivery" — which this row
    /// used to say — was an unearned claim sitting three lines under a comment
    /// pointing out that no such evidence exists. What is defensible is the
    /// mechanism: a named mobile carrier, never quietly swapped for a VoIP
    /// number, and refunded if that carrier is dry. That is what
    /// `create-order`'s strict pin actually guarantees.
    private var tierSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            MicroLabel("Number type")

            // Standard is omitted entirely where the service refuses VoIP —
            // offering a tier that cannot deliver is worse than offering one
            // option.
            if !realSimOnly {
                OptionCard(
                    title: "Standard",
                    price: standardCost.map { "\($0) cr" },
                    detail: "Any number in stock for this route — usually an internet number.",
                    selected: !state.checkoutPremium,
                    action: { state.checkoutPremium = false })
            }

            OptionCard(
                title: "Real SIM",
                price: premiumCost.map { "\($0) cr" },
                detail: "A named mobile carrier, never swapped for an internet number. Refunded if that carrier has none left.",
                selected: state.checkoutPremium || realSimOnly,
                action: { state.checkoutPremium = true })

            if let advice = tierAdvice {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.warn)
                        .padding(.top, 1)
                    Text(advice)
                        .font(RFont.text(12, weight: .medium))
                        .foregroundStyle(theme.text)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(theme.warnSoft, in: .rect(cornerRadius: RRadius.sm))
            }
        }
    }

    // MARK: - Action

    /// The refund promise lives HERE and nowhere else on this screen.
    ///
    /// It is the sentence that makes the hold above safe to accept, so it
    /// belongs against the button that starts the hold — not scattered across
    /// five rows that each had their own job to do.
    private var ctaBlock: some View {
        VStack(spacing: 10) {
            if let routeCost {
                if insufficient {
                    PrimaryButton(
                        label: "Buy credits",
                        sub: String(localized: "Need \(routeCost - state.balance) more"),
                        icon: RIcon.plus,
                        action: {
                            RHaptic.select()
                            openCredits()
                        }
                    )
                } else {
                    PrimaryButton(
                        label: state.isPlacingOrder ? "Getting number…" : "Get number",
                        sub: state.isPlacingOrder ? nil : "\(routeCost) cr",
                        icon: RIcon.bolt,
                        disabled: state.isPlacingOrder,
                        action: {
                            RHaptic.select()
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
                // Enabled, and it opens the picker it names. A disabled button
                // whose subtitle is an instruction is the same anti-pattern the
                // e-mail CTAs on Home had: the screen's answer to "what now?"
                // refusing to do the thing it just told you to do.
                PrimaryButton(
                    label: "Pick another country",
                    sub: String(localized: "Not available here"),
                    icon: RIcon.globe,
                    action: {
                        RHaptic.select()
                        openCountries()
                    }
                )
            }

            Text("No code in 8 minutes → your credits come straight back.")
                .font(RFont.text(13, weight: .medium))
                .tracking(-0.1)
                .foregroundStyle(theme.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
