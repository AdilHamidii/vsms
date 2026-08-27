import SwiftUI

/// The rented-number store — and, since 2026-08-05, the app's front door.
///
/// ── Why this is a sequence and not one long page ──────────────────────────
///
/// Three steps — read the pitch, pick a city, pick your actual number — then
/// the paywall. Each step renders instantly: a single page had to wait on a
/// Telnyx search before it could show anything, and the whole screen sat blank
/// meanwhile.
///
/// ⚠️ The city step NAMES THE MONTHLY PRICE as of 2026-08-23 (owner decision —
/// see `priceNote`). The original sequencing argument was that the number on
/// screen should be *theirs* before money is mentioned; that was overruled by
/// the cancellation data, and a subscriber who meets $9.99/month only after two
/// choices can feel walked into it. The full 3.1.2(a) disclosure is still
/// `LineCheckoutScreen`'s job alone.
///
/// There is deliberately **no credit pill** anywhere here. This product is paid
/// entirely through a StoreKit subscription and never touches the wallet;
/// showing a balance would imply otherwise, and it removes the `PurchaseIntent`
/// read path that has already shipped three bugs elsewhere.
///
/// The price, period, renewal terms and Terms/Privacy links live on
/// `LineCheckoutScreen`, which is the screen immediately before the purchase —
/// which is what App Store 3.1.2(a) actually requires.
struct LineStoreScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    @Environment(SubscriptionStore.self) private var subs

    /// Jump to the temp-SMS product. Passed in rather than reaching for
    /// `state.tab` directly so the caller owns navigation, matching
    /// `HomeScreen(onOpenEsim:)`.
    var onOpenSms: () -> Void

    private enum Step: Hashable { case intro, country, city, number }

    /// Opens on the pitch. The one exception is the screenshot harness, whose
    /// `lineStore` frame has always been the city list — the App Store
    /// screenshots would otherwise silently change meaning on the next run.
    @State private var step: Step =
        ScreenshotMode.screen == .lineStore ? .city : .intro

    /// Which way the last move went.
    ///
    /// A fixed edge per step works only while there are two steps and
    /// therefore one boundary. `city` now has a neighbour on either side, so
    /// there is no single edge that is correct for both — it has to slide out
    /// of whichever side it is being pushed toward.
    @State private var goingForward = true
    @State private var appeared = false

    var body: some View {
        ZStack {
            switch step {
            case .intro:   introStep.transition(pushTransition)
            case .country: countryStep.transition(pushTransition)
            case .city:    cityStep.transition(pushTransition)
            case .number:  numberStep.transition(pushTransition)
            }
        }
        .background(theme.bg)
        // Set BEFORE any await. This flag drives `riseIn`, so awaiting a network
        // call first left the entire screen at opacity 0 until Telnyx answered —
        // which is exactly what "the rent number screen takes too long to show
        // up" was. Nothing on the city step needs the network at all.
        .task {
            withAnimation(RMotion.content) { appeared = true }
            // The country catalogue. Swallows its own failure and keeps the
            // seeded two — see `AppState.loadLineCountries`. Fired here rather
            // than on entering the country step so the step can decide whether
            // to exist at all before the user reaches it.
            await state.loadLineCountries(using: LineAPI(client: api))
            // Loads the product the city step's `priceNote` reads — and the
            // reason that note renders nothing until this returns. Also keeps
            // the product warm for the paywall: the store is the app's first
            // screen, and `LineCheckoutScreen` renders a redacted placeholder while
            // StoreKit is still answering, and this usually removes it.
            // Idempotent, so calling it in both places is free.
            await subs.loadProduct()
        }
    }

    private var pushTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: goingForward ? .trailing : .leading)
                .combined(with: .opacity),
            removal: .move(edge: goingForward ? .leading : .trailing)
                .combined(with: .opacity))
    }

    /// Direction is set OUTSIDE the animation, so `pushTransition` is resolved
    /// against the new value in the same update that moves the step.
    private func go(to next: Step, forward: Bool) {
        goingForward = forward
        withAnimation(RMotion.panel) { step = next }
    }

    // MARK: - Step 1 · the pitch, alone
    //
    // The city list used to sit under this card on the same scroll, so the
    // launch screen opened on a wall of seven rows plus a footnote plus an
    // escape link — the reader had to get past a decision to finish reading
    // what the product even was. One page, one job: say what this is, then ask.
    //
    // Nothing here touches the network.

    private var introStep: some View {
        // `minHeight` equal to the viewport is what puts the CTA in the thumb
        // zone on a short page while still letting the whole thing scroll at
        // accessibility type sizes. A plain VStack would clip; a plain
        // ScrollView would leave the button stranded mid-screen.
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(kicker: "Second number", title: "Your own number")

                    // Two spacers, not one. With a single spacer under the
                    // card the whole pitch clung to the top and left a third
                    // of the screen empty above the button; equal-priority
                    // spacers split the slack so the card floats between the
                    // title and the CTA instead.
                    Spacer(minLength: 16)

                    pitch.riseIn(appeared, index: 0)
                    usSoon.padding(.top, 16).riseIn(appeared, index: 1)

                    Spacer(minLength: 24)

                    PrimaryButton(label: showsCountryStep
                                  ? String(localized: "Choose a country")
                                  : String(localized: "Choose a city")) {
                        go(to: showsCountryStep ? .country : .city, forward: true)
                    }
                    .riseIn(appeared, index: 2)

                    smsEscape.padding(.top, 12).riseIn(appeared, index: 3)
                }
                .padding(.horizontal, 20)
                // 🔴 THE TAB-BAR CLEARANCE MUST SIT OUTSIDE THE MIN-HEIGHT
                // FRAME. With `.padding(.bottom, 120)` applied INSIDE it, the
                // 120pt of clearance counted as content: the two spacers then
                // distributed slack across the FULL viewport, which put "Choose
                // a city" flush against the bottom of the screen — i.e. on top
                // of the floating tab bar — and pushed `smsEscape` underneath
                // it entirely. The escape is the only route to the temp-SMS
                // product from the launch surface, so it being invisible is a
                // funnel bug, not a cosmetic one.
                //
                // Subtracting the clearance from the min height and applying it
                // afterwards makes the spacers distribute slack in the space
                // that is actually visible.
                .frame(minHeight: proxy.size.height - 120, alignment: .top)
                .padding(.bottom, 120)
            }
        }
    }

    // MARK: - Step 2 · country
    //
    // Renders from `LineCountry.seeded` before any network call, then from
    // `line_country_menu`.

    /// Only sellable countries count toward "is there a choice here". A screen
    /// listing one buyable country and eleven grayed ones is a wall of "no"
    /// standing between the user and the only thing they can actually do — so
    /// with a single sellable country the step is skipped entirely and the
    /// grayed rows are simply not shown anywhere.
    private var sellableCountries: [LineCountry] {
        state.lineCountries.filter(\.isAvailable)
    }

    private var showsCountryStep: Bool { sellableCountries.count > 1 }

    /// Available first, then A–Z by the name the reader actually sees. Sorting
    /// by the server's English `country_name` would scramble the order on
    /// every non-English locale.
    private var sortedCountries: [LineCountry] {
        state.lineCountries.sorted {
            if $0.isAvailable != $1.isAvailable { return $0.isAvailable }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private var countryStep: some View {
        VStack(spacing: 0) {
            backHeader(title: "Where should it be?", subtitle: nil, back: .intro)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    countryList
                    priceNote.padding(.top, 14)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 120)
            }
        }
    }

    private var countryList: some View {
        Card(elevation: .flat) {
            VStack(spacing: 0) {
                ForEach(Array(sortedCountries.enumerated()), id: \.element.id) { i, country in
                    countryRow(country)
                    if i < sortedCountries.count - 1 { RowRule(inset: 16) }
                }
            }
        }
    }

    /// Flag, name, and what the number can DO.
    ///
    /// The capability strip is the whole point of showing unsellable countries
    /// at all: a voice-only country is an honest "call out" line, and a user
    /// who buys one expecting texts is a refund. Green means supported, GRAY
    /// means not — never red. Red is an error, and a number that simply does
    /// not carry MMS is not an error.
    private func countryRow(_ country: LineCountry) -> some View {
        Button {
            select(country)
        } label: {
            HStack(spacing: 12) {
                // A real flag asset rather than the emoji, at the 44pt leading
                // slot every other list row in the redesigned tab uses — the
                // emoji renders as a tofu box wherever the font lacks the pair,
                // and `CodeFlag` cascades bundled PNG → flagcdn → emoji.
                CodeFlag(code: country.countryCode, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: country.displayName)
                        .font(RFont.display(16, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    if !country.isAvailable {
                        Text("Not available yet")
                            .font(RFont.text(12))
                            .foregroundStyle(theme.text3)
                    }
                }
                Spacer(minLength: 8)
                capabilityStrip(country)
                if country.isAvailable {
                    Image(systemName: RIcon.chev)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.text3)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(minHeight: 56)
            .contentShape(.rect)
        }
        .buttonStyle(PressScaleStyle())
        .opacity(country.isAvailable ? 1 : 0.45)
        .disabled(!country.isAvailable)
        .accessibilityHint(country.isAvailable ? Text("") : Text(unavailableHint(country)))
    }

    /// Four glyphs, always all four, in a fixed order. A strip that only shows
    /// what IS supported reads as a feature list and hides the absence — which
    /// is the thing the buyer needs to see.
    private func capabilityStrip(_ country: LineCountry) -> some View {
        HStack(spacing: 9) {
            capabilityIcon("phone.fill", on: country.canVoice,
                           label: String(localized: "Calls"))
            capabilityIcon("message.fill", on: country.canSms,
                           label: String(localized: "Texts"))
            capabilityIcon("photo.fill", on: country.canMms,
                           label: String(localized: "Picture messages"))
            capabilityIcon("cross.case.fill", on: country.canEmergency,
                           label: String(localized: "Emergency calls"))
        }
    }

    private func capabilityIcon(_ symbol: String, on: Bool, label: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            // `live` is the semantic success green, and that is exactly the
            // claim being made here: this works. Absence is `text3`, the same
            // muted ink every other "nothing to report" uses.
            .foregroundStyle(on ? theme.live : theme.text3)
            .opacity(on ? 1 : 0.55)
            .accessibilityLabel(Text(verbatim: label))
            .accessibilityValue(on ? Text("Supported") : Text("Not supported"))
    }

    /// The machine key becomes a sentence HERE, never on the server. Anything
    /// unrecognised falls back to the vaguer line rather than rendering a raw
    /// key — an untranslated `documents_required` on a French phone is worse
    /// than saying less.
    private func unavailableHint(_ country: LineCountry) -> LocalizedStringKey {
        switch country.sellReason {
        case "documents_required": "Requires local registration we don't support yet"
        default:                   "Coming soon"
        }
    }

    /// Picking a country invalidates everything downstream.
    ///
    /// The city list, the offers and any hold all describe the PREVIOUS
    /// country, and leaving them in place would show Toronto under a Polish
    /// flag for as long as the search takes. Cleared first, loaded second.
    private func select(_ country: LineCountry) {
        state.lineCountry = country.countryCode
        state.lineCity = nil
        state.lineCities = []
        state.lineOffers = []
        state.lineOffer = nil
        state.lineReservation = nil
        state.lineUnavailableReason = nil
        go(to: .city, forward: true)
        Task {
            await state.loadLineNumbers(using: LineAPI(client: api),
                                        country: country.countryCode)
        }
    }

    // MARK: - Step 3 · city
    //
    // Renders with zero network dependency: the city list is seeded and only
    // replaced once a search has run. See `LineCity.seeded`.

    private var cityStep: some View {
        VStack(spacing: 0) {
            // The question IS the title here, so there is no separate
            // `SectionHeader` — printing "Where should it be?" twice, once as
            // a heading and once as a section label, is the shape this screen
            // just got rid of.
            backHeader(title: "Which city?", subtitle: countryLabel,
                       back: showsCountryStep ? .country : .intro)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // A country with no curated localities sells country-wide,
                    // and an empty list mid-load must not render as "nowhere".
                    if state.lineCities.isEmpty {
                        if state.isLoadingLineNumbers {
                            rowSkeleton
                        } else {
                            countryWide
                        }
                    } else {
                        cityList
                    }
                    priceNote.padding(.top, 14)
                    usSoon.padding(.top, 16)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 120)
            }
        }
    }

    /// ⚠️ **Only sell what ships.** Calling was absent from this card for as
    /// long as `flow = .dialer` was assigned nowhere, and was restored in the
    /// same commit that linked the SDK and wired the dialer. Keep that
    /// ordering for anything added here.
    ///
    /// 🔴 **OUTBOUND SMS WAS DROPPED ENTIRELY (owner decision, 2026-08-18) and
    /// every promise of it came off this card in the same change.** Lifetime
    /// outbound is 1 sent against 6 failed — every cross-border attempt refused
    /// by the carrier for want of 10DLC registration, which the owner is not
    /// pursuing. Inbound is 3 of 3. So the card now leads with the half that
    /// demonstrably works and sells the half that was invisible: international
    /// calling existed only inside the dialer and was never mentioned to anyone
    /// deciding whether to buy.
    private var pitch: some View {
        Card(elevation: .raised) {
            VStack(alignment: .leading, spacing: 0) {
                Text("A real Canadian phone number that stays yours.")
                    .font(RFont.display(17, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 8)

                // The situations, not the medium. Every one of these is
                // somebody sending a code TO the number.
                Text("Give it to marketplaces, dating apps, a side business or a bank. Your verification codes and texts land here, with one tap to copy the code.")
                    .font(RFont.text(13))
                    .lineSpacing(2)
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)

                RowRule(inset: 54)
                BenefitRow(icon: RIcon.message,
                           label: "Receive texts and codes in the app",
                           dense: true)
                RowRule(inset: 54)
                // "Make and take" until 2026-08-22. Inbound has never connected
                // once; it is a "Not yet" row below. Mirror of LineCheckoutScreen.
                BenefitRow(icon: RIcon.phone,
                           label: "Make calls from the app",
                           dense: true)
                RowRule(inset: 54)
                // Sold here for the first time. The rates, the credit cost and
                // the per-minute price all existed and were reachable ONLY from
                // inside the dialer — i.e. only after paying — so nobody
                // deciding whether to subscribe ever knew the number could call
                // abroad at all.
                BenefitRow(icon: RIcon.globe,
                           label: "Call 50+ countries, priced per minute before you dial",
                           dense: true)
                RowRule(inset: 54)
                // The actual reason to buy, and it used to be the last clause
                // of a paragraph. It is the only line here that names a
                // problem rather than a feature.
                BenefitRow(icon: RIcon.shield,
                           label: "Keep your own number private",
                           tint: theme.live,
                           dense: true)

                // ── What it does NOT do, stated on the same ledger ──────────
                //
                // Owner decision 2026-08-18: say plainly what the number can
                // and cannot do "for now". Every affordance for sending is
                // gone from the app, so a user who wants to text back finds
                // out by hunting for a button that is not there — which is
                // the refund moment. Naming it here, in the same row style as
                // the benefits, turns a surprise into a known limitation the
                // buyer accepted. Muted tint + a "Not yet" hint so it reads
                // as a ledger line, not an alarm. Same on the checkout screen,
                // which is the 3.1.2(a) disclosure surface.
                RowRule(inset: 54)
                BenefitRow(icon: RIcon.message,
                           label: "Sending texts from this number",
                           hint: "Not yet",
                           tint: theme.text3,
                           dense: true)
                    .opacity(0.72)
                RowRule(inset: 54)
                BenefitRow(icon: RIcon.globe,
                           label: "Receiving texts from outside the US and Canada",
                           hint: "Not yet",
                           tint: theme.text3,
                           dense: true)
                    .opacity(0.72)
                RowRule(inset: 54)
                BenefitRow(icon: RIcon.phone,
                           label: "Taking incoming calls",
                           hint: "Not yet",
                           tint: theme.text3,
                           dense: true)
                    .opacity(0.72)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The cities, as ONE grouped object.
    ///
    /// They were seven separate `theme.elev` cards with 8pt gaps — the pattern
    /// every other list in this app avoids. `CountrySheet` and `ServiceSheet`
    /// both put their rows inside a single `Card` divided by `RowRule`, which
    /// is what makes a stack read as one list to choose from rather than seven
    /// unrelated objects competing for the same tap. Seven detached cards also
    /// cost ~8pt of dead space each and made a trivial choice fill the screen.
    ///
    /// The rows stay deliberately plain. There is nothing honest to put on
    /// them: `search-line-numbers` walks a city's area codes until one has
    /// stock (416, 647, 514, 613 and 403 are all exhausted), so printing "437"
    /// beside Toronto would promise digits the reservation may not deliver.
    private var cityList: some View {
        Card(elevation: .flat) {
            VStack(spacing: 0) {
                ForEach(Array(state.lineCities.enumerated()), id: \.element.id) { i, city in
                    cityRow(city)
                    if i < state.lineCities.count - 1 { RowRule(inset: 16) }
                }
            }
        }
    }

    /// The country the user is shopping in, for the city step's subtitle.
    /// Reads the SEARCH's answer first — it is what the stock on screen came
    /// from — and the catalogue row only as a fallback.
    private var countryLabel: String? {
        guard let iso = state.lineCountry else { return nil }
        if let c = state.lineSearchCountry, c.countryCode == iso { return c.displayName }
        return state.lineCountries.first { $0.countryCode == iso }?.displayName
            ?? Locale.current.localizedString(forRegionCode: iso)
    }

    /// Same height and rhythm as the rows it stands in for, without the
    /// outer padding `numberSkeleton` applies — this one sits inside a stack
    /// that is already inset.
    private var rowSkeleton: some View {
        VStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: RRadius.md, style: .continuous)
                    .fill(theme.elev)
                    .frame(height: 56)
                    .opacity(1 - Double(i) * 0.18)
            }
        }
        .transition(.opacity)
    }

    /// Some countries have no curated cities — the server sells country-wide.
    /// One honest row beats an empty list, which reads as "sold out".
    private var countryWide: some View {
        Card(elevation: .flat) {
            Button {
                Task {
                    go(to: .number, forward: true)
                    await state.loadLineNumbers(using: LineAPI(client: api))
                }
            } label: {
                HStack(spacing: 12) {
                    leadingTile(RIcon.globe)
                    Text(countryLabel.map { String(localized: "Anywhere in \($0)") }
                         ?? String(localized: "Anywhere available"))
                        .font(RFont.display(16, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(theme.text)
                    Spacer(minLength: 8)
                    Image(systemName: RIcon.chev)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.text3)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .frame(minHeight: 56)
                .contentShape(.rect)
            }
            .buttonStyle(PressScaleStyle())
        }
    }

    /// What this costs, stated on the city step.
    ///
    /// ⚠️ **THIS REVERSES AN EARLIER OWNER DECISION** (2026-08-06: "there is
    /// deliberately no price on this screen … read, pick a city, get a number,
    /// and meet the paywall once — in that order"). That note said the removal
    /// would be the first thing to re-examine if a surprise subscription
    /// showed up in refunds or reviews, and it did: every subscriber so far
    /// cancelled auto-renew at a median of 3.9 minutes, with the two
    /// no-trial monthlies killed at 6 seconds and 9.7 minutes. Owner decision
    /// 2026-08-23 — a $9.99/month recurring charge is now named BEFORE the two
    /// choices, so someone who will not pay leaves before investing in a
    /// number.
    ///
    /// This does not move the App Store 3.1.2(a) disclosure: price, billing
    /// period, renewal terms and the Terms/Privacy links stay on
    /// `LineCheckoutScreen`, which is the screen immediately before the
    /// purchase and the one the guideline is about. This is one line of
    /// context, not the disclosure.
    ///
    /// 🔴 **NEVER A HARDCODED "$9.99".** The price is StoreKit's own localized
    /// `displayPrice` for the MONTHLY product, and when StoreKit has not
    /// answered — which is the normal state for the first moment of the app's
    /// launch surface, and permanently in the simulator — this renders
    /// NOTHING. A stale or assumed figure here is exactly the drift that put
    /// $4.99 against €5.99 on the credit ladder's top product.
    ///
    /// ⚠️ `monthlyPriceDisplay`, not `displayPrice`: the latter follows the
    /// paywall's `selectedPlan`, so a user who had tapped Yearly would read
    /// "$99.99 a month" here. Same trap that misstated the plan row by 12×.
    ///
    /// ⚠️ **NO TRIAL IS MENTIONED.** The line's 3-day trial was deleted in App
    /// Store Connect on 2026-08-23 after all three conversions to $99.99 were
    /// declined, so a trial claim would be false — and `trialLabel` is nil per
    /// Apple ID eligibility anyway, which is why no trial copy may ever be
    /// written as a literal.
    @ViewBuilder
    private var priceNote: some View {
        if let price = subs.monthlyPriceDisplay {
            Text("\(price) a month. Cancel any time in Settings.")
                .font(RFont.text(12))
                .foregroundStyle(theme.text2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Cities, never area codes.
    ///
    /// Canada's prestige codes are exhausted — 416 and 647 (Toronto), 514
    /// (Montreal), 613 (Ottawa) and 403 (Calgary) all return zero stock — while
    /// their overlays are full. A raw area-code picker would offer "416 —
    /// Toronto" and then fail, so the server takes a CITY and walks its codes
    /// in order until one has stock.
    private func cityRow(_ city: LineCity) -> some View {
        Button {
            Task {
                // Move first, load second. The tap is the commitment, so the
                // next screen appears immediately and fills in — rather than
                // the user waiting on this one with nothing happening.
                go(to: .number, forward: true)
                await state.loadLineNumbers(using: LineAPI(client: api), city: city.id)
            }
        } label: {
            HStack(spacing: 12) {
                // The same 34pt leading slot the country rows use, so the two
                // steps read as one sequence rather than two list styles. A
                // place glyph, not a flag: every city on screen is in the one
                // country already named in the header, so a repeated flag would
                // be seven copies of information the subtitle carries once.
                leadingTile("mappin.and.ellipse")
                Text(city.label)
                    .font(RFont.display(16, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(theme.text)
                Spacer(minLength: 8)
                // The province is a disambiguator, not a second title — two
                // Ontario rows (Toronto, Ottawa) are the only reason it is on
                // screen at all. Trailing and secondary, so the column of city
                // names stays the thing the eye scans.
                Text(city.region)
                    .font(RFont.text(13))
                    .foregroundStyle(theme.text2)
                    .lineLimit(1)
                Image(systemName: RIcon.chev)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.text3)
            }
            .padding(.horizontal, 16)
            // 11 + 11 around a 34pt tile clears the 44pt minimum target with
            // room to spare; the explicit `minHeight` is what guarantees it if
            // the tile ever shrinks.
            .padding(.vertical, 11)
            .frame(minHeight: 56)
            .contentShape(.rect)
        }
        .buttonStyle(PressScaleStyle())
    }

    /// The leading glyph slot shared by the city and country-wide rows.
    ///
    /// Sized to match `CodeFlag(size: 34)` exactly so a step that leads with a
    /// flag and a step that leads with an icon put their titles on the same
    /// x-position — the thing that makes a multi-step picker feel like one
    /// screen changing rather than four different lists.
    private func leadingTile(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(theme.text2)
            .frame(width: 34, height: 34)
            .background(theme.chipBg, in: .circle)
    }

    // MARK: - Step 3 · number

    /// What the store currently knows about the country being shopped. The
    /// search's own answer wins: it describes the stock on screen, and it is
    /// present even when `line_country_menu` could not be read.
    private var currentCountry: LineCountry? {
        guard let iso = state.lineCountry else { return nil }
        if let c = state.lineSearchCountry, c.countryCode == iso { return c }
        return state.lineCountries.first { $0.countryCode == iso }
    }

    /// TRUE only on a positive `supports_sms = false`. A missing field is "we
    /// do not know", and a "calls only" warning printed over a number that can
    /// text is its own kind of lie — one that costs a sale rather than a
    /// refund, but a lie either way.
    private var isVoiceOnly: Bool {
        guard let c = currentCountry else { return false }
        return c.supportsSms == false && c.supportsVoice != false
    }

    private var numberStep: some View {
        VStack(spacing: 0) {
            backHeader(title: "Pick your number", subtitle: cityLabel, back: .city)
            if isVoiceOnly { voiceOnlyNotice }
            if state.isLoadingLineNumbers, state.lineOffers.isEmpty {
                numberSkeleton
            } else if state.lineOffers.isEmpty {
                unavailable
            } else {
                numberList
            }
        }
    }

    /// Carried on the number step AND on checkout, deliberately twice.
    ///
    /// A user who picks a voice-only country and discovers it after paying is
    /// an Apple refund and, on this product, a `CONSUMPTION_REQUEST` — the
    /// same failure the "Not yet" ledger rows exist to prevent. `warnSoft` and
    /// not `failSoft`: it is a property of the number, not a fault.
    private var voiceOnlyNotice: some View {
        // Through `Card` with a semantic fill and hairline, which is the one
        // sanctioned use of `border`: an amber caution surface. Identical
        // treatment to `LineCheckoutScreen`'s own copy of this notice and to
        // its emergency block, so a caution looks like a caution everywhere in
        // the funnel instead of three hand-rolled backgrounds drifting apart.
        Card(radius: RRadius.md, elevation: .flat,
             fill: theme.warnSoft, border: theme.warn.opacity(0.28)) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.warn)
                    .padding(.top, 1)
                Text("Calls only. This number can't send or receive texts.")
                    .font(RFont.text(12, weight: .medium))
                    .foregroundStyle(theme.text)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    /// Shared by steps 2 and 3, so the two inner pages cannot drift apart in
    /// title weight, back-button size or spacing.
    private func backHeader(title: LocalizedStringKey, subtitle: String?,
                            back: Step) -> some View {
        HStack(spacing: 12) {
            Button {
                go(to: back, forward: false)
            } label: {
                Image(systemName: RIcon.back)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.text2)
                    .frame(width: 34, height: 34)
                    .background(theme.chipBg, in: .circle)
            }
            .buttonStyle(.plain)
            // Without this VoiceOver reads the SF Symbol's name.
            .accessibilityLabel("Back")

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(RFont.display(19, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(theme.text)
                if let subtitle {
                    Text(subtitle)
                        .font(RFont.text(12))
                        .foregroundStyle(theme.text2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// Real rows at the real height, so the list does not jump when it fills.
    /// A spinner in the middle of an empty screen gives no sense of what is
    /// coming; these do.
    private var numberSkeleton: some View {
        VStack(spacing: 8) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: RRadius.md, style: .continuous)
                    .fill(theme.elev)
                    // Matches the contact card exactly — 42pt avatar plus 14+14
                    // of padding — so the list does not jump as it fills.
                    .frame(height: 70)
                    .overlay(alignment: .leading) {
                        HStack(spacing: 13) {
                            Circle()
                                .fill(theme.chipBg)
                                .frame(width: 42, height: 42)
                            VStack(alignment: .leading, spacing: 7) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(theme.chipBg)
                                    .frame(width: 140, height: 15)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(theme.chipBg)
                                    .frame(width: 72, height: 10)
                            }
                        }
                        .padding(.leading, 14)
                    }
                    .opacity(1 - Double(i) * 0.15)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .transition(.opacity)
    }

    private var numberList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(Array(state.lineOffers.enumerated()), id: \.element.id) { i, offer in
                    numberRow(offer, index: i)
                }

                // The app's one secondary-action shape, rather than a bespoke
                // borderless row that gave no press feedback at all.
                GhostButton(label: "Show different numbers",
                            icon: RIcon.refresh,
                            fillsWidth: false) {
                    Task { await state.loadLineNumbers(using: LineAPI(client: api)) }
                }
                .disabled(state.isLoadingLineNumbers)
                .opacity(state.isLoadingLineNumbers ? 0.5 : 1)
                .padding(.top, 6)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 120)
        }
    }

    /// One candidate number, presented as a contact card.
    ///
    /// `PeerAvatar` is the same deterministic circle the recents and thread
    /// rows use, keyed on the E.164 — so the colour a user sees beside a number
    /// here is the colour it keeps on the checkout hero and, once bought,
    /// everywhere in the tab. That continuity is the whole reason to spend the
    /// leading slot on it: it makes the number feel like a thing being adopted
    /// rather than a row in a stock list.
    ///
    /// ⚠️ **No price is rendered here, deliberately.** `monthlyCents` /
    /// `upfrontCents` on this model are the WHOLESALE quote — the cost book,
    /// which the app never shows a user — and the retail figure is the same
    /// subscription price on every row, so printing it would be noise on top
    /// of a leak. The price is stated once, on `LineCheckoutScreen`, which is
    /// the 3.1.2(a) surface.
    private func numberRow(_ offer: LineNumberOffer, index: Int) -> some View {
        Button {
            state.lineOffer = offer
            state.intent = .line
            state.flow = .lineCheckout
        } label: {
            Card(radius: RRadius.md, elevation: .raised) {
                HStack(spacing: 13) {
                    PeerAvatar(e164: offer.phoneNumber, size: 42)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(PhoneFormat.national(offer.phoneNumber))
                            .font(RFont.mono(18, weight: .medium))
                            .foregroundStyle(theme.text)
                            .minimumScaleFactor(0.8)
                            .lineLimit(1)
                        offerCapabilities(offer)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: RIcon.chev)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.text3)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
        }
        .buttonStyle(PressScaleStyle(scale: 0.98, dim: true))
    }

    /// What THIS number can do, when Telnyx told us.
    ///
    /// `features` is optional on the model because the deployed server does not
    /// always send it, and an absent list means "we do not know" — never "it
    /// cannot". So the strip renders nothing at all rather than four gray
    /// glyphs, which would read as a number that does nothing. When the list IS
    /// present the same rule as the country strip applies: green means
    /// supported, gray means not, never red. The region, when the search names
    /// one, stands in when there are no features to show.
    @ViewBuilder
    private func offerCapabilities(_ offer: LineNumberOffer) -> some View {
        if offer.features != nil {
            HStack(spacing: 9) {
                capabilityIcon("phone.fill", on: offer.supports("voice") == true,
                               label: String(localized: "Calls"))
                capabilityIcon("message.fill", on: offer.supports("sms") == true,
                               label: String(localized: "Texts"))
                capabilityIcon("photo.fill", on: offer.supports("mms") == true,
                               label: String(localized: "Picture messages"))
                capabilityIcon("cross.case.fill", on: offer.supports("emergency") == true,
                               label: String(localized: "Emergency calls"))
            }
        } else if let region = offer.region, !region.isEmpty {
            Text(verbatim: region)
                .font(RFont.text(12))
                .foregroundStyle(theme.text2)
                .lineLimit(1)
        }
    }

    // MARK: - Nothing to sell

    /// Three causes, and we only ever know one of them.
    ///
    /// `paused` is something the server told us and can be stated outright. An
    /// empty search is an observation about ONE city and nothing more — and a
    /// failed fetch looks identical from here, which is why the third case
    /// claims no reason at all. Same discipline as
    /// `EsimStoreScreen.emptyCatalog`.
    /// Through the shared `EmptyState`, which is the app's one answer to
    /// "there is nothing here" — and which carries the rule this screen was
    /// already following by hand: an empty state with an obvious next action
    /// must offer it, and a genuine LOAD FAILURE must not look like a healthy
    /// absence. Hence the `fail` tint on the unknown case only; a paused line
    /// or a dry city is not an error.
    private var unavailable: some View {
        EmptyState(
            icon: state.lineUnavailableReason == .paused
                  ? "pause.circle" : "phone.badge.waveform",
            title: unavailableTitle,
            message: unavailableBody,
            tint: state.lineUnavailableReason == nil ? theme.fail : nil,
            // A refused COUNTRY cannot be fixed by another city, so the escape
            // has to point one step further back.
            secondary: (label: state.lineUnavailableReason == .countryNotSellable
                        ? String(localized: "Try another country")
                        : String(localized: "Try another city"),
                        action: {
                            go(to: state.lineUnavailableReason == .countryNotSellable
                               && showsCountryStep ? .country : .city,
                               forward: false)
                        }))
        .padding(.top, 24)
    }

    private var unavailableTitle: LocalizedStringKey {
        switch state.lineUnavailableReason {
        case .paused:  "Second numbers are unavailable"
        case .noStock: "No numbers here right now"
        case .countryNotSellable: "We don't sell numbers here yet"
        default:       "We couldn't load any numbers"
        }
    }

    private var unavailableBody: LocalizedStringKey {
        switch state.lineUnavailableReason {
        case .paused:  "We've paused new numbers while we make some improvements. Check back soon."
        case .noStock: "Stock moves through the day. Another city will have some."
        case .countryNotSellable: "We're working on this country. Another one is ready now."
        default:       "Check your connection and try again."
        }
    }

    private var cityLabel: String? {
        state.lineCities.first { $0.id == state.lineCity }?.label
    }

    // MARK: - Chrome

    private func header(kicker: LocalizedStringKey, title: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(kicker).font(RFont.text(13)).foregroundStyle(theme.text2)
            Text(title)
                .font(RFont.display(28, weight: .bold))
                .tracking(-0.7).foregroundStyle(theme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }

    private var usSoon: some View {
        // Same container as the caution notices, in NEUTRAL ink rather than
        // amber — this is a statement of reach, not a warning, and the two must
        // not look alike. Giving it a surface at all is what stops a
        // load-bearing honesty line reading as a stray caption.
        Card(radius: RRadius.md, elevation: .flat,
             fill: theme.chipBg, border: nil) {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "flag")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.text2)
                .padding(.top, 2)
            // ⚠️ NO SENDING PROMISE OF ANY KIND, and the "US sending is coming"
            // half is gone rather than softened — outbound SMS is dropped, not
            // delayed, so a roadmap sentence would be a promise nobody intends
            // to keep. What replaces it is the calling reach, which is the
            // thing this product can actually do outward.
            // "US and Canadian" is deliberate, not a hedge: the numbers carry
            // `international_inbound: false` and Telnyx silently ignores the
            // PATCH to change it — a European phone texting this number
            // produces NOTHING, no failure, no webhook. Verification codes come
            // from services, which send from NANP, so the useful claim is true
            // and the broader one would be the next refund. Calling OUT is
            // genuinely worldwide. See providers.md "US NUMBERS ARE
            // DOMESTIC-ONLY FOR SMS".
            Text("Receives texts from US and Canadian numbers and services. Call out to Canada, the US and 50 countries.")
                .font(RFont.text(12))
                .foregroundStyle(theme.text2)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        }
    }

    /// Temp SMS is second in the business, not retired. Now that this screen is
    /// the launch surface, it is the only thing standing between a user who
    /// wants a one-off code and a monthly subscription pitch.
    /// Rendered as a real secondary button — full width, 48pt, `chipBg`, the
    /// same shape `GhostButton` gives every other "the other way" action in the
    /// app. It used to be a 13pt regular line in `text2`, which read as a
    /// caption; combined with the layout bug above (see `introStep`) it was
    /// both faint and off-screen. The copy is unchanged.
    /// Now the shared `GhostButton` itself rather than a hand-rolled copy of
    /// its shape. It was already styled to imitate one — same 48pt height,
    /// `chipBg` capsule, same press scale — so this is the same button with
    /// one definition instead of two, and it picks up any future change to the
    /// app's secondary action for free. The copy is unchanged; the trailing
    /// arrow goes, because `GhostButton` places its glyph leading and one
    /// consistent shape beats a bespoke affordance.
    private var smsEscape: some View {
        GhostButton(label: "Just need a one-off verification code?",
                    action: onOpenSms)
    }
}
