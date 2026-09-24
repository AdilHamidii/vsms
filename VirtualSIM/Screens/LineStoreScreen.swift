import StoreKit
import SwiftUI

/// The rented-number store: the My number tab's root for anyone without a
/// live line, and the "Rent another number" cover (`LineStoreCover`).
///
/// ── One scrolling page, top to bottom (design overhaul, 2026-09-24) ──────
///
/// 1. **"Your own number"** and one sentence of what it is.
/// 2. **The country control** — a capsule segmented control built from the
///    LIVE sellable list (a menu when more than three, or when three do not
///    fit; nothing for one), and "Other city ›", which PUSHES the localities
///    (`LineCitiesPage`) on the tab's `NavigationStack`.
/// 3. **The ledger** (`LineLedger`): what the number does and does not do,
///    including the ✗ row for texts sent to US numbers.
/// 4. **The proof line** — the three services that have delivered a real code.
/// 5. **Three available numbers, inline**, as one grouped list, with "Show
///    different numbers". Tapping one goes straight to the paywall.
/// 6. **The price row** — StoreKit only.
/// 7. **"Just need a one-off code?"** — the way to the temp code store.
///
/// The picker SHEET is gone: the numbers are on the page and the place pages
/// are pushed, so there is no nested presentation to get wrong.
///
/// ⚠️ **THE PRICE IS BACK ON THE STORE** by the approved 2026-09-24 design,
/// reversing the 2026-09-09 "no price on this screen" decision. It is never a
/// literal: `priceRow` renders `SubscriptionStore`'s localized display prices
/// and renders NOTHING until StoreKit answers. There is deliberately **no
/// credit pill** anywhere: this product is paid entirely through a StoreKit
/// subscription and never touches the wallet.
///
/// The full 3.1.2(a) disclosure — price, period, renewal terms, Terms/Privacy —
/// is still `LineCheckoutScreen`'s job alone, because that is the screen
/// immediately before the purchase.
struct LineStoreScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    @Environment(SubscriptionStore.self) private var subs
    @Environment(Session.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Jump to the temp-SMS product. Passed in rather than reaching for
    /// `state.tab` directly so the caller owns navigation, matching
    /// `TempScreen(onOpenEsim:)`.
    var onOpenSms: () -> Void

    /// Present only when the store is a COVER (`flow == .lineStoreMore`,
    /// "Rent another number" from a live line's settings). As a tab the tab
    /// bar is the way out; as a cover there was none at all — a subscriber
    /// who opened it was stuck with the pitch for a number they did not want
    /// and no ✕ (owner report 2026-09-06). Same shape as `OrdersScreen`,
    /// which learned this the day it stopped being a tab.
    var onClose: (() -> Void)? = nil

    /// Pushes a place page on whichever stack hosts the store — the tab's
    /// (`AppState.linePath`) or the cover's own (`LineStoreCover`).
    var push: (LineRoute) -> Void

    @State private var appeared = false

    /// How many numbers the screen offers at once.
    ///
    /// Three, not the whole search. This list is one section of a scrolling
    /// page rather than the page itself, and every row past the third pushes
    /// the price — the thing a subscriber has to have read — below the fold.
    /// "Show different numbers" re-rolls the search for anyone who dislikes
    /// all three.
    private static let visibleOffers = 3

    private var hasSession: Bool { session.accessToken != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header.riseIn(appeared, index: 0)
                countryControl.padding(.top, RSpace.xl).riseIn(appeared, index: 1)
                ledger.padding(.top, RSpace.lg).riseIn(appeared, index: 1)
                proofLine.padding(.top, RSpace.md).riseIn(appeared, index: 2)
                numbers.padding(.top, RSpace.xl).riseIn(appeared, index: 2)
                priceRow.padding(.top, RSpace.lg).riseIn(appeared, index: 3)
                oneOffLink.padding(.top, RSpace.xl).riseIn(appeared, index: 4)
            }
            .padding(.horizontal, RSpace.gutter)
            .padding(.top, RSpace.lg)
            .padding(.bottom, RSpace.xxl)
        }
        .scrollIndicators(.hidden)
        .background(theme.bg.ignoresSafeArea())
        // `appeared` is set BEFORE any await: nothing above the numbers needs
        // the network, and awaiting first left the screen at opacity 0.
        .task {
            withAnimation(RMotion.unlessReduced(RMotion.content, reduceMotion)) { appeared = true }
            Analytics.shared.track("line_store_view")
            async let product: () = subs.loadProduct()   // the price row; idempotent
            await state.loadLineCountries(using: LineAPI(client: api))
            if state.lineCountry == nil, let iso = defaultCountry() {
                state.lineCountry = iso
            }
            await searchIfNeeded()
            _ = await product
        }
    }

    /// Runs the inline search once per visit (leaving the tab clears the
    /// draft, so the next visit searches again). Screenshot frames seed the
    /// offers themselves; a live search from `simctl` would wipe them.
    /// 🔴 `search-line-numbers` needs a session: a guest (a later plan) must
    /// not hit it, and a 401 would render as "We couldn't load any numbers".
    private func searchIfNeeded() async {
        guard !ScreenshotMode.isActive, hasSession,
              state.lineOffers.isEmpty, !state.isLoadingLineNumbers else { return }
        await LineStoreSearch.reload(state, api: api)
    }

    /// Where an untouched store looks first: the United States, for everyone.
    ///
    /// Owner decision 2026-09-06. Until then the default was the device's App
    /// Store country when sellable and Toronto otherwise — which put a
    /// Canadian number in front of every European reader, i.e. exactly the
    /// audience the "vSMS WhatsApp EU" campaign sends here. A US number is
    /// what "second number" means to a buyer anywhere, and the country control
    /// still offers every sellable country (and Canada's cities) one tap away.
    /// Canadian storefronts default to the US too, deliberately — "everyone".
    ///
    /// Gated on the catalogue: if the US is not sellable right now (a stale
    /// catalogue fails closed — see `sellableCountry()` server-side) this
    /// returns nil and the server's own default stands, rather than opening
    /// on a country the first search would refuse.
    private static let defaultCountryCode = "US"

    private func defaultCountry() -> String? {
        sellableCountries.contains(where: { $0.countryCode == Self.defaultCountryCode })
            ? Self.defaultCountryCode : nil
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: RSpace.md) {
            VStack(alignment: .leading, spacing: RSpace.sm) {
                Text("Your own number")
                    .displayType(30)
                    .foregroundStyle(theme.text)
                Text("A number that stays yours. Receive codes, texts and calls here.")
                    .font(RFont.text(15))
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let onClose {
                // The ✕ exists because the cover had no exit (owner report 2026-09-06).
                Button(action: onClose) {
                    Image(systemName: RIcon.close)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.text2)
                        .frame(width: 36, height: 36)
                        .background(theme.chipBg, in: .circle)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(PressScaleStyle(scale: 0.92))
                .accessibilityLabel(Text("Close"))
            }
        }
    }

    // MARK: - Country

    /// A capsule segmented control built from the LIVE sellable list (never
    /// hardcoded), a menu past three countries or when three do not fit, and
    /// nothing at all for one. "Other city ›" pushes the localities.
    @ViewBuilder
    private var countryControl: some View {
        let countries = chipOrder
        VStack(alignment: .leading, spacing: RSpace.sm) {
            if countries.count > 1 {
                if countries.count <= 3 {
                    ViewThatFits(in: .horizontal) {
                        CapsuleSegmentedControl(selection: countryBinding(countries),
                                                tags: countries.map(\.countryCode)) { iso, _ in
                            HStack(spacing: 6) {
                                CodeFlag(code: iso, size: 18)
                                Text(verbatim: name(of: iso, in: countries))
                            }
                        }
                        countryMenu(countries)
                    }
                } else {
                    countryMenu(countries)
                }
            }
            if currentCountry?.hasLocalities != false {
                Button { RHaptic.select(); push(.cities) } label: {
                    HStack(spacing: 4) {
                        if let city = state.linePlaceCityLabel {
                            Text(verbatim: city).foregroundStyle(theme.text2)
                            Text(verbatim: "·").foregroundStyle(theme.text3)
                        }
                        Text("Other city").foregroundStyle(theme.text)
                        Image(systemName: RIcon.chev)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.text3)
                    }
                    .font(RFont.text(14, weight: .medium))
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Every sellable country: the default leads, then A–Z by the name the
    /// reader sees, so the control opens on the segment already selected.
    private var chipOrder: [LineCountry] {
        sellableCountries.sorted {
            let a = $0.countryCode == Self.defaultCountryCode
            let b = $1.countryCode == Self.defaultCountryCode
            if a != b { return a }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func name(of iso: String, in countries: [LineCountry]) -> String {
        countries.first { $0.countryCode == iso }?.displayName ?? iso
    }

    private func countryBinding(_ countries: [LineCountry]) -> Binding<String> {
        Binding(
            get: { state.lineCountry ?? Self.defaultCountryCode },
            set: { iso in
                guard iso != state.lineCountry,
                      let c = countries.first(where: { $0.countryCode == iso }) else { return }
                LineStoreSearch.selectCountry(c, state: state, api: api)
            })
    }

    private func countryMenu(_ countries: [LineCountry]) -> some View {
        Menu {
            ForEach(countries) { c in
                Button {
                    RHaptic.select()
                    guard c.countryCode != state.lineCountry else { return }
                    LineStoreSearch.selectCountry(c, state: state, api: api)
                } label: {
                    if c.countryCode == state.lineCountry {
                        Label(c.displayName, systemImage: RIcon.check)
                    } else {
                        Text(verbatim: c.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: RSpace.sm) {
                if let iso = state.lineCountry { CodeFlag(code: iso, size: 22) }
                Text(verbatim: state.linePlaceCountryLabel ?? "")
                    .font(RFont.text(15, weight: .semibold))
                    .foregroundStyle(theme.text)
                Spacer(minLength: RSpace.sm)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.text3)
            }
            .padding(.horizontal, RSpace.lg)
            .frame(minHeight: 44)
            .background(theme.elev, in: .rect(cornerRadius: RRadius.group, style: .continuous))
        }
    }

    /// See `Array<LineCountry>.sellable`.
    private var sellableCountries: [LineCountry] { state.lineCountries.sellable }

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

    // MARK: - Ledger

    /// The honest ledger (spec §4.1). It replaces `sendingNotice` and its
    /// false Canada branch, and `voiceOnlyNotice`.
    ///
    /// 🔴 The ✗ row renders for EVERY country, not only US/PR: 10DLC is
    /// enforced by the RECIPIENT's network, so a Canadian number texting a US
    /// number fails too (CA→US 0 of 8, all `40010`, CLAUDE.md 2026-09-24).
    /// The ✓ row's detail is the inbound NANP limit (the retired reach note's claim): a
    /// number does not receive texts from outside the US and Canada, and the
    /// unqualified "texts" is honest only while this line is on screen.
    private var ledger: some View {
        LineLedger {
            if isVoiceOnly {
                LineLedgerRow(kind: .no,
                              text: Text("Calls only. This number can't send or receive texts."))
            } else {
                LineLedgerRow(kind: .yes,
                              text: Text("Receive texts and verification codes"),
                              detail: Text("From US and Canadian numbers and services."))
            }
            LineLedgerRow(kind: .yes, text: Text("Calls"))
            if !isVoiceOnly {
                LineLedgerRow(kind: .no,
                              text: Text("Texts you send to US numbers usually don't arrive."))
            }
        }
    }

    /// US and Puerto Rico: both are +1 US-carrier long codes under the same
    /// 10DLC rule. Read by checkout's `capabilityNote`, the thread's
    /// failed-send copy and the swap sheet's confirm page, so they cannot
    /// disagree about who is warned. The store's ledger ✗ row is shown for
    /// every country and does not read it.
    static let unreliableSendingCountries: Set<String> = ["US", "PR"]

    // MARK: - Proof, numbers, price

    /// Owner, 2026-09-24: past tense, exactly these three (each has a real
    /// code in `line_messages`). "And most other apps" was unmeasured and is
    /// gone. Anything added here needs the same evidence.
    private var proofLine: some View {
        Text("Has received codes from WhatsApp, TikTok and DoorDash.")
            .font(RFont.text(13))
            .foregroundStyle(theme.text2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Three available numbers, inline. Four states:
    /// - no session: nothing (a guest never searches — a later plan adds sign-in);
    /// - loading, or not answered yet (empty with no reason): the skeleton;
    /// - answered empty or failed: the three-cause empty state, with Try again
    ///   when the cause is unknown (a load failure must not look healthy);
    /// - answered: the grouped list and "Show different numbers".
    @ViewBuilder
    private var numbers: some View {
        if hasSession || ScreenshotMode.isActive {
            VStack(alignment: .leading, spacing: RSpace.sm) {
                if let place = state.linePlaceLabel {
                    MicroLabel("Available now in \(place)")
                } else {
                    MicroLabel("Available now")
                }
                if state.isLoadingLineNumbers
                    || (state.lineOffers.isEmpty && state.lineUnavailableReason == nil) {
                    LineOfferSkeleton(rows: Self.visibleOffers)
                } else if state.lineOffers.isEmpty {
                    unavailable
                } else {
                    LineOfferList(offers: Array(state.lineOffers.prefix(Self.visibleOffers)),
                                  country: state.lineCountry,
                                  placeFallback: state.linePlaceLabel) { pick($0) }
                    GhostButton(label: "Show different numbers", icon: RIcon.refresh,
                                fillsWidth: false) {
                        Task { await LineStoreSearch.reload(state, api: api) }
                    }
                    .padding(.top, RSpace.xs)
                }
            }
        }
    }

    private var isFailure: Bool {
        state.lineUnavailableReason == nil || state.lineUnavailableReason == .unknown
    }

    /// Three causes, and we only ever know one of them (`LineUnavailableCopy`).
    /// Through the shared `EmptyState`, which is the app's one answer to
    /// "there is nothing here": an empty state with an obvious next action
    /// must offer it, and a genuine LOAD FAILURE must not look like a healthy
    /// absence. Hence the `fail` tint on the unknown case only; a paused line
    /// or a dry city is not an error.
    private var unavailable: some View {
        let reason = state.lineUnavailableReason
        // A load failure offers Try again (it must not look like a healthy
        // absence); paused and "no stock" do not.
        //
        // (if/else rather than `?:`: a ternary over these optional tuples
        // crashes the Swift 6.4 type checker.)
        var retry: (label: String, action: () -> Void)? = nil
        if isFailure {
            retry = (label: String(localized: "Try again"),
                     action: { Task { await LineStoreSearch.reload(state, api: api) } })
        }
        // A refused COUNTRY cannot be fixed by another city; paused has no
        // escape at all (every city is paused).
        var elsewhere: (label: String, action: () -> Void)? = nil
        if reason != .paused {
            let route: LineRoute = reason == .countryNotSellable
                && state.lineCountries.offersCountryChoice ? .countries : .cities
            elsewhere = (label: reason == .countryNotSellable
                            ? String(localized: "Try another country")
                            : String(localized: "Try another city"),
                         action: { push(route) })
        }
        return EmptyState(
            icon: reason == .paused ? "pause.circle" : "phone.badge.waveform",
            title: LineUnavailableCopy.title(for: reason),
            message: LineUnavailableCopy.body(for: reason),
            tint: isFailure ? theme.fail : theme.text2,
            primary: retry,
            secondary: elsewhere)
    }

    /// The monthly price, StoreKit only (spec §4.1). "{regular}/month" leads;
    /// the intro sits beneath, only behind the eligibility gate
    /// (`monthlyIntroPriceDisplay` is nil for an ineligible Apple ID). Hidden
    /// until StoreKit answers — never a placeholder price.
    ///
    /// ⚠️ `monthlyPriceDisplay`, not `displayPrice`: the latter follows the
    /// paywall's `selectedPlan`, so a user who had tapped Yearly would read
    /// the yearly figure "a month" here.
    @ViewBuilder
    private var priceRow: some View {
        if let regular = subs.monthlyPriceDisplay {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(regular)/month")
                    .numberStyle(size: 20, color: theme.text)
                if let intro = subs.monthlyIntroPriceDisplay {
                    Text("\(intro) your first month · new subscribers")
                        .font(RFont.text(13))
                        .foregroundStyle(theme.text2)
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// Temp SMS is second in the business, not retired: this is the only
    /// thing standing between a user who wants a one-off code and a monthly
    /// subscription pitch.
    private var oneOffLink: some View {
        GhostButton(label: "Just need a one-off code?", action: onOpenSms)
    }

    // MARK: - Pick

    /// Tap a number → paywall (3 taps to Apple's sheet).
    private func pick(_ offer: LineNumberOffer) {
        RHaptic.select()
        Analytics.shared.track("line_number_picked", [
            "country": .string(offer.countryCode ?? state.lineCountry ?? "unknown")])
        state.lineOffer = offer
        state.intent = .line
        if state.flow == .lineStoreMore {
            // Cover → cover is not a swap SwiftUI performs reliably
            // (`fullScreenCover(item:)`), so dismiss first, raise next runloop.
            state.flow = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(320))
                state.flow = .lineCheckout
            }
        } else {
            state.flow = .lineCheckout
        }
    }
}
