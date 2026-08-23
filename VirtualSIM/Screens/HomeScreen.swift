import SwiftUI

/// The screen 78% of users die on.
///
/// ── What the 2026-08 audit found, and what changed ───────────────────────
///
/// **Nothing on it said what the product does.** The top 60pt was a time-of-day
/// greeting and the words "Get a number." — a command, not a proposition, and
/// ambiguous besides ("a number" for what?). Both are gone. The eyebrow now
/// names the outcome and the headline names the specific next action, with the
/// selected service in it.
///
/// **There were THREE stacked decision surfaces and one was a pure
/// duplicate**: the mode switch, the hero (service + country + price + metrics
/// + CTA), and then a section literally headed "CHANGE" holding the same
/// service and the same country as two more tappable cards. That section is
/// deleted. The hero's service and country are now tappable `ReceiptRow`s — the
/// component Checkout already uses for exactly this — which removes ~120pt, a
/// whole decision layer, and the visual discontinuity between the two screens.
///
/// **"Start here" / "Last used" / "Change" were unactionable headers.**
/// "CHANGE" is a verb with no object; "LAST USED" describes the past on the
/// app's only buy button. All three deleted.
///
/// **Two disabled buttons gave instructions.** In e-mail mode the CTA read
/// "Choose a domain / Tap Domain below" and "Not available for this service /
/// Pick another service" — a dead control telling you to go tap something else,
/// while the thing it named was the section this change deleted. Both are now
/// live buttons that open what they name.
///
/// **`freeCreditHint` was dead code.** It required `isFirstRun && balance >=
/// routeCost`, and the signup grant is 0, so the only first-run users who could
/// see it were ones who had already paid. Its slot now holds the three-step
/// explainer, shown to first-run users who are SHORT — which is the state
/// almost everyone who never orders is actually in.
struct HomeScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    // Home renders the e-mail price, so it needs the same entitlement input the
    // domain sheet uses. Without it Home said "Free" to a user whose one free
    // address was already spent, and the tap was refused into a paywall.
    @Environment(MailSubscriptionStore.self) private var mailStore

    var openServices: () -> Void = {}
    var openCountries: () -> Void = {}
    var openEmailDomains: () -> Void = {}
    var openCredits: () -> Void = {}
    var onStart: () -> Void = {}
    var onStartEmail: () -> Void = {}
    var onTapOrder: (Order) -> Void = { _ in }
    var onSeeAllOrders: () -> Void = {}
    var onOpenEsim: () -> Void = {}

    @State private var appeared = false
    /// Presented from HERE, not through `state.showMailPaywall`. The root
    /// sheet is unreachable from any screen under a `fullScreenCover`, and
    /// this keeps Home on the same pattern as `EmailCodeScreen`.
    @State private var showMailPaywall = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .riseIn(appeared, index: 0)

                // First on the screen on purpose: an announcement is the
                // owner telling users something about the service right now
                // (an outage, a provider switch), which outranks everything.
                if let announcement = state.visibleAnnouncement {
                    AnnouncementBanner(announcement: announcement) {
                        state.dismissAnnouncement()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // (The daily-credit claim card lived here until 2026-08-02 —
                // the feature was disabled server-side and then removed.)

                if let purchased = state.creditPurchaseBanner {
                    creditBanner(
                        title: String(localized: "+\(purchased) credits added"),
                        sub: String(localized: "Your purchase is confirmed."),
                        dismiss: { state.creditPurchaseBanner = nil })
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                modeSwitch
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .riseIn(appeared, index: 1)

                heroSection
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .riseIn(appeared, index: 2)

                if !state.orders.isEmpty {
                    recentSection
                        .padding(.horizontal, 16)
                        .padding(.top, 26)
                        .riseIn(appeared, index: 3)
                }

                // eSIM lived only behind the 2nd tab. It is the healthier of
                // the two product lines by every measure we have — 4x margin,
                // ~100% delivery, and 9 of its 12 buyers never ordered SMS at
                // all — so hiding it behind a tab was costing the line its
                // only discovery path.
                //
                // ⚠️ Gated on `!esimPaused`. The line has been paused since
                // 2026-07-31 and while it is, this teaser advertised a product
                // whose own tab answers "eSIMs are unavailable right now" — an
                // ad for a dead end, on the screen where first-session users
                // are already deciding whether the app works.
                if !state.esimCountries.isEmpty, !state.esimPaused {
                    esimTeaser
                        .padding(.horizontal, 16)
                        .padding(.top, 26)
                        .riseIn(appeared, index: 4)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 140)
        }
        .scrollIndicators(.hidden)
        .task { withAnimation(RMotion.content) { appeared = true } }
        // The segmented control is a shared component with no haptic of its
        // own; switching product line is the biggest state change on the
        // screen and should be felt.
        .onChange(of: state.emailMode) { _, _ in RHaptic.select() }
        // Env objects injected explicitly: sheet content does not reliably
        // inherit @Observable environment objects — the reason `EnvBundle`
        // exists at all.
        .sheet(isPresented: $showMailPaywall) {
            MailPaywallScreen()
                .environment(\.theme, theme)
                .environment(state)
                .environment(mailStore)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(theme.bg)
        }
    }

    /// Confirms credits actually landed after a purchase. Without a visible
    /// acknowledgement, a successful buy looks exactly like a failed one.
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
        .background(theme.liveSoft, in: .rect(cornerRadius: RRadius.sm))
    }

    // MARK: - What this app is for

    /// Eyebrow states the OUTCOME; headline states the next action.
    ///
    /// The greeting it replaced is the purest example of the problem: it took
    /// the most valuable 60pt on the app's entry screen, was different on every
    /// visit, and told the user nothing they did not already know. Median
    /// signup → first order is ~2 minutes, so this block is very close to the
    /// entire pitch.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                eyebrow
                Spacer(minLength: 0)
                CreditPill(value: state.balance, action: openCredits)
            }
            headline
        }
    }

    // Both of these are written as an if/else over two `Text("literal")` calls
    // rather than one ternary. A ternary between two string literals resolves
    // to `String`, which selects `Text.init<S: StringProtocol>` — so the copy
    // silently stops being localized and never reaches the catalog at all.
    @ViewBuilder
    private var eyebrow: some View {
        if state.emailMode {
            MicroLabel("Sign up without your real e-mail").lineLimit(2)
        } else {
            MicroLabel("Verify any account without your real number").lineLimit(2)
        }
    }

    @ViewBuilder
    private var headline: some View {
        if state.emailMode {
            Text("Get an e-mail for \(state.lastService.name)")
                .displayType(28)
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
        } else if isSuggestion {
            // Naming the service here would be the same overclaim the hero
            // below makes: the app picked it, the user has not, and the CTA
            // underneath refuses to sell it. State the product instead.
            Text("Get a verification number")
                .displayType(28)
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Get a number for \(state.lastService.name)")
                .displayType(28)
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The hero is showing the app's OWN pre-selection, which the CTA will not
    /// sell (see `heroCTA` and `AppState.needsServiceChoice`).
    ///
    /// Everything priced or graded is suppressed in this state. It used to
    /// render "TikTok · 2 cr · worked 1 of 4 · Hit or miss" above a button
    /// reading "Choose a service" — four assertions about a route that is not
    /// on offer, two of them measurements, all of them about a service the user
    /// never named. `from_default` orders deliver 2.4% against 17.2% for chosen
    /// ones, so this is not a cosmetic mismatch: it is evidence attached to the
    /// wrong decision.
    private var isSuggestion: Bool { state.needsServiceChoice && !state.emailMode }

    private var routeCost: Int? {
        state.cost(for: state.lastService, country: state.lastCountry)
    }

    /// The vendor's published rate for this route's pool, or nil when they
    /// publish none — in which case the hero renders no delivery figure at all.
    /// Our own record is not shown here any more; see the header of
    /// `SuccessBadge.swift`.
    private var routePoolRate: Int? {
        state.poolRate(for: state.lastService, country: state.lastCountry)
    }

    /// A user who has never placed an order.
    private var isFirstRun: Bool { state.orders.isEmpty }

    /// First run AND cannot afford the route in front of them — including the
    /// `nil` price case, which is also "you cannot buy this right now".
    ///
    /// This is the condition `freeCreditHint` should have had. With the signup
    /// grant at 0 this is where essentially every new user stands, and 159 of
    /// 203 signups have never placed a single order while holding idle credits.
    private var needsExplainer: Bool {
        guard isFirstRun else { return false }
        guard let routeCost else { return true }
        return state.balance < routeCost
    }

    // MARK: - Money in plain words
    //
    // 🔴 THERE IS DELIBERATELY NO FIAT APPROXIMATION HERE ANY MORE.
    //
    // `approxMoney` used to render "about €2,29" under the credit cost. It was
    // accurate — arithmetic on our own live StoreKit price — and it was the
    // wrong thing to show. The user is deciding whether to spend CREDITS they
    // already hold; printing the cash value re-frames a one-tap decision as a
    // purchase decision and invites the comparison "is this code worth €2.29
    // to me", which is exactly the thought that stops the tap.
    //
    // Credits exist so the spend feels like a token, not a payment. Money
    // belongs on the paywall, where the user really is buying, and nowhere
    // else. Do not reintroduce it on a cost row.

    // MARK: - Hero

    /// One object: what you are buying, what it costs, what we know about it,
    /// and the button. Service and country are rows INSIDE it rather than a
    /// second set of cards below it.
    private var heroSection: some View {
        HeroCard {
            VStack(alignment: .leading, spacing: 0) {
                ReceiptRow(label: "Service", onTap: openServices, leading: {
                    ServiceLogo(service: state.lastService, size: 32, radius: 9)
                }, trailing: {
                    // The secondary line says WHOSE choice this is. Without it
                    // the row is indistinguishable from a service the user
                    // picked, which is the whole confusion this state creates.
                    ReceiptValue(primary: state.lastService.name,
                                 secondaryText: isSuggestion
                                     ? String(localized: "Suggested. Tap to change")
                                     : state.lastService.category,
                                 chev: true)
                })

                if state.emailMode {
                    // The domain replaces the country: an e-mail address has no
                    // country, and showing one would imply a choice that does
                    // not exist.
                    ReceiptRow(label: "Domain", onTap: openEmailDomains, leading: {
                        Image(systemName: "envelope.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.accent2)
                            .frame(width: 32, height: 32)
                            .background(theme.inkSoft, in: .rect(cornerRadius: 9))
                    }, trailing: {
                        ReceiptValue(primary: state.emailDomain?.displayName
                                         ?? String(localized: "Choose one"),
                                     chev: true)
                    })
                } else {
                    ReceiptRow(label: "Country", onTap: openCountries, leading: {
                        FlagImage(country: state.lastCountry, size: 32, radius: 9)
                    }, trailing: {
                        ReceiptValue(primary: state.lastCountry.name, secondary: {
                            MonoText(state.lastCountry.dialCode, size: 11, color: theme.text2)
                        }, chev: true)
                    })
                }

                ReceiptRow(label: "Cost", last: true, leading: {
                    CoinIconBox()
                }, trailing: {
                    priceValue
                })

                evidenceStrip

                // VStack, NOT Group: a modifier on a `Group` is applied to each
                // child individually, so `.padding(.top, 16)` here would space
                // the explainer, the button and the promise apart by 16 each
                // instead of insetting the block once.
                VStack(spacing: 0) {
                    if needsExplainer { explainer.padding(.bottom, 16) }

                    if state.emailMode { emailCTA } else { heroCTA }

                    // The ONE refund promise on this screen, and the sentence
                    // that used to be `trustFooter`: 12pt at 38% opacity
                    // (~2.5:1, below WCAG AA) sitting below the fold, i.e. the
                    // most reassuring thing the app can say rendered as the
                    // least legible thing on the page. It is also why the
                    // metrics row no longer carries a "No code → Refunded"
                    // cell: a refund POLICY formatted identically to a
                    // MEASUREMENT makes the row assert that the policy is one.
                    Text(refundPromise)
                        .font(RFont.text(13, weight: .medium))
                        .tracking(-0.1)
                        .foregroundStyle(theme.text2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                }
                .padding(.horizontal, 16)
                // Always 16 here, and `evidenceStrip` deliberately adds no
                // bottom padding of its own — otherwise the gap above the CTA
                // would differ between SMS (strip present) and e-mail (absent).
                .padding(.top, 16)
                .padding(.bottom, 18)
            }
        }
    }

    /// The 8-minute window is the SMS order's. An e-mail activation runs
    /// ~20 minutes (measured), and a FREE one has nothing to refund — so
    /// promising a refund there would be meaningless at best.
    private var refundPromise: String {
        guard state.emailMode else {
            return String(localized: "No code in 8 minutes → refunded automatically.")
        }
        if state.emailDomain?.isFree == true {
            // ⚠️ NOT unconditionally "free". The one free address is per
            // account for life, so this promised no cost to a user who had
            // already spent theirs and would be refused into the paywall.
            switch freeEmailAccess {
            case .free:
                return String(localized: "Free addresses cost you nothing if no code arrives.")
            case .included:
                return String(localized: "Addresses are included with your subscription.")
            case .subscription:
                return String(localized: "You've used your free address. More come with a subscription.")
            }
        }
        return String(localized: "No code in 20 minutes → refunded automatically.")
    }

    @ViewBuilder
    private var priceValue: some View {
        if state.emailMode {
            emailHeroPrice
        } else if isSuggestion {
            // No price, because nothing is on sale yet. A figure here is a
            // quote for a route the button will not buy, and the user reads it
            // as what THEIR verification will cost.
            VStack(alignment: .trailing, spacing: 1) {
                Text("—")
                    .font(RFont.display(22, weight: .bold))
                    .foregroundStyle(theme.text3)
                Text("Once you pick a service")
                    .font(RFont.text(12))
                    .foregroundStyle(theme.text3)
            }
        } else if let routeCost {
            VStack(alignment: .trailing, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(routeCost)")
                        .font(RFont.display(22, weight: .bold))
                        .tracking(-0.5)
                        .foregroundStyle(theme.text)
                        .monospacedDigit()
                    Text("cr")
                        .font(RFont.text(13, weight: .medium))
                        .foregroundStyle(theme.text2)
                }
            }
        } else {
            VStack(alignment: .trailing, spacing: 1) {
                Text("Unavailable")
                    .font(RFont.display(15, weight: .semibold))
                    .foregroundStyle(theme.text2)
                Text("Pick another country")
                    .font(RFont.text(12))
                    .foregroundStyle(theme.text3)
            }
        }
    }

    // MARK: - Evidence

    /// Two FIXED-WIDTH cells and an odds chip.
    ///
    /// The old row was three cells separated by `Spacer()`, so the columns
    /// re-flowed with content length and nothing lined up between visits — and
    /// one of the three was the refund POLICY, formatted exactly like the two
    /// measurements beside it. Fixed widths mean the layout is the same every
    /// time the screen is opened, which is what makes a value worth glancing at.
    ///
    /// SMS-only ON PURPOSE. Typical wait and the delivery record are measured
    /// for phone numbers on a specific route; rendering them on an e-mail
    /// purchase would restate another product's evidence as this one's, and we
    /// have measured nothing for e-mail yet.
    ///
    /// ⚠️ E-mail mode gets a SENTENCE, not silence. Switching product line used
    /// to delete this whole block with no explanation, so the screen quietly
    /// lost its evidence and looked like it had simply broken. Saying that we
    /// have not measured e-mail yet is both the honest answer and the reason
    /// the row is gone.
    @ViewBuilder
    private var evidenceStrip: some View {
        // ⚠️ Nothing measured is rendered for a route the user did not choose.
        // The network rate is a real measurement about a real route — it is
        // simply not about the purchase this screen is offering, which is
        // currently no purchase at all.
        if isSuggestion {
            EmptyView()
        } else if state.showMetrics, state.emailMode {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle()
                    .fill(theme.sep)
                    .frame(height: 0.5)
                Text("No delivery record yet. E-mail is new and we only show what we've measured.")
                    .font(RFont.text(12))
                    .foregroundStyle(theme.text3)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
            }
        } else if state.showMetrics, !state.emailMode {
            VStack(alignment: .leading, spacing: 0) {
                // Full-bleed, matching the rules ReceiptRow draws above it —
                // an inset rule here would read as a second, unrelated card.
                Rectangle()
                    .fill(theme.sep)
                    .frame(height: 0.5)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(alignment: .leading, spacing: 6) {
                            MicroLabel("Typical wait")
                            // Measured p50, or "—" when we have no sample.
                            // Never the seed etaSeconds.
                            Text(state.lastService.typicalWaitShort ?? "—")
                                .font(RFont.display(16, weight: .semibold))
                                .tracking(-0.3)
                                .foregroundStyle(theme.text)
                        }
                        .frame(width: 100, alignment: .leading)

                        // Only the network meter now, and only when the vendor
                        // publishes a rate for this pool. The "Delivery · 30
                        // days" label went with our own record: it was that
                        // record's window, and the meter carries its own in the
                        // word `network` it renders inline.
                        if let routePoolRate {
                            VStack(alignment: .leading, spacing: 6) {
                                MicroLabel("Delivery")
                                NetworkRateMeter(pct: routePoolRate)
                            }
                        // `minWidth`, not a fixed `width`. At 138pt the network
                        // meter fits in English (~120pt) and German, and
                        // TRUNCATES in Japanese, where "network" is
                        // ネットワーク — the widest label in the row is the one
                        // that says whose number this is, so clipping it is
                        // exactly the wrong thing to lose. There is ~123pt of
                        // slack beside this column on a 393pt screen, so
                        // letting it take its ideal width costs nothing.
                        .frame(minWidth: 138, alignment: .leading)
                        }

                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
            }
        }
    }

    // The plain-English odds chip ("Rarely works for Facebook", "Hit or miss")
    // was removed on 2026-08-22 with every other rendering of our own delivery
    // record — see the header of `SuccessBadge.swift`. `Service.deliversPoorly`
    // still exists and still steers checkout's tier default; it is simply no
    // longer quoted at the user.

    // MARK: - First run

    /// Three steps, for someone who has never seen a temporary number work.
    ///
    /// It replaces `freeCreditHint`, which could not render. The point is not
    /// reassurance — it is that "get a number" is meaningless until you know
    /// the code comes back to this app and you paste it somewhere else.
    private var explainer: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(explainerSteps.enumerated()), id: \.offset) { idx, label in
                explainerStep(idx + 1, label)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.chipBg, in: .rect(cornerRadius: RRadius.sm))
    }

    /// ⚠️ THE PAYWALL IS A STEP, AND IT WAS MISSING.
    ///
    /// `needsExplainer` fires exactly for the first-run user who CANNOT afford
    /// the route on screen — which, with the signup grant at 0, is nearly every
    /// new signup. The card walked them through pick → we hand you a number →
    /// the code lands here, mentioning cost nowhere, while the button directly
    /// beneath it read "Buy credits". Naming the money step is not a
    /// deterrent; discovering it one tap later is.
    ///
    /// Deliberately quotes no figure. Prices, the grant and the pack ladder all
    /// change server-side with no release — this file's standing rule after the
    /// onboarding card promised "+3 credits" through two versions in which the
    /// grant was 0.
    private var explainerSteps: [LocalizedStringKey] {
        var steps: [LocalizedStringKey] = ["Pick the service you're verifying"]
        if explainerNeedsCredits {
            steps.append("Add credits — that's how you pay for it")
        }
        // This step names the thing the user is about to be given, and in
        // e-mail mode that is not a number. The generic wording read as a
        // promise the e-mail line cannot keep — same class as every other
        // leak of SMS vocabulary into the e-mail flow.
        steps.append(state.emailMode
                     ? "We hand you a real, working e-mail address"
                     : "We hand you a real, working number")
        steps.append("The code lands here. Paste it back")
        return steps
    }

    /// Whether the thing this screen's button will buy actually costs credits
    /// the user does not have.
    ///
    /// E-mail is checked separately because `routeCost` is always the SMS
    /// route's price — so in e-mail mode `needsExplainer` can be true while the
    /// address on offer is FREE, and asserting a payment step there would be
    /// the mirror of the bug this fixes.
    private var explainerNeedsCredits: Bool {
        if state.emailMode {
            guard let dom = state.emailDomain, dom.credits > 0 else { return false }
            return state.balance < dom.credits
        }
        guard let routeCost else { return false }
        return state.balance < routeCost
    }

    private func explainerStep(_ n: Int, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            Text("\(n)")
                .font(RFont.text(11, weight: .heavy))
                .foregroundStyle(theme.accent2)
                .frame(width: 20, height: 20)
                .background(theme.inkSoft, in: .circle)
            Text(label)
                .font(RFont.text(13, weight: .medium))
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Actions

    /// The hero's primary action. Mirrors CheckoutScreen: a real "Buy credits"
    /// path when short, instead of a dead greyed-out button.
    @ViewBuilder
    private var heroCTA: some View {
        // 🔴 A first-run user must CHOOSE before they can buy.
        //
        // The route below it is a suggestion the app computed, and selling a
        // suggestion is what produced six deliveroo/us numbers for four
        // brand-new users who had never heard of Deliveroo — every one issued,
        // none ever entered anywhere, four not even cancelled. The credits are
        // refunded automatically, so the cost is not money: it is the single
        // session a new user gives us, spent proving nothing.
        //
        // Deliberately a real, labelled action rather than a disabled button:
        // the next step IS picking a service, so the button should do that.
        if state.needsServiceChoice && !state.emailMode {
            PrimaryButton(
                label: "Choose a service",
                sub: String(localized: "What are you verifying?"),
                icon: RIcon.search,
                action: { RHaptic.select(); openServices() }
            )
        } else if let routeCost {
            if state.balance < routeCost {
                PrimaryButton(
                    label: "Buy credits",
                    sub: String(localized: "Need \(routeCost - state.balance) more"),
                    icon: RIcon.plus,
                    action: { RHaptic.select(); openCredits() }
                )
            } else {
                PrimaryButton(
                    label: "Get number",
                    sub: "\(routeCost) cr",
                    icon: RIcon.bolt,
                    action: { RHaptic.select(); onStart() }
                )
            }
        } else {
            // The one honest dead end left: this pair is not bookable at all,
            // so the button that fixes it is the country picker.
            PrimaryButton(
                label: "Pick another country",
                sub: String(localized: "Not available here"),
                icon: RIcon.globe,
                action: { RHaptic.select(); openCountries() }
            )
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

    /// What a free domain costs THIS account, from the one shared definition
    /// the domain sheet also reads. Home used to hardcode "Free" for every
    /// `isFree` domain and so contradicted the sheet the user had just left.
    private var freeEmailAccess: FreeEmailAccess {
        FreeEmailAccess.resolve(isEntitled: mailStore.isEntitled,
                                hasUsedFree: state.hasUsedFreeEmail)
    }

    /// StoreKit's own localized monthly price as the CTA subtitle, and nil
    /// until the products load — the same rule `EmailCodeScreen` follows.
    private var mailPlanSub: String? {
        guard let price = mailStore.displayPrice(for: .monthly) else { return nil }
        return String(localized: "\(price)/mo")
    }

    /// Price in the e-mail hero. "Free" is a word, not a 0 — rendering "0 cr"
    /// reads as a broken price rather than a gift. But it is only "Free" when
    /// the account actually still has its one free address.
    @ViewBuilder
    private var emailHeroPrice: some View {
        if let dom = state.emailDomain {
            if dom.isFree {
                Text(freeEmailAccess.label)
                    .font(RFont.display(19, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(freeEmailAccess.readsAsFree ? theme.live : theme.text)
            } else {
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(dom.credits)")
                            .font(RFont.display(22, weight: .bold))
                            .tracking(-0.5)
                            .foregroundStyle(theme.text)
                            .monospacedDigit()
                        Text("cr")
                            .font(RFont.text(13, weight: .medium))
                            .foregroundStyle(theme.text2)
                    }
                }
            }
        } else {
            Text("—")
                .font(RFont.display(22, weight: .bold))
                .foregroundStyle(theme.text3)
        }
    }

    /// CTA for the e-mail line.
    ///
    /// ⚠️ **Every branch here is ENABLED and opens the thing it names.** Two of
    /// them used to be `disabled: true` buttons whose subtitle was an
    /// instruction — "Tap Domain below", "Pick another service" — which is a
    /// control that refuses to work while telling you to go and work it
    /// yourself. Worse, "below" pointed at the picker section this redesign
    /// deleted. A primary button is the screen's answer to "what now?"; if the
    /// answer is "choose a domain", it should choose a domain.
    ///
    /// Three distinct states, and the differences matter: a service with no
    /// domain cannot offer e-mail AT ALL (11 of 265), a domain can be out of
    /// stock, and the free tier must never render a credit price.
    @ViewBuilder
    private var emailCTA: some View {
        if !state.emailSupported {
            PrimaryButton(label: "Pick another service",
                          sub: String(localized: "No e-mail here"),
                          icon: RIcon.search,
                          action: { RHaptic.select(); openServices() })
        } else if let dom = state.emailDomain, dom.inStock {
            if dom.credits > 0 && state.balance < dom.credits {
                PrimaryButton(label: "Buy credits",
                              sub: String(localized: "Need \(dom.credits - state.balance) more"),
                              icon: RIcon.plus,
                              action: { RHaptic.select(); openCredits() })
            } else if dom.isFree && freeEmailAccess == .subscription {
                // The paywall's ONLY entry point used to be a refused order:
                // the button said "Get email address · Subscription", ran the
                // whole order path, and came back with `subscription_required`.
                // Selling the plan before spending the request is both honest
                // and the only way this line is ever bought on purpose.
                PrimaryButton(
                    label: "Get more addresses",
                    // StoreKit's own localized price, or nothing. A hardcoded
                    // "$2.99" here is the drift that put $4.99-vs-€5.99 on the
                    // credit ladder.
                    sub: mailPlanSub,
                    icon: RIcon.inbox,
                    action: {
                        RHaptic.select()
                        // Declare the product first, exactly as the refused-
                        // order path does, so the paywall and anything sized
                        // from `intent` agree about what is being bought.
                        state.intent = .mailSubscription
                        showMailPaywall = true
                    }
                )
            } else {
                PrimaryButton(
                    label: "Get email address",
                    // Same three states the domain sheet renders, from the
                    // same definition. It said "Free" unconditionally, so a
                    // user whose one free address was spent was invited in and
                    // then refused with `subscription_required`.
                    sub: dom.isFree ? freeEmailAccess.subtitle : "\(dom.credits) cr",
                    icon: RIcon.bolt,
                    disabled: state.isBuyingEmail,
                    action: { RHaptic.select(); onStartEmail() }
                )
            }
        } else {
            // No `sub`. "Pick where it lives" wrapped to two mono lines on a
            // narrow phone and squeezed the label it was meant to support —
            // and the label already says what the tap does.
            PrimaryButton(label: "Choose a domain",
                          icon: "envelope.fill",
                          action: { RHaptic.select(); openEmailDomains() })
        }
    }

    // MARK: - Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                MicroLabel("Recent")
                Button(action: { RHaptic.select(); onSeeAllOrders() }) {
                    Text("See all")
                        .font(RFont.text(13, weight: .medium))
                        .foregroundStyle(theme.text2)
                }
                .pressable(0.94)
            }
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
    /// instead of "from 0 credits" — and the whole teaser is suppressed while
    /// the line is paused, so it can never advertise a tab that answers
    /// "eSIMs are unavailable right now".
    private var esimTeaser: some View {
        let cheapest = state.esimCountries.map(\.fromCredits).min() ?? 0
        let countries = state.esimCountries.count
        return Button(action: { RHaptic.select(); onOpenEsim() }) {
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(theme.accent2)
                    .frame(width: 40, height: 40)
                    .background(theme.inkSoft, in: .rect(cornerRadius: RRadius.sm))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Travelling? Get data abroad")
                        .font(RFont.display(15, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(theme.text)
                    Text("eSIM plans in \(countries) countries, from \(cheapest) cr")
                        .font(RFont.text(12))
                        .foregroundStyle(theme.text2)
                }
                Spacer(minLength: 0)
                Image(systemName: RIcon.chev)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.text3)
            }
            .padding(14)
            .background(theme.elev, in: .rect(cornerRadius: RRadius.md))
            .contentShape(.rect)
        }
        .pressable()
    }
}
