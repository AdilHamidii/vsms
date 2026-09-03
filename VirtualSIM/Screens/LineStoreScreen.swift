import StoreKit
import SwiftUI

/// The rented-number store — and, since 2026-08-05, the app's front door.
///
/// ── Why this is ONE screen and not a sequence (2026-09-03) ────────────────
///
/// It was four steps — read the pitch, pick a country, pick a city, pick your
/// number — and then the paywall. That flow sold **nothing**: 162
/// `line_store_view` events across 106 distinct viewers since 2.7 shipped, and
/// **zero subscriptions**. The number and the price were three taps away from
/// the only screen most people ever saw, and the first tap bought them another
/// page of reading rather than the product. Owner decision 2026-09-03: collapse
/// it, put real numbers and the monthly price on the launch surface, and let
/// the pickers become a `.sheet` for the minority who want a different place.
///
/// The step sequence existed because a single page had to wait on a Telnyx
/// search before it could show anything. That argument is answered rather than
/// ignored: everything above the numbers renders from local state on the first
/// frame, the search runs in the background from the root `.task`, and the
/// numbers themselves occupy `numberSkeleton` at their real height meanwhile —
/// so nothing on screen ever waits on the network to exist.
///
/// ⚠️ **THE PRICE IS NAMED HERE, and it is never a literal** — see `priceNote`.
/// There is deliberately **no credit pill** anywhere: this product is paid
/// entirely through a StoreKit subscription and never touches the wallet, and
/// showing a balance would imply otherwise.
///
/// The full 3.1.2(a) disclosure — price, period, renewal terms, Terms/Privacy —
/// is still `LineCheckoutScreen`'s job alone, because that is the screen
/// immediately before the purchase.
struct LineStoreScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    @Environment(SubscriptionStore.self) private var subs

    /// Jump to the temp-SMS product. Passed in rather than reaching for
    /// `state.tab` directly so the caller owns navigation, matching
    /// `HomeScreen(onOpenEsim:)`.
    var onOpenSms: () -> Void

    @State private var appeared = false

    /// The place pickers, which are no longer steps in a flow. They are a
    /// detour off a screen that already has an answer on it.
    @State private var showsPlaceSheet = false
    /// Which list the sheet is showing. A country selection moves it to that
    /// country's cities INSIDE the sheet, so the two lists keep the ordering
    /// the old two steps had without owning the whole screen.
    @State private var sheetShowsCountries = false

    /// How many numbers the screen offers at once.
    ///
    /// Three, not the whole search. This list is one section of a scrolling
    /// page rather than the page itself, and every row past the third pushes
    /// the price — the thing a subscriber has to have read — below the fold.
    /// "Show different numbers" re-rolls the search for anyone who dislikes
    /// all three.
    private static let visibleOffers = 3

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(kicker: "Second number", title: "A number for your codes")

                    Spacer(minLength: 16)

                    pitch.riseIn(appeared, index: 0)

                    numbers.padding(.top, 18).riseIn(appeared, index: 1)

                    usSoon.padding(.top, 16).riseIn(appeared, index: 3)

                    Spacer(minLength: 24)

                    smsEscape.padding(.top, 12).riseIn(appeared, index: 4)
                }
                .padding(.horizontal, 20)
                // 🔴 THE TAB-BAR CLEARANCE MUST SIT OUTSIDE THE MIN-HEIGHT
                // FRAME. With `.padding(.bottom, 120)` applied INSIDE it, the
                // 120pt of clearance counts as content: the spacers then
                // distribute slack across the FULL viewport, which puts the
                // last element flush against the bottom of the screen — i.e.
                // on top of the floating tab bar — and pushes `smsEscape`
                // underneath it entirely. The escape is the only route to the
                // temp-SMS product from the launch surface, so it being
                // invisible is a funnel bug, not a cosmetic one.
                .frame(minHeight: proxy.size.height - 120, alignment: .top)
                .padding(.bottom, 120)
            }
        }
        .background(theme.bg)
        .sheet(isPresented: $showsPlaceSheet) { placeSheet }
        // Set BEFORE any await. This flag drives `riseIn`, so awaiting a
        // network call first left the entire screen at opacity 0 until Telnyx
        // answered — which is exactly what "the rent number screen takes too
        // long to show up" was. Nothing above the numbers needs the network.
        .task {
            withAnimation(RMotion.content) { appeared = true }
            Analytics.shared.track("line_store_view")
            // The country catalogue. Swallows its own failure and keeps the
            // seeded two — see `AppState.loadLineCountries`. It has to land
            // before the default place is chosen, because "is this country
            // sellable" is a question only the catalogue can answer.
            await state.loadLineCountries(using: LineAPI(client: api))
            if state.lineCountry == nil, let iso = await storefrontCountry() {
                state.lineCountry = iso
            }
            // Numbers before the product: the search is the slow half and it
            // is what this screen is for. `priceNote` renders nothing until
            // StoreKit answers and then fills in a beat later, without moving
            // anything above it.
            //
            // Screenshot frames seed the offers directly — a live search from
            // `simctl` returns nothing and would wipe the fixture, the same
            // trap `AppState.loadLineThreads` documents.
            if !ScreenshotMode.isActive, state.lineOffers.isEmpty {
                await reloadNumbers()
            }
            // Keeps the product warm for the paywall: the store is the app's
            // first screen and `LineCheckoutScreen` renders a redacted
            // placeholder while StoreKit is still answering. Idempotent, so
            // calling it in both places is free.
            await subs.loadProduct()
        }
    }

    // MARK: - The search

    /// Every search the screen runs goes through here, so `line_numbers_shown`
    /// cannot drift away from the thing it claims to measure. It fires on the
    /// RESULT rather than in `body`, which SwiftUI re-evaluates for reasons
    /// that have nothing to do with a new search.
    private func reloadNumbers(city: String? = nil, country: String? = nil) async {
        await state.loadLineNumbers(using: LineAPI(client: api),
                                    city: city, country: country)
        Analytics.shared.track("line_numbers_shown", [
            "country": .string(state.lineCountry ?? "unknown"),
            // "any" is a real answer here — a country with no curated
            // localities sells country-wide — and it must not be read as a
            // missing one.
            "city": .string(state.lineCity ?? "any"),
            "count": .int(state.lineOffers.count)])
    }

    /// One definition of "the user chose somewhere else", used by all three
    /// selection paths in the sheet. Anything that changes the place must go
    /// through it, or the funnel silently loses a branch.
    private func changePlace(city: String? = nil, country: String? = nil) {
        Analytics.shared.track("line_place_changed", [
            "country": .string(country ?? state.lineCountry ?? "unknown"),
            "city": .string(city ?? "any")])
        Task { await reloadNumbers(city: city, country: country) }
    }

    /// ISO-3166 alpha-3 → alpha-2, for the countries this store can sell.
    ///
    /// ⚠️ `Storefront.countryCode` is **alpha-3** ("USA", "CAN") while the
    /// catalogue speaks alpha-2, and Foundation offers no conversion. So the
    /// map is explicit and deliberately covers the sellable set only —
    /// anything outside it resolves to nil and the server's own default
    /// stands. Add a row here when a country becomes sellable; a wrong guess
    /// (the first two letters happen to work for these three and not for
    /// DEU/GBR) would search the wrong country.
    private static let storefrontISO2: [String: String] =
        ["USA": "US", "CAN": "CA", "PRI": "PR"]

    /// The device's App Store country, when we can actually sell there.
    ///
    /// 41 of the last 50 signups are USA and the server's default is Toronto,
    /// so an untouched screen showed most users a foreign number. The
    /// storefront is the payment geography, which is the closest thing to
    /// "where this person is" that costs no permission prompt.
    private func storefrontCountry() async -> String? {
        guard let iso3 = await Storefront.current?.countryCode,
              let iso2 = Self.storefrontISO2[iso3],
              sellableCountries.contains(where: { $0.countryCode == iso2 })
        else { return nil }
        return iso2
    }

    // MARK: - The pitch

    /// ⚠️ **Only sell what ships.** Calling was absent from this card for as
    /// long as `flow = .dialer` was assigned nowhere, and was restored in the
    /// same commit that linked the SDK and wired the dialer. Keep that
    /// ordering for anything added here.
    ///
    /// 🔴 **CODES-FIRST since 2026-09-01 (owner decision).** The pitch is "a
    /// real US or Canadian number that receives verification codes" — not
    /// calling, not texting. It names ONLY services that have delivered a real
    /// code to a rented number (WhatsApp, TikTok, DoorDash — each verified in
    /// `line_messages`), says plainly that some platforms refuse virtual
    /// numbers, and sells the switch as the remedy at its live price.
    ///
    /// 🔴 **THREE ROWS, and the "Not yet" ledger is NOT one of them
    /// (2026-09-03).** The ledger — sending texts, receiving from outside
    /// NANP, taking incoming calls — still exists, on `LineCheckoutScreen`,
    /// which is the disclosure surface a buyer reads immediately before
    /// paying. It came off THIS card because the store now has to carry the
    /// numbers and the price as well, and seven ledger rows between the
    /// headline and the first real number is the shape that sold nothing.
    /// Honesty is not deleted here, it is moved to the screen where it is
    /// acted on. The same rule governs calling, which was a fourth row and is
    /// now checkout's alone: it works, it is not why anyone buys.
    private var pitch: some View {
        Card(elevation: .raised) {
            VStack(alignment: .leading, spacing: 0) {
                Text("A real US or Canadian number that receives your verification codes.")
                    .font(RFont.display(17, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 8)

                // Only proven names. Adding a service here requires a real
                // code on a rented line, not a guess.
                Text("Works with WhatsApp, TikTok, DoorDash and most other apps. The code lands here, with one tap to copy it.")
                    .font(RFont.text(13))
                    .lineSpacing(2)
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)

                RowRule(inset: 54)
                BenefitRow(icon: RIcon.message,
                           label: "Receive verification codes in the app",
                           tint: theme.live,
                           dense: true)
                RowRule(inset: 54)
                // The honest line, and the remedy priced live. NO client
                // default for the figure — `app_config.line_swap_credits`
                // changes without a release, so when it is unknown the
                // sentence drops the number rather than inventing one. Never
                // `?? 8`.
                if let cost = state.appStatus.lineSwapCredits {
                    BenefitRow(icon: "arrow.triangle.2.circlepath",
                               label: "Might not work on every service — if a code doesn't arrive, switch to a new number for \(cost) credits",
                               dense: true)
                } else {
                    BenefitRow(icon: "arrow.triangle.2.circlepath",
                               label: "Might not work on every service — if a code doesn't arrive, switch to a new number for a few credits",
                               dense: true)
                }
                RowRule(inset: 54)
                // The actual reason to buy, and it used to be the last clause
                // of a paragraph. It is the only line here that names a
                // problem rather than a feature.
                BenefitRow(icon: RIcon.shield,
                           label: "Keep your own number private",
                           dense: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - The numbers, on the same screen

    /// Where the stock on screen is from, in the reader's own words: the city
    /// when the search picked one, the country otherwise. Never an ISO code —
    /// "CA" is not a place to a reader.
    private var placeLabel: String? { cityLabel ?? countryLabel }

    private var numbers: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if let place = placeLabel {
                    MicroLabel("Available now in \(place)")
                } else {
                    MicroLabel("Available now")
                }
                Spacer(minLength: 0)
                GhostButton(label: "Change", fillsWidth: false) {
                    sheetShowsCountries = showsCountryStep
                    showsPlaceSheet = true
                }
            }

            // The price sits ABOVE the list, not under it: below three 70pt
            // rows it landed under the floating tab bar on a 6.3" screen, i.e.
            // the one figure this redesign exists to put in front of the
            // reader was the one thing they had to scroll for (verified from a
            // simulator screenshot, 2026-09-03).
            priceNote

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

    private var numberList: some View {
        VStack(spacing: 8) {
            ForEach(Array(state.lineOffers.prefix(Self.visibleOffers)), id: \.id) { offer in
                numberRow(offer)
            }

            // The app's one secondary-action shape, rather than a bespoke
            // borderless row that gave no press feedback at all.
            GhostButton(label: "Show different numbers",
                        icon: RIcon.refresh,
                        fillsWidth: false) {
                Task { await reloadNumbers() }
            }
            .disabled(state.isLoadingLineNumbers)
            .opacity(state.isLoadingLineNumbers ? 0.5 : 1)
            .padding(.top, 6)
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
    /// of a leak. The price is stated once below this list, and in full on
    /// `LineCheckoutScreen`, which is the 3.1.2(a) surface.
    private func numberRow(_ offer: LineNumberOffer) -> some View {
        Button {
            Analytics.shared.track("line_number_picked", [
                "country": .string(offer.countryCode ?? state.lineCountry ?? "unknown")])
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

    /// Real rows at the real height, so the section does not jump when it
    /// fills. A spinner gives no sense of what is coming; these do. Three of
    /// them, matching `visibleOffers` — a five-row skeleton resolving to three
    /// rows is a collapse, which reads as something having gone wrong.
    private var numberSkeleton: some View {
        VStack(spacing: 8) {
            ForEach(0..<Self.visibleOffers, id: \.self) { i in
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
        }
        .transition(.opacity)
    }

    /// Carried here AND on checkout, deliberately twice.
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
            // A refused COUNTRY cannot be fixed by another city, so that one
            // escape opens the sheet on the country list instead.
            secondary: (label: state.lineUnavailableReason == .countryNotSellable
                        ? String(localized: "Try another country")
                        : String(localized: "Try another city"),
                        action: {
                            sheetShowsCountries =
                                state.lineUnavailableReason == .countryNotSellable
                                && showsCountryStep
                            showsPlaceSheet = true
                        }))
        .padding(.top, 12)
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

    // MARK: - The place sheet
    //
    // Both lists render with zero network dependency — the countries fall back
    // to `LineCountry.seeded` and the cities to `LineCity.seeded` — so the
    // sheet is never a blank page waiting on Telnyx.

    private var placeSheet: some View {
        VStack(spacing: 0) {
            SheetHeader(title: sheetShowsCountries
                        ? String(localized: "Where should it be?")
                        : String(localized: "Which city?"))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if sheetShowsCountries {
                        countryList
                    } else if state.lineCities.isEmpty {
                        // A country with no curated localities sells
                        // country-wide, and an empty list mid-load must not
                        // render as "nowhere".
                        if state.isLoadingLineNumbers {
                            rowSkeleton
                        } else {
                            countryWide
                        }
                    } else {
                        cityList
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .background(theme.bg)
    }

    /// Only sellable countries count toward "is there a choice here". A list
    /// of one buyable country and eleven grayed ones is a wall of "no"
    /// standing between the user and the only thing they can actually do — so
    /// with a single sellable country the sheet opens straight on the cities
    /// and the grayed rows are simply not shown anywhere.
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
    ///
    /// The sheet stays up and moves to that country's cities — the ordering
    /// the two steps had, without taking the store screen away from someone
    /// who only wanted to look.
    private func select(_ country: LineCountry) {
        state.lineCountry = country.countryCode
        state.lineCity = nil
        state.lineCities = []
        state.lineOffers = []
        state.lineOffer = nil
        state.lineReservation = nil
        state.lineUnavailableReason = nil
        sheetShowsCountries = false
        changePlace(country: country.countryCode)
    }

    /// The cities, as ONE grouped object.
    ///
    /// They were seven separate `theme.elev` cards with 8pt gaps — the pattern
    /// every other list in this app avoids. `CountrySheet` and `ServiceSheet`
    /// both put their rows inside a single `Card` divided by `RowRule`, which
    /// is what makes a stack read as one list to choose from rather than seven
    /// unrelated objects competing for the same tap.
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

    /// Cities, never area codes.
    ///
    /// Canada's prestige codes are exhausted — 416 and 647 (Toronto), 514
    /// (Montreal), 613 (Ottawa) and 403 (Calgary) all return zero stock — while
    /// their overlays are full. A raw area-code picker would offer "416 —
    /// Toronto" and then fail, so the server takes a CITY and walks its codes
    /// in order until one has stock.
    private func cityRow(_ city: LineCity) -> some View {
        Button {
            // Dismiss on the tap. The store behind the sheet already holds the
            // skeleton and fills in — leaving the sheet up until the search
            // returned would make the choice feel unacknowledged.
            showsPlaceSheet = false
            changePlace(city: city.id)
        } label: {
            HStack(spacing: 12) {
                // The same 34pt leading slot the country rows use, so the two
                // lists read as one sequence rather than two list styles. A
                // place glyph, not a flag: every city here is in the one
                // country already chosen, so a repeated flag would be seven
                // copies of the same information.
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

    /// Some countries have no curated cities — the server sells country-wide.
    /// One honest row beats an empty list, which reads as "sold out".
    private var countryWide: some View {
        Card(elevation: .flat) {
            Button {
                showsPlaceSheet = false
                changePlace()
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

    /// The leading glyph slot shared by the city and country-wide rows.
    ///
    /// Sized to match `CodeFlag(size: 34)` exactly so a list that leads with a
    /// flag and a list that leads with an icon put their titles on the same
    /// x-position — the thing that makes the sheet feel like one screen
    /// changing rather than two different lists.
    private func leadingTile(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(theme.text2)
            .frame(width: 34, height: 34)
            .background(theme.chipBg, in: .circle)
    }

    /// Same rhythm as the city rows it stands in for, at their height.
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

    // MARK: - Labels

    /// The country the user is shopping in. Reads the SEARCH's answer first —
    /// it is what the stock on screen came from — and the catalogue row only
    /// as a fallback.
    private var countryLabel: String? {
        guard let iso = state.lineCountry else { return nil }
        if let c = state.lineSearchCountry, c.countryCode == iso { return c.displayName }
        return state.lineCountries.first { $0.countryCode == iso }?.displayName
            ?? Locale.current.localizedString(forRegionCode: iso)
    }

    private var cityLabel: String? {
        state.lineCities.first { $0.id == state.lineCity }?.label
    }

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

    /// What this costs, stated directly under the numbers.
    ///
    /// ⚠️ **THIS REVERSES AN EARLIER OWNER DECISION** (2026-08-06: "there is
    /// deliberately no price on this screen … read, pick a city, get a number,
    /// and meet the paywall once — in that order"). That note said the removal
    /// would be the first thing to re-examine if a surprise subscription
    /// showed up in refunds or reviews, and it did: every subscriber so far
    /// cancelled auto-renew at a median of 3.9 minutes, with the two no-trial
    /// monthlies killed at 6 seconds and 9.7 minutes. Owner decision
    /// 2026-08-23 — the monthly charge is named before any choice is invested
    /// in, so someone who will not pay leaves before picking a number.
    ///
    /// This does not move the App Store 3.1.2(a) disclosure: price, billing
    /// period, renewal terms and the Terms/Privacy links stay on
    /// `LineCheckoutScreen`, which is the screen immediately before the
    /// purchase and the one the guideline is about. This is one line of
    /// context, not the disclosure.
    ///
    /// 🔴 **NEVER A HARDCODED PRICE.** It is StoreKit's own localized
    /// `displayPrice` for the MONTHLY product — $5.99 in the USA since
    /// 2026-09-02, and a different numeral in most storefronts — and when
    /// StoreKit has not answered, which is the normal state for the first
    /// moment of the app's launch surface and permanent in the simulator, this
    /// renders NOTHING. A stale or assumed figure here is exactly the drift
    /// that put $4.99 against €5.99 on the credit ladder's top product.
    ///
    /// ⚠️ `monthlyPriceDisplay`, not `displayPrice`: the latter follows the
    /// paywall's `selectedPlan`, so a user who had tapped Yearly would read
    /// the yearly figure "a month" here. Same trap that misstated the plan row
    /// by 12×.
    ///
    /// ⚠️ **NO TRIAL IS MENTIONED.** The line's 3-day trial was deleted in App
    /// Store Connect on 2026-08-23 after all three conversions were declined,
    /// so a trial claim would be false — and `trialLabel` is nil per Apple ID
    /// eligibility anyway, which is why no trial copy may ever be written as a
    /// literal.
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
    /// The shared `GhostButton` rather than a hand-rolled copy of its shape, so
    /// it picks up any future change to the app's secondary action for free.
    private var smsEscape: some View {
        GhostButton(label: "Just need a one-off verification code?",
                    action: onOpenSms)
    }
}
