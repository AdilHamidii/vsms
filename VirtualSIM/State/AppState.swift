import AdServices
import SwiftUI

/// Tab order encodes the business, and the business changed on 2026-08-05:
/// rented numbers first, temp SMS second, temp e-mail as an acquisition hook,
/// eSIM eventually. `line` therefore leads and is the launch tab.
///
/// ⚠️ Defaulting the launch tab to `.line` is a product bet worth watching. A
/// new user used to land on a free-to-browse SMS catalogue and now lands on a
/// $9.99/month pitch, while signup → first-order is already the app's weakest
/// step (21.7% lifetime). `LineStoreScreen` keeps an explicit route across to
/// the SMS product for exactly that reason. The revert is one line here.
///
/// `tab` is not persisted, so growing this enum and moving its default carry no
/// decode risk — unlike `OrderStatus`, which ships to every phone.
enum AppTab: String, Hashable, CaseIterable {
    case line, home, esim, orders, account
}

enum FlowStage: String, Hashable, Identifiable {
    case checkout, waiting, otp, recovery, esimCheckout, esimDetail
    case emailWaiting, emailCode
    /// The rented line. `thread` and `dialer` are covers rather than navigation
    /// pushes, and that is forced by the layout rather than chosen: `TabBar` is
    /// a ZStack overlay pinned to the bottom of `ContentView` on every tab, so
    /// a NavigationStack push would leave the floating tab bar sitting on top
    /// of the message composer.
    case lineCheckout, lineProvisioning, thread, dialer
    /// Start a conversation with someone who has never texted us.
    ///
    /// Without this the Messages segment could only ever REPLY: threads are
    /// created by an inbound message or by an outbound send, and every path to
    /// `.thread` went through a row that already existed. Calls have had an
    /// initiating affordance since the dialer landed; messages had none.
    case compose
    /// The number store, opened OVER a live line to rent an additional one.
    /// The tab itself only shows the store when there is no line at all, so
    /// without this a second number is unreachable — which made the whole
    /// multi-number feature impossible to exercise.
    case lineStoreMore
    /// Order history.
    ///
    /// It was a TAB until 2026-08-06. Home already carries a `Recent` section
    /// with a "See all", so a whole tab for the same data was the fifth item
    /// in a bar competing for the thumb — and the least-used one, since the
    /// three rows on Home answer the question most of the time. It is a cover
    /// now, reached from that link and from the three places that say "check
    /// your orders". Removing it from the bar had to keep every one of those
    /// routes working, which is why this exists rather than the tab simply
    /// disappearing.
    case orders
    var id: String { rawValue }
}

/// Which product the user is currently buying.
///
/// This exists because `creditsShortfall` used to infer it, and inference was
/// wrong. It branched on `if let plan = checkoutEsimPlan` with no `flow` check —
/// deliberately, because the credits pill in the eSIM tab opens the ROOT sheet
/// with `flow == nil`. But `flow`'s `didSet` clears the SMS draft and **never
/// cleared `checkoutEsimPlan`**, which was assigned in exactly one place and set
/// to nil in none. So after a single visit to an eSIM checkout, every later
/// "how many credits do you need?" answered for that plan — for the rest of the
/// session, on every screen, including SMS checkout.
///
/// `CreditsSheet` is product-agnostic and receives only `needed:`, so it had no
/// way to notice. Adding a third product to that if-chain would have multiplied
/// the bug rather than added to it.
///
/// Stated once so it generalises: **when a write path branches on `flow` but the
/// read path doesn't, the two disagree the moment the flow ends.** The intent is
/// therefore set explicitly at each entry point and cleared centrally in
/// `flow`'s `didSet`, exactly as `configuringService`/`configuringCountry`
/// already discipline the SMS draft.
/// `.line` is the odd one out and deliberately so: the rented line is billed by
/// StoreKit subscription and spends NO credits, so `creditsShortfall` returns 0
/// for it rather than answering with whatever SMS route was last configured.
/// The Number tab also renders no credit pill at all, which removes the read
/// path this whole enum exists to discipline.
enum PurchaseIntent: String, Hashable {
    case sms, esim, email, line, call
}

/// What the post-failure recovery card needs to know. Stored on AppState
/// (FlowStage is raw-value-backed, so cases can't carry payloads — same
/// pattern as checkoutService/checkoutCountry).
struct RecoveryContext {
    enum Reason { case expired, canceled }
    let service: Service
    let failedCountry: Country
    let reason: Reason
    /// Credits put back on the wallet for the order that just ended. The
    /// backend refunds on BOTH terminal paths (`poll-active-orders` expiry and
    /// `cancel-order`), so any order reaching this card was refunded — but the
    /// card used to assert that in fixed copy with no amount. Showing the real
    /// number is the difference between "trust me" and a receipt. nil only if
    /// we somehow reached recovery without the order row.
    var refundedCredits: Int? = nil
}

/// Cold-launch readiness, driving `SplashScreen`.
///
/// `failed` is reserved for the CATALOG failing, which is the only fetch Home
/// cannot render truthfully without — see `AppState.coldStart`.
enum BootPhase: Equatable { case loading, ready, failed }

/// Internal, not private: `AuthGate` reads `isDark`/`accent` through
/// `@AppStorage` so the splash it shows during session bootstrap is already
/// themed the way `ContentView` will theme the app a moment later. Sharing the
/// constants keeps the two from drifting to different key strings.
enum PrefKey {
    /// Legacy Bool, read once for migration — see `AppState.storedAppearance`.
    static let isDark           = "pref.isDark"
    static let appearance       = "pref.appearance"
    static let accent           = "pref.accent"
    static let waitingAnimation = "pref.waitingAnimation"
    static let otpAnimation     = "pref.otpAnimation"
    static let showMetrics      = "pref.showMetrics"

    /// The `id` of the announcement this user waved away. Stored as the id and
    /// not a Bool so the NEXT announcement still shows — see
    /// `AppState.visibleAnnouncement`.
    static let dismissedAnnounce = "announce.dismissedId"

    // Review-prompt gating (App Store 5.6.4: native prompt, no incentive).
    static let successfulCodes  = "review.successfulCodes"
    static let lastCountedOrder = "review.lastCountedOrder"
    static let lastPromptVer    = "review.lastPromptVersion"

    /// The most recent order the client noticed carrying a code it had not
    /// seen before, plus when it noticed — so a foreground check can still ask
    /// for a review after a cold launch, for someone who read the code off a
    /// lock-screen push and never opened `OtpScreen` at all. See
    /// `AppState.reviewableRecentDelivery`.
    static let lastDeliveredOrderId = "review.lastDeliveredOrderId"
    static let lastDeliveredAt      = "review.lastDeliveredAt"

    /// eSIM order ids whose install flow has been opened at least once.
    static let esimInstallsStarted = "esim.installsStarted"

    /// Set once the AdServices attribution token has been accepted by
    /// `record-attribution`. The token is per INSTALL, so one successful
    /// submission is all there ever is to send — and re-sending on every cold
    /// launch would be a round-trip that can only ever overwrite a row with
    /// itself.
    static let attributionSubmitted = "attribution.submitted"
}

@Observable
final class AppState {
    /// Temp SMS is the launch tab (owner decision 2026-08-08). The rented line
    /// led for one release on the reasoning that it is the premium product —
    /// but it is a $9.99/mo subscription, while temp SMS is what the store
    /// listing, the keywords and essentially all acquisition are actually
    /// about, and it is the line every arriving user can afford today.
    var tab: AppTab = .home
    var balance: Int = 0
    var services: [Service] = SeedData.services
    var countries: [Country] = SeedData.countries
    var routes: [Route] = []
    /// O(1) lookup index built from `routes`. Rebuilt in loadCatalog so we
    /// don't linear-scan 17k+ rows on every cost() call.
    @ObservationIgnored
    private var routeIndex: [String: Route] = [:]

    /// The provider's own top-10 success rates per service. NOT our delivery —
    /// see `CountryRank`. Steering input and an attributed display; never a badge.
    var countryRanks: [CountryRank] = []
    /// `"serviceId|countryId"` -> rank, for O(1) lookup during steering.
    @ObservationIgnored
    private var rankIndex: [String: CountryRank] = [:]
    /// `serviceId` -> that service's ranks, best first, for the "Top countries"
    /// list. Derived ONCE here rather than filtered per body evaluation:
    /// `AppState` is `@Observable`, so a computed property that filters 390 rows
    /// re-runs on every redraw of every view that reads it — the same trap that
    /// made the eSIM map rebuild all 66 annotations per frame.
    @ObservationIgnored
    private(set) var ranksByService: [String: [CountryRank]] = [:]
    /// True until a user with no order history has actually PICKED a service.
    ///
    /// `applyStartupSelection` still seeds a suggested pair so the hero has
    /// something to render and price — this flag is what stops that suggestion
    /// being purchasable as though the user had chosen it. Cleared by
    /// `chooseService`, and by `applyStartupSelection` for anyone who has
    /// ordered before (a returning user genuinely wants their last route back).
    var needsServiceChoice = false

    /// Guards one-time first-run selection seeding (see applyStartupSelection).
    @ObservationIgnored
    private var didSeedStartupSelection = false
    var lastService: Service
    var lastCountry: Country
    var orders: [Order] = []
    var filter: SortFilter = .all
    var profile: Profile?

    /// Credits a friend lands with when they join on an invite code.
    ///
    /// ⚠️ TRACKS `redeem_referral` ALONE — deliberately NOT the sum of the two
    /// grants. It used to be 5 (`handle_new_user`'s 3 at signup plus
    /// `redeem_referral`'s 2), which was correct on the day it was written and
    /// silently became a 150% overstatement on 2026-08-04 when the signup grant
    /// was set to 0 permanently. A joiner now lands with exactly 2.
    ///
    /// The signup grant is a SERVER value that changes with no release — it has
    /// been 0, 1, 3 and 5 — and the client cannot read it (`app_config`'s RLS
    /// whitelist exposes only maintenance/announcement/esim_paused, and the
    /// invite is rendered before any of that would help). Summing a volatile
    /// server number into shipped copy therefore cannot be kept honest; the
    /// referral half is set by one function that changes only by migration.
    ///
    /// So: if the signup grant is ever restored, do NOT add it back in here.
    /// This constant is the referral reward, and the copy it feeds says what
    /// the invite itself is worth.
    ///
    /// Same rule as OnboardingScreen's: never render a credit amount the server
    /// is free to change underneath you. Keep in lockstep with
    /// `redeem_referral`'s `wallet_credit(p_referee, 2, 'referral_invitee', …)`.
    static let inviteJoinerCredits = 2

    /// What the REFERRER earns when their invitee buys a first pack.
    ///
    /// Added for the same reason as the joiner figure: it was written as a bare
    /// "5" in the two surfaces that mention it, so a change to `redeem_referral`
    /// would have left the app quoting the old number with nothing to catch it.
    /// Keep in lockstep with `redeem_referral`'s
    /// `wallet_credit(p_referrer, 5, 'referral_reward', …)`.
    static let inviteReferrerCredits = 5

    /// Share text for the invite, in ONE place.
    ///
    /// It previously lived duplicated in `OtpScreen` and `AccountScreen`, each
    /// carrying a comment asking the next editor to keep it identical to the
    /// other — which is precisely how two copies drift apart.
    var inviteMessage: String? {
        guard let code = profile?.referralCode else { return nil }
        return String(localized: "Get a private temporary number for verification codes on vSMS. Join with my code \(code) and start with \(Self.inviteJoinerCredits) free credits: https://apps.apple.com/app/id6774768570")
    }
    var maintenance: MaintenanceStatus = .off

    /// Deliberately-published slice of `app_config` — the owner's announcement
    /// and whether the eSIM line is paused.
    var appStatus: AppStatus = .unknown

    /// Whether eSIMs are off sale server-side. Lets the eSIM tab STATE that,
    /// instead of inferring it from an empty catalog — which is also what an
    /// ordinary failed fetch looks like.
    var esimPaused: Bool { appStatus.esimPaused }

    private var dismissedAnnouncementId: String =
        UserDefaults.standard.string(forKey: PrefKey.dismissedAnnounce) ?? "" {
        didSet {
            UserDefaults.standard.set(dismissedAnnouncementId,
                                      forKey: PrefKey.dismissedAnnounce)
        }
    }

    /// The banner to show, or nil. Dismissal is keyed on the announcement's own
    /// `id`, so waving one away does NOT silence the channel: the next thing the
    /// owner posts carries a new id and shows again.
    var visibleAnnouncement: Announcement? {
        guard let a = appStatus.announcement, a.isLive else { return nil }
        return a.id == dismissedAnnouncementId ? nil : a
    }

    func dismissAnnouncement() {
        guard let a = appStatus.announcement else { return }
        dismissedAnnouncementId = a.id
    }

    /// Swallows its own failure on purpose. A banner is additive: failing to
    /// fetch it must never disturb a screen that is otherwise fine, and the
    /// previous value staying put is better than blanking a live notice
    /// because one request timed out.
    func refreshAppStatus(using api: AppStatusAPI) async {
        if let s = try? await api.fetch() { appStatus = s }
    }

    /// Clearing the checkout draft here is load-bearing — see
    /// `configuringService`. `flow` is assigned from a dozen call sites
    /// (`state.flow = nil` in CheckoutScreen, OtpScreen, EsimDetail, plus the
    /// terminal paths in this file); resetting the draft at each of them would
    /// be one forgotten line away from bringing the stale-price bug back, so it
    /// happens once, centrally, on every transition out of `.checkout`.
    var flow: FlowStage? {
        didSet {
            // The eSIM plan and the purchase intent are cleared on ANY exit,
            // not just out of `.checkout`. `checkoutEsimPlan` was previously
            // never cleared anywhere, which is what let a stale plan answer
            // `creditsShortfall` for the rest of the session — see PurchaseIntent.
            if flow == nil {
                checkoutEsimPlan = nil
                emailDomain = nil
                // The line's per-flow drafts. `lineReservation` is NOT cleared
                // here on purpose — it belongs to the Number TAB and is read by
                // `LineStoreScreen` at `flow == nil`, so clearing it on every
                // flow exit would throw away the held number the moment the
                // user closed the paywall. It is cleared on leaving the tab
                // instead, in ContentView's `.onChange(of: state.tab)`.
                openThreadId = nil
                // `dialerDigits` was cleared here and lived on AppState — but
                // `DialerScreen` keeps its own `@State private var digits`, so
                // the AppState copy was written by exactly one line and read by
                // nothing. A draft that only one side of the app knows about is
                // worse than no draft: it looks like the clearing rule is
                // covered when it is not.
                intent = tab == .line ? .line : .sms
            }
            guard flow != .checkout else { return }
            checkoutService = nil
            checkoutCountry = nil
            checkoutPremium = false
            // Cleared with the rest of the draft. A concurrent-order intent that
            // outlived its checkout would shorten the dedupe window on some
            // unrelated later order — the same class of bug as the stale
            // checkout draft and the stale `checkoutEsimPlan`.
            wantsConcurrentOrder = false
        }
    }

    /// What the user is buying right now. See `PurchaseIntent`.
    var intent: PurchaseIntent = .sms
    /// Context for the `.recovery` flow stage; set wherever an order ends
    /// without a code, cleared by retry/dismiss.
    var recovery: RecoveryContext?

    // eSIM product line
    // ── Temporary email ──────────────────────────────────────────────────
    /// Home's Numbers / E-mails segmented selection. Purely a view mode; the
    /// authoritative "what am I buying" is `intent`, set at the entry points.
    var emailMode = false
    var emailOrders: [ServerEmailOrder] = []
    /// Live domain options for the service being configured. Refetched whenever
    /// the service changes — stock is per (service, domain) and moves.
    var emailDomains: [EmailDomainOption] = []
    var isLoadingEmailDomains = false
    /// The domain chosen in the picker; drives price and the CTA.
    var emailDomain: EmailDomainOption?
    var activeEmailOrder: ServerEmailOrder?
    var isBuyingEmail = false

    // ── Rented second number (the fourth product line) ───────────────────
    /// The caller's line, from the `my_line` VIEW. nil = they have never had
    /// one; a `.released` line is still returned so its history survives.
    /// EVERY line the user holds, newest first. Credits can rent several.
    var lines: [Line] = []
    /// Which one the Number tab is showing. nil = the first live one.
    var selectedLineId: String?

    /// The line currently on screen.
    ///
    /// Kept as `line` so the dozens of existing call sites keep their meaning,
    /// but it now RESOLVES against `lines` instead of being the only line there
    /// is. Falls back to the first live line, then to the newest of any status —
    /// a user whose only line is released still gets its history rather than an
    /// empty tab.
    var line: Line? {
        if let id = selectedLineId, let match = lines.first(where: { $0.id == id }) {
            return match
        }
        return lines.first(where: { $0.status.isLive }) ?? lines.first
    }

    /// True once a switcher is worth showing. One line should look exactly as
    /// it did before multi-number existed.
    var hasMultipleLines: Bool { lines.filter { $0.status.isLive }.count > 1 }

    var lineThreads: [LineThread] = []
    /// Messages keyed by thread id, so opening a thread the user has already
    /// read does not blank the screen while the fetch runs.
    var lineMessages: [String: [LineMessage]] = [:]
    var lineCalls: [LineCall] = []

    /// International per-minute prices, in credits. Empty until loaded AND
    /// empty when no destination is enabled — the dialer must treat "no match"
    /// as uncallable in both cases, never as free.
    var voiceRates: [VoiceRate] = []

    /// Credits the dialer needs for the call being composed, DECLARED by it
    /// alongside `intent = .call`.
    ///
    /// Same rule as `checkoutEsimPlan`: the amount is stated by the screen that
    /// knows it, never re-derived by `creditsShortfall`. It must be cleared
    /// wherever `intent` is, or the credits pill keeps sizing packs for a call
    /// the user abandoned — which is precisely the bug `PurchaseIntent` was
    /// introduced to kill, twice.
    var callCreditsNeeded: Int?

    /// The destination being dialled, for the credits sheet. Catalog text, so
    /// it is rendered verbatim — translating a country label we got from the
    /// server is the same mistake as translating a service name.
    var callDestinationLabel: String?
    /// Cities we sell numbers in. Seeded so the picker renders instantly, then
    /// replaced by the server's list on the first search — see `LineCity.seeded`
    /// for why a city is safe to seed when an area code is not.
    var lineCities: [LineCity] = LineCity.seeded
    /// Every number the search returned, for the user to pick from. Showing one
    /// number is a take-it-or-leave-it; showing eight is a choice, and the
    /// search already returns up to eight at no extra cost.
    var lineOffers: [LineNumberOffer] = []
    /// The one the user picked, and the hold on it if we have one.
    /// Owned by the Number TAB (read at `flow == nil`), so it is cleared on
    /// leaving the tab rather than in `flow.didSet` — see the note there.
    var lineOffer: LineNumberOffer?
    var lineReservation: LineReservation?
    var lineCity: String?
    var isLoadingLineNumbers = false
    /// Set when a search came back empty so the store can say WHICH of the two
    /// causes it knows about, instead of rendering a blank screen.
    var lineUnavailableReason: LineUnavailableReason?
    /// Thread open in the `.thread` cover. Cleared in `flow.didSet`.
    var openThreadId: String?

    var esimPlans: [EsimPlan] = []
    var esimOrders: [EsimOrder] = []
    var checkoutEsimPlan: EsimPlan?
    var activeEsimOrder: EsimOrder?
    var isBuyingEsim = false
    @ObservationIgnored
    private var esimPlanIndex: [String: EsimPlan] = [:]
    var checkoutService: Service?
    var checkoutCountry: Country?
    /// True when the Real-SIM (premium) tier is selected in checkout.
    /// Never sticky across a route change — every reset site recomputes it from
    /// the NEW route via `defaultPremium(for:country:)`.
    var checkoutPremium = false

    /// Whether checkout should OPEN on the real-SIM tier for this route.
    ///
    /// Standard used to be the unconditional default, and for the services
    /// people actually come here for that meant defaulting to a tier our own
    /// orders say does not work. Measured 2026-07-30: instagram is **2 of 23**
    /// all-time and took **12 first orders for 0 codes**; whatsapp 1 of 9;
    /// discord 0 of 3. Meta and Telegram reject numbers they recognise as
    /// temporary, which is exactly what the real-SIM tier exists for — and it
    /// had never been sold once in 192 orders, because it was an opt-in chip
    /// the user had to notice.
    ///
    /// The uplift is small where it matters (instagram 3cr vs 2cr, facebook
    /// 4 vs 3, discord 3 vs 2) — ~1 credit for a materially better shot at the
    /// thing they came for. Standard stays selectable.
    ///
    /// Returns false whenever the route carries no premium price, preserving
    /// the invariant behind `effectiveCheckoutPremium`: never send
    /// `tier: "premium"` to a route without one, because the backend rejects it
    /// and the Standard chip is hidden in exactly that case — a dead end.
    func defaultPremium(for service: Service, country: Country) -> Bool {
        guard premiumCost(for: service, country: country) != nil else { return false }
        // Real-SIM-only routes have no other option to open on.
        if realSimOnly(for: service, country: country) { return true }
        // The COUNTRY can be the problem rather than the service. Measured
        // 2026-07-31, the US pool is ~96% `textnow` (a VoIP texting service)
        // and US VoIP orders returned 0 codes on 5 attempts, 175 of the 198
        // credits charged that day. Driven by measured country evidence, not a
        // hardcoded "us", so it corrects itself as the data moves.
        if country.deliversPoorly { return true }
        return service.deliversPoorly
    }

    /// Premium is only real when the CURRENT route actually carries a premium
    /// price. Reading `checkoutPremium` directly let a stale selection survive
    /// a route change and send `tier: "premium"` to a route with no premium
    /// tier, which the backend rejects with `premium_unavailable` — a dead end,
    /// because the Standard chip is hidden in exactly that situation. The
    /// pickers also reset the flag (ContentView), but this makes it impossible
    /// for a catalog refresh under an open checkout to strand the user.
    var effectiveCheckoutPremium: Bool {
        // The mirror of the guard below: on a real-SIM-only route the Standard
        // chip is not rendered, so a user who never taps anything would send
        // `tier: standard` and be refused with `real_sim_required` — a dead end
        // with no visible control to escape it.
        if realSimOnly(for: configuringService, country: configuringCountry) { return true }
        guard checkoutPremium else { return false }
        return premiumCost(for: configuringService, country: configuringCountry) != nil
    }

    /// The (service, country) pair the user is currently looking at a price
    /// for: the checkout draft while the checkout flow is open, otherwise
    /// Home's selection.
    ///
    /// The draft is only meaningful INSIDE `.checkout`. It used to outlive its
    /// flow — `startCheckout` wrote it and nothing ever cleared it — while
    /// every picker read `checkoutService ?? lastService` with no flow check.
    /// So after one visit to checkout (tapping "order again" on a history row
    /// is enough), the sheets opened from Home quoted the LAST CHECKED-OUT
    /// service: Home read "Deliveroo · Kyrgyzstan · 4 cr" while the country
    /// sheet opened from that same screen priced every row for Leboncoin and
    /// showed Kyrgyzstan at 60 cr. Availability and the "Best success" ranking
    /// were computed for the wrong service too, so a country could read
    /// "Unavailable" while being perfectly bookable for the selected service.
    ///
    /// Reading the draft outside `.checkout` is therefore always a bug. These
    /// two accessors are the single definition of what the user is
    /// configuring — prefer them to `checkoutService ?? lastService` at the
    /// call site, which is the shape that hid the mismatch.
    var configuringService: Service {
        flow == .checkout ? (checkoutService ?? lastService) : lastService
    }
    var configuringCountry: Country {
        flow == .checkout ? (checkoutCountry ?? lastCountry) : lastCountry
    }
    var activeOrder: Order?
    /// True while a create-order call is in flight — guards against double-tap
    /// double-charge and lets the checkout CTA show an in-progress state.
    var isPlacingOrder = false

    /// eSIM order ids whose install flow has already been opened.
    ///
    /// An LPA activation code is SINGLE-USE: once iOS consumes the profile the
    /// same QR/URL fails, and Apple's error says nothing about why — it just
    /// looks like we sold a broken eSIM. Persisted (not view state) because
    /// the user leaves the app for Settings during install and comes back to a
    /// freshly-built screen. This WARNS rather than blocks: if the first
    /// attempt died before the profile was consumed, they must still be able
    /// to retry.
    private(set) var esimInstallsStarted: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: PrefKey.esimInstallsStarted) ?? [])
    }()

    func hasStartedEsimInstall(_ orderId: String) -> Bool {
        esimInstallsStarted.contains(orderId)
    }

    func markEsimInstallStarted(_ orderId: String) {
        guard !esimInstallsStarted.contains(orderId) else { return }
        esimInstallsStarted.insert(orderId)
        UserDefaults.standard.set(Array(esimInstallsStarted),
                                  forKey: PrefKey.esimInstallsStarted)
    }
    /// Consecutive failures of the provider-dependent `check-order` poll.
    /// Two in a row means stop trusting it and reconcile against the order row
    /// instead — see `pollActiveOrder`.
    @ObservationIgnored
    private var pollFailureStreak = 0

    /// Latest error string for UI banners. Phase F wires real banner UI.
    var lastError: String?

    /// Cold-launch readiness. `SplashScreen` covers the app until this leaves
    /// `.loading`, so the first Home frame a user ever sees is a true one.
    ///
    /// Before this, `.task` populated an AppState that starts from `SeedData`
    /// with `routes = []`, so `cost(for:country:)` returned nil for every pair
    /// and the primary CTA read "Unavailable · Pick another country" for the
    /// whole fetch. The seed default is WhatsApp/United States, which is in
    /// `blocked_routes` and therefore never bookable at all — so it stayed
    /// wrong until `applyStartupSelection()` ran at the END of the chain.
    private(set) var bootPhase: BootPhase = .loading

    /// 0...1 over the steps `coldStart` has actually completed.
    ///
    /// Never synthetic. A timer-driven bar looks like information and carries
    /// none — the same class of claim as a seeded success rate, which this app
    /// already refuses to render.
    private(set) var bootProgress: Double = 0

    /// System / Light / Dark. See `AppearanceMode` — `.system` is the default,
    /// so the launch screen, the splash and the app all agree out of the box.
    var appearance: AppearanceMode {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: PrefKey.appearance) }
    }
    /// Brand colour. Affects `ink`/`inkSoft`/`glow` only — semantic
    /// success/warn/fail colours are fixed. See `AccentColor`.
    var accent: AccentColor {
        didSet { UserDefaults.standard.set(accent.rawValue, forKey: PrefKey.accent) }
    }
    var waitingAnimation: WaitingAnimation {
        didSet { UserDefaults.standard.set(waitingAnimation.rawValue, forKey: PrefKey.waitingAnimation) }
    }
    var otpAnimation: OtpAnimation {
        didSet { UserDefaults.standard.set(otpAnimation.rawValue, forKey: PrefKey.otpAnimation) }
    }
    var showMetrics: Bool {
        didSet { UserDefaults.standard.set(showMetrics, forKey: PrefKey.showMetrics) }
    }

    /// Read the appearance preference, migrating the old `pref.isDark` Bool.
    ///
    /// The distinction that matters is **explicitly set vs never touched**, and
    /// `defaults.bool(forKey:)` cannot express it — it returns false for both,
    /// which is exactly how "never chose" became "wants light" for every user.
    /// So this checks `object(forKey:)` for presence:
    ///   - `pref.isDark` present  → the user really did pick; honour it.
    ///   - absent                 → they never chose, so follow the device.
    ///
    /// Shared with `AuthGate`, which needs the same answer before `AppState`
    /// exists. Deliberately does NOT write back: leaving the old key untouched
    /// keeps a downgrade to the shipped build (1.4/1.5) working unchanged.
    static func storedAppearance(_ defaults: UserDefaults = .standard) -> AppearanceMode {
        if let raw = defaults.string(forKey: PrefKey.appearance),
           let mode = AppearanceMode(rawValue: raw) {
            return mode
        }
        if defaults.object(forKey: PrefKey.isDark) != nil {
            return defaults.bool(forKey: PrefKey.isDark) ? .dark : .light
        }
        return .system
    }

    init() {
        self.lastService = SeedData.services.first ?? AppState.fallbackService
        self.lastCountry = SeedData.countries.first ?? AppState.fallbackCountry

        let defaults = UserDefaults.standard
        self.appearance = AppState.storedAppearance(defaults)
        // Must match AuthGate's @AppStorage default. Two defaults for one
        // preference is how the pre-sign-in screens end up a different colour
        // from the app they lead into.
        self.accent = AccentColor(
            rawValue: defaults.string(forKey: PrefKey.accent) ?? ""
        ) ?? .green
        self.waitingAnimation = WaitingAnimation(
            rawValue: defaults.string(forKey: PrefKey.waitingAnimation) ?? ""
        ) ?? .pulse
        self.otpAnimation = OtpAnimation(
            rawValue: defaults.string(forKey: PrefKey.otpAnimation) ?? ""
        ) ?? .cascade
        self.showMetrics = defaults.object(forKey: PrefKey.showMetrics) as? Bool ?? true
        // Seed the intent to match the launch tab. Everywhere else it is set by
        // a tab change or a flow entry, and neither fires on the tab the app
        // opens ON — so without this the app would boot on the Number tab
        // holding `.sms`.
        self.intent = tab == .line ? .line : .sms
    }

    var deliveredCount: Int { orders.filter { $0.status == .received }.count }

    /// Whether to surface Apple's native review sheet now that a fresh code
    /// was delivered. Returns true at most once per app version, from the
    /// user's FIRST successful code — a genuinely positive moment, and for
    /// most users the only one (see the threshold note below).
    ///
    /// No credits or incentive are attached: App Store guideline 5.6.4 forbids
    /// paying for reviews. The system further throttles the actual sheet
    /// (~3 prompts/user/year), so we spend that quota only on happy outcomes.
    func shouldRequestReview(forOrderId id: String) -> Bool {
        // 🔴 A screenshot run delivers a code by construction, so this fires
        // and Apple's rating sheet lands squarely over the code card — which
        // is exactly the frame the whole harness exists to produce. It reached
        // an App Store upload once. Gated here rather than at the two call
        // sites so a third caller cannot reintroduce it, and it also stops a
        // harness run burning the user's ~3-prompts-per-year system quota.
        if ScreenshotMode.isActive { return false }
        let d = UserDefaults.standard
        // A re-render of the same delivery must not double-count.
        guard d.string(forKey: PrefKey.lastCountedOrder) != id else { return false }
        d.set(id, forKey: PrefKey.lastCountedOrder)

        let count = d.integer(forKey: PrefKey.successfulCodes) + 1
        d.set(count, forKey: PrefKey.successfulCodes)
        // Fires on the FIRST delivered code, lowered from the second on
        // 2026-07-31. Ratings are what decide App Store search POSITION —
        // keywords only decide which queries you are eligible for — and the US
        // storefront shows 0 ratings. Measured the same day: 20 users have ever
        // received a code but only 7 ever reached two, and those 7 produced all
        // 3 reviews the app has (~43%). The prompt was working; the eligible
        // pool was the constraint, so the threshold was the thing to move.
        //
        // Still compliant with App Store 5.6.4 — this is Apple's native prompt,
        // nothing is rewarded for leaving a review, and there is no custom UI or
        // App Store deep link. It stays gated to once per app version and
        // de-duped per order above, and Apple independently caps its own prompt
        // at three per year.
        guard count >= 1 else { return false }

        let version = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard d.string(forKey: PrefKey.lastPromptVer) != version else { return false }
        d.set(version, forKey: PrefKey.lastPromptVer)
        return true
    }

    /// Records that the client just noticed a code on an order it hadn't seen
    /// carrying one before — see the diff in `loadOrders`. Persisted (not just
    /// in-memory) so a cold launch after the app was force-quit or backgrounded
    /// through the delivery still has something to check on the next foreground.
    private func recordCodeDelivered(orderId: String) {
        let d = UserDefaults.standard
        d.set(orderId, forKey: PrefKey.lastDeliveredOrderId)
        d.set(Date().timeIntervalSince1970, forKey: PrefKey.lastDeliveredAt)
    }

    /// Whether THIS foreground should surface the native review prompt for a
    /// user who never opened `OtpScreen`/`EmailCodeScreen` at all — the
    /// designed flow for anyone who reads the code straight off a lock-screen
    /// push and pastes it into the other app without reopening vSMS. Bounded
    /// to 30 minutes so a delivery discovered long after the fact (e.g. an
    /// unrelated cold launch days later) doesn't retroactively read as a fresh
    /// happy moment. Every other gate — once per app version,
    /// per-order dedupe — still lives in `shouldRequestReview`, which this
    /// calls rather than duplicates.
    func reviewableRecentDelivery() -> Bool {
        let d = UserDefaults.standard
        guard let orderId = d.string(forKey: PrefKey.lastDeliveredOrderId) else { return false }
        let deliveredAt = d.double(forKey: PrefKey.lastDeliveredAt)
        let elapsed = Date().timeIntervalSince1970 - deliveredAt
        guard deliveredAt > 0, elapsed >= 0, elapsed <= 30 * 60 else { return false }
        return shouldRequestReview(forOrderId: orderId)
    }

    // MARK: - Cold launch

    /// The cold-launch sequence, in the order Home needs it, reporting progress
    /// so the splash can show real work rather than a timer.
    ///
    /// Readiness is deliberately NOT "the chain finished". The eSIM catalog and
    /// eSIM orders are read only by the eSIM tab, so gating the reveal on them
    /// would hold a fully correct Home screen behind two fetches nobody is
    /// looking at. They run AFTER `bootPhase` goes `.ready`, behind the
    /// already-visible UI.
    ///
    /// Everything here stays sequential on the main actor. Overlapping these
    /// would genuinely shorten the wait — measured, the six steps are ~3 s of
    /// which the catalog is ~1.5 s — but `AppState` is a plain `@Observable`
    /// class with no actor isolation, so `async let` over methods that all
    /// mutate `self` would be a data race, not a speed-up. Doing that safely
    /// means making the API calls return values instead of mutating, which is a
    /// separate change with its own risk.
    func coldStart(api: APIClient) async {
        bootPhase = .loading
        bootProgress = 0

        let total = 5.0
        var done = 0.0
        func step() {
            done += 1
            bootProgress = min(1, done / total)
        }

        // First, so a maintenance window is known before we bother fetching a
        // catalog nobody can order from. ContentView reveals on maintenance
        // without waiting for the rest.
        await refreshMaintenance(using: MaintenanceAPI(client: api))
        step()

        // The one fetch Home cannot render truthfully without: with no routes
        // every price is nil and every service reads "Unavailable".
        guard await loadCatalog(using: CatalogAPI(client: api)) else {
            bootPhase = .failed
            return
        }
        step()

        // Must precede applyStartupSelection below, which is what picks the
        // country a first-run user lands on — the single decision this data
        // exists to improve. ~390 rows / ~25 KB against the catalog's 3.5 MB,
        // so this is one more round-trip's latency, not payload, on a chain
        // that already has six. It swallows its own failure, so a slow or dead
        // response costs the ranking and nothing else.
        await loadCountryRanks(using: CatalogAPI(client: api))

        await refreshWallet(using: WalletAPI(client: api));   step()
        await refreshProfile(using: ProfileAPI(client: api)); step()
        await loadOrders(using: OrdersAPI(client: api));      step()

        // Both must run before the reveal — they decide WHICH screen and which
        // service/country the user lands on.
        resumeInFlightOrder()
        applyStartupSelection()
        bootPhase = .ready

        // Behind the reveal: a banner is additive, and holding a correct Home
        // screen behind one more round-trip to fetch it would be the exact
        // trade `coldStart` exists to avoid. Runs BEFORE the eSIM loads because
        // `esimPaused` decides what the eSIM tab says when the catalog is empty.
        await refreshAppStatus(using: AppStatusAPI(client: api))
        await loadEsimCatalog(using: EsimPlansAPI(client: api))
        await loadEsimOrders(using: EsimOrdersAPI(client: api))
        // Behind the reveal like the eSIM loads: history is not needed to render
        // a correct Home screen. It WAS missing entirely — loadEmailOrders
        // existed and had no caller, so email activations never appeared in
        // history at all.
        await loadEmailOrders(using: EmailAPI(client: api))

        // Also behind the reveal, and last: attribution is a MEASUREMENT, and
        // no measurement may lengthen the boot critical path. It is also the
        // only thing here that can tell us which Search Ads campaign produced
        // a paying user — the app spends on ASA daily and, until this landed,
        // installs and purchases were never joined at all.
        await submitAttributionIfNeeded(api: api)
    }

    /// Hand Apple's AdServices attribution token to `record-attribution`, once
    /// per install.
    ///
    /// Three properties, all deliberate:
    /// - **It can never throw out or block anything.** Every failure path is
    ///   swallowed. A campaign we cannot attribute is a reporting gap; a cold
    ///   launch that fails because of one is an outage.
    /// - **The pref is set only on SUCCESS**, so a launch with no network
    ///   retries on the next one. The token stays valid for the install.
    /// - **The simulator has no token** — `attributionToken()` throws there —
    ///   which is ordinary, not an error worth surfacing.
    func submitAttributionIfNeeded(api: APIClient) async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: PrefKey.attributionSubmitted) else { return }

        let token: String
        do {
            token = try AAAttribution.attributionToken()
        } catch {
            // Simulator, or a device that has no token to give. Not retried
            // within this launch and not reported: there is nothing to send.
            return
        }
        guard !token.isEmpty else { return }

        do {
            try await AttributionAPI(client: api).submit(token: token)
            defaults.set(true, forKey: PrefKey.attributionSubmitted)
        } catch {
            // Left unset on purpose — the next cold launch tries again.
            print("attribution submit failed: \(error)")
        }
    }

    /// Leave a failed cold start without data rather than trapping the user.
    /// Orders, credits and account still work; the catalog-backed surfaces will
    /// say "Unavailable", which is at least honest once we have told them the
    /// server was unreachable.
    func continueWithoutCatalog() { bootPhase = .ready }

    /// Returns the credit cost for (service, country), or nil when we don't
    /// have a confirmed retail price. nil means the pair is unavailable to
    /// book — UI should show "Unavailable" and disable the Get number button.
    /// We deliberately do NOT fall back to service.cost (a seed default), as
    /// undercharging vs the live SMSPVA price would burn margin per order.
    func cost(for service: Service, country: Country) -> Int? {
        guard let route = routeIndex["\(service.id)|\(country.id)"],
              route.status == "active",
              let credits = route.retailCredits else {
            return nil
        }
        return credits
    }

    /// Credit cost of the Real-SIM (premium) tier for (service, country), or
    /// nil when the route has no pinned real carrier — the checkout hides the
    /// tier choice entirely in that case. Never falls back to the standard
    /// price: a nil here means "not sellable as premium", same contract as
    /// cost(for:country:).
    /// This service refuses VoIP numbers here, so the Standard tier must not be
    /// offered. Mirrors `premiumCost` deliberately: both read the SAME route,
    /// so the chips and the tier rules can never disagree about which route
    /// they describe.
    func realSimOnly(for service: Service, country: Country) -> Bool {
        guard let route = routeIndex["\(service.id)|\(country.id)"],
              route.status == "active" else { return false }
        // Only meaningful when there is a Real SIM tier to fall back on —
        // otherwise it would hide Standard and leave nothing selectable.
        return route.realSimOnly == true && route.premiumCredits != nil
    }

    func premiumCost(for service: Service, country: Country) -> Int? {
        guard let route = routeIndex["\(service.id)|\(country.id)"],
              route.status == "active",
              route.retailCredits != nil else {
            return nil
        }
        return route.premiumCredits
    }

    /// Provider self-reported delivery success (0-100) for (service, country),
    /// or nil when we have no figure. Separate from `cost` on purpose — a
    /// missing rate hides the badge, it does NOT make the route unavailable.
    func successRate(for service: Service, country: Country) -> Int? {
        guard let route = routeIndex["\(service.id)|\(country.id)"],
              route.status == "active" else { return nil }
        return route.successRate
    }

    /// Rate plus provenance. `isMeasured` is true only when the backend marked
    /// the rate `measured` — the only case the UI may state as fact; anything
    /// else is a seeded estimate and must read as one.
    /// `sample` is how many conclusive orders back a MEASURED rate. It matters
    /// because the demotion gate is asymmetric (migration 20260725120000): a
    /// route with zero codes becomes `measured 0%` at just 2 attempts, so
    /// "0% delivered" is now routinely a 2-sample claim. True, but it should
    /// not wear the confidence of a 40-sample one — SuccessBadge shows the
    /// sample instead of a bare percentage below `thinSample`.
    func rateInfo(for service: Service, country: Country) -> (rate: Int, isMeasured: Bool, sample: Int?)? {
        guard let route = routeIndex["\(service.id)|\(country.id)"],
              route.status == "active", let rate = route.successRate else { return nil }
        return (rate, route.rateSource == "measured", route.successSample)
    }

    /// The honest delivery record for a route.
    ///
    /// Unlike `rateInfo` this NEVER returns nil — every route gets a label,
    /// which is the whole point. An absent badge was being read as reassurance
    /// on the 17,471-of-17,804 active routes we have never measured, and
    /// "no badge" is indistinguishable from "fine" at a glance.
    ///
    /// A seeded rate maps to `.notTested` on purpose: a provider's own grade is
    /// not a test we ran. See `DeliveryRecord`.
    func deliveryRecord(for service: Service, country: Country) -> DeliveryRecord {
        guard let route = routeIndex["\(service.id)|\(country.id)"],
              route.rateSource == "measured",
              let codes = route.successCodes,
              let attempts = route.successSample,
              attempts > 0
        else { return .notTested }
        return .measured(codes: codes, attempts: attempts)
    }

    /// The provider's published 30-day delivery rate for the pool this route
    /// buys from, or nil when they publish none for it.
    ///
    /// Distinct from `deliveryRecord`, which is OUR measurement of orders we
    /// placed. Both can appear on the same row and they must stay visually and
    /// verbally separate — collapsing them is what forced the seeded vendor
    /// grade to be demoted to `.notTested`.
    func poolRate(for service: Service, country: Country) -> Int? {
        guard let route = routeIndex["\(service.id)|\(country.id)"],
              route.status == "active" else { return nil }
        return route.poolRatePct
    }

    /// How this COUNTRY has delivered across every service, over 30 days, on
    /// the provider we currently use — or nil when we've never had a conclusive
    /// order there. Server-computed by `refresh_country_delivery`.
    ///
    /// Used ONLY to order routes we have no route-level record for — never
    /// rendered. It is not a claim about the specific route the user is
    /// looking at, so it must not reach the badge, which says exactly what was
    /// measured for that pair and nothing else.
    ///
    /// Deliberately NOT rolled up client-side from `routes.success_*`, which
    /// was the first attempt: that data carries no provider scoping the client
    /// can apply, so the roll-up silently mixed in smspool/virtualsms numbers
    /// we no longer sell (all 5 of Indonesia's failures, 5 of South Africa's 8)
    /// and it saw only 12 of the 25 countries we have order history for.
    func countryRatio(_ country: Country) -> Double? { country.deliveryRatio }

    /// (tier, pool rate, country tier, country record, price) — see `routeKey`.
    typealias RouteKey = (Int, Int, Int, Int, Int)

    /// Sort key for a route with no record of its own: country evidence first,
    /// price only as the final tie-break.
    ///
    /// Ordering untested routes by price was picking the cheapest country in
    /// the catalog every time, which is Colombia — and hiding Colombia does not
    /// fix it, because the next-cheapest country simply inherits the traffic
    /// (measured: il/bd/vn/ph, all never tested; cl 2/13, za 0/8, id 0/5).
    /// The floor regenerates, so the rule has to change, not the inventory.
    private func untestedKey(_ country: Country, price: Int) -> (Int, Int, Int) {
        guard let ratio = countryRatio(country) else {
            return (1, 0, price)                 // country unknown too
        }
        return ratio > 0 ? (0, -Int(ratio * 100), price)   // country delivers
                         : (2, 0, price)                    // country measured 0
    }

    /// As `untestedKey`, but ranked FIRST by the provider's published delivery
    /// rate for the exact pool this route buys from. Used wherever we are
    /// choosing between routes we have never sold.
    ///
    /// Ordering is (pool tier, pool rate, country tier, country record, price).
    ///
    /// Measured 2026-07-31, and this is the whole reason a vendor rate sits
    /// ahead of price: for `google` the cheapest bookable route was Kenya at 1
    /// credit, which has delivered 0 of 9. Cameroon costs 2 credits and the
    /// provider reports 59.3%. Price picked Kenya every time.
    ///
    /// Two things changed on 2026-08-03, both of which were steering wrong:
    ///
    ///  1. It read `service_country_ranks` (1,043 rows) while the row in front
    ///     of the user renders `routes.pool_rate_pct` (2,715 rows). So 1,672
    ///     active routes showed a real percentage that the ranker scored as 0 —
    ///     the list and the default pick were reading two different tables.
    ///     Where both exist they agree exactly, so this is a pure coverage win.
    ///
    ///  2. The COUNTRY tier came first, and country evidence is a cross-service
    ///     roll-up over a handful of orders. The UK (3 attempts, 0 codes) and
    ///     the US (4, 0) therefore sorted BELOW countries we know nothing about,
    ///     while holding some of the best-rated pools in the catalog. A
    ///     pair-specific rate outranks a country-wide one, so the country tier
    ///     now only breaks ties between equally-rated pools.
    ///
    /// A published 0% sorts LAST, below unrated. That deliberately differs from
    /// CountrySheet's "Best success" sort, which lists 0% above unrated because
    /// the owner asked for measured values in descending order. The difference
    /// is between a list the user scrolls and a choice we make FOR them: 1,184
    /// of the 2,715 rated routes publish exactly 0, and defaulting someone onto
    /// inventory the vendor itself reports as dead is the same error as the old
    /// cheapest-first rule. "No information" beats "reported dead".
    private func rankedUntestedKey(_ service: Service, _ country: Country,
                                   price: Int) -> (Int, Int, Int, Int, Int) {
        let base = untestedKey(country, price: price)
        let poolTier: Int, poolScore: Int
        switch poolRate(for: service, country: country) {
        case .some(let pct) where pct > 0: (poolTier, poolScore) = (0, -pct)
        case .some:                        (poolTier, poolScore) = (2, 0)  // published 0%
        case .none:                        (poolTier, poolScore) = (1, 0)  // unrated
        }
        return (poolTier, poolScore, base.0, base.1, price)
    }

    /// The provider's rate for one pair, or nil when it is not in their top 10.
    func rank(for service: Service, country: Country) -> CountryRank? {
        rankIndex["\(service.id)|\(country.id)"]
    }

    /// Best provider-ranked country for a RETRY: highest reported rate,
    /// bookable, affordable on the current balance, and never the country that
    /// just failed.
    ///
    /// Used only when we have no measurement of our own — our evidence always
    /// wins, because it describes orders we actually placed. Excluding
    /// `failedCountry` is the point: a retry that hands back the same pool the
    /// user just lost an order on is the dead end this whole screen exists to
    /// replace, and the backend's fresh-number guarantee only changes the
    /// number, not the country.
    func bestRankedCountry(for service: Service,
                           excluding failed: Country?) -> (country: Country, rank: CountryRank, price: Int)? {
        topRankedCountries(for: service)
            .filter { $0.country.id != failed?.id && $0.price <= balance }
            .max { a, b in a.rank.vendorPercent < b.rank.vendorPercent }
            .map { (country: $0.country, rank: $0.rank, price: $0.price) }
    }

    /// A service's ranked countries, best first, restricted to ones we can
    /// actually sell. A row the user cannot buy is worse than no row — it
    /// advertises inventory and then dead-ends.
    func topRankedCountries(for service: Service) -> [(rank: CountryRank, country: Country, price: Int)] {
        (ranksByService[service.id] ?? []).compactMap { r in
            guard let c = countries.first(where: { $0.id == r.countryId }),
                  let p = cost(for: service, country: c) else { return nil }
            return (r, c, p)
        }
    }

    /// Fetch the provider's rankings. SWALLOWS its own failure on purpose: this
    /// is a steering enhancement, and Home, checkout and every price render
    /// correctly without it. Letting it fail the launch chain would trade a
    /// working app for a nicer sort.
    @MainActor
    func loadCountryRanks(using api: CatalogAPI) async {
        guard let fetched = try? await api.fetchCountryRanks() else { return }
        countryRanks = fetched
        var idx: [String: CountryRank] = [:]
        idx.reserveCapacity(fetched.count)
        var byService: [String: [CountryRank]] = [:]
        for r in fetched {
            idx["\(r.serviceId)|\(r.countryId)"] = r
            byService[r.serviceId, default: []].append(r)
        }
        // The server already orders by rank, but sort defensively: the display
        // promises "best first" and must not depend on a query's ORDER BY
        // surviving a future edit.
        for (k, v) in byService {
            byService[k] = v.sorted { $0.vendorRank < $1.vendorRank }
        }
        rankIndex = idx
        ranksByService = byService
    }

    /// The country to land on when the user picks `service`. Ranks by
    /// evidence, but NEVER silently swaps a working selection:
    ///  1. A country we've measured delivering wins — real steering.
    ///  2. Otherwise KEEP `current` when the service is bookable there and not
    ///     measured-failing. The sheet just showed the user a price for that
    ///     country; the buy button must say the same number.
    ///  3. Otherwise the best untested bookable country, ranked by that
    ///     COUNTRY's measured record and only then by price — see
    ///     `untestedKey`. Both previous rules were price rules: "priciest"
    ///     (a SMSPool-era pool heuristic) quoted 40cr Thailand right after the
    ///     list showed 3cr Netherlands, and "cheapest" that replaced it walks
    ///     straight into Colombia on every service it can reach.
    ///  4. Everything left is measured-failing; give back the cheapest.
    func bestCountry(for service: Service, keeping current: Country? = nil) -> Country? {
        let bookable = countries.filter { cost(for: service, country: $0) != nil }
        guard !bookable.isEmpty else { return nil }

        let priceOf: (Country) -> Int = { self.cost(for: service, country: $0) ?? .max }

        // 1) Anything we have actually SEEN deliver — measured only.
        //
        // This used to accept any `successRate > 0`, which includes SMSPVA's
        // SEEDED per-country grade. So a route we had never sold, carrying a
        // vendor number about the vendor's own inventory, was ranked as
        // "proven" and beat every genuinely untested country. 323 routes carry
        // a seeded rate against 10 measured ones, so the steering was almost
        // entirely driven by the one signal we had already decided not to
        // trust anywhere else in the app.
        let proven = bookable.compactMap { c -> (Country, Double, Int)? in
            guard let r = deliveryRecord(for: service, country: c).ratio, r > 0 else { return nil }
            return (c, r, priceOf(c))
        }
        if let best = proven.max(by: { a, b in
            a.1 != b.1 ? a.1 < b.1 : a.2 > b.2      // best ratio; ties -> cheaper
        }) { return best.0 }

        // 2) Nothing proven — stay where the user already is, unless we have
        //    measured that route failing. Untested is not a reason to move: the
        //    sheet just showed the user a price for this country.
        if let current, cost(for: service, country: current) != nil,
           !deliveryRecord(for: service, country: current).isMeasuredZero {
            return current
        }

        // 3) Best untested — by the COUNTRY's record, price last. See
        //    `untestedKey`: "cheapest" here was how a new user arrived at
        //    Colombia, the cheapest of all 69 countries.
        let untested = bookable.filter { deliveryRecord(for: service, country: $0) == .notTested }
        if let pick = untested.min(by: {
            rankedUntestedKey(service, $0, price: priceOf($0))
                < rankedUntestedKey(service, $1, price: priceOf($1))
        }) { return pick }

        // 4) Everything left is measured-failing; give back the cheapest.
        return bookable.min(by: { priceOf($0) < priceOf($1) })
    }

    /// Where tapping `service` in the service picker actually lands, and what
    /// it costs there. The single shared definition used by BOTH the picker row
    /// and the tap handler.
    ///
    /// The service picker fixes the COUNTRY and varies the service — the mirror
    /// of CountrySheet — so a service with no route in the selected country
    /// rendered a bare "Unavailable" with nothing naming that country. Measured
    /// 2026-07-30: all 265 visible services are bookable in at least one
    /// country, so the word was wrong every single time it appeared. It can
    /// only ever mean "not in this country", and it read as "not at all" for a
    /// median of 79 services per country (Turkey: 165 of 265, i.e. 62% of the
    /// catalog looked dead).
    ///
    /// Worse, the row was dimmed to look disabled but stayed tappable, and the
    /// tap WORKED — the handler already relocated to `bestCountry`. So the
    /// label was steering users away from taps that would have succeeded.
    ///
    /// Returning the destination lets the row state it up front, which turns
    /// that relocation from silent into predicted. Both callers MUST go through
    /// here: a row promising a different country than the tap delivers would be
    /// a worse lie than the one it replaces.
    ///
    /// nil means bookable NOWHERE — the only case in which "Unavailable",
    /// unqualified, is actually true.
    func pickDestination(for service: Service) -> (country: Country, credits: Int)? {
        guard let c = bestCountry(for: service, keeping: configuringCountry),
              let credits = cost(for: service, country: c) else { return nil }
        return (c, credits)
    }

    /// Country picker shows every country in the catalog. A specific
    /// (service, country) pair may still be rejected at order time if
    /// SMSPVA is out of numbers — handled by create-order.
    var availableCountries: [Country] { countries }

    /// Credit shortfall for whatever the user is currently configuring (the
    /// checkout draft if present, else Home's selection). 0 when it's already
    /// affordable or the pair is unavailable. Drives CreditsSheet's pack
    /// preselection so the user is offered the smallest pack that unblocks them.
    var creditsShortfall: Int {
        // Switch on the DECLARED intent, never infer it from which draft happens
        // to be non-nil. See `PurchaseIntent` for the bug that shape caused.
        //
        // Still not gated on `flow`, and that is deliberate: the credits pill in
        // EsimStoreScreen opens the ROOT sheet with flow == nil. The intent is
        // what carries the product across that boundary, and unlike the old
        // draft-sniffing it is cleared when the flow ends.
        switch intent {
        case .esim:
            guard let c = checkoutEsimPlan?.retailCredits else { return 0 }
            return max(0, c - balance)
        case .email:
            // Free domains can never leave you short, so they contribute 0
            // rather than a spurious "buy credits" nudge.
            guard let c = emailDomain?.credits, c > 0 else { return 0 }
            return max(0, c - balance)
        case .line:
            // RENTING the line is paid entirely through a StoreKit subscription
            // and never spends credits, so there is no shortfall it could
            // create. Returning 0 rather than falling through is what stops it
            // answering with whatever SMS route was last configured — the exact
            // failure this enum exists to prevent.
            return 0
        case .call:
            // ⚠️ An INTERNATIONAL call is the one thing on this line that does
            // spend credits: the minute allowance covers NANP only, because a
            // bucket denominated in minutes cannot price a $3.62/min
            // destination. The amount is DECLARED by the dialer, never derived
            // here — deriving it would mean this property re-matching a prefix
            // against a rate card, and a second definition of the price is a
            // second thing to drift.
            guard let need = callCreditsNeeded else { return 0 }
            return max(0, need - balance)
        case .sms:
            break
        }
        let svc = configuringService
        let cty = configuringCountry
        // Respect the tier being configured: a premium pick must preselect a
        // pack that covers the premium price, not the standard one.
        // effectiveCheckoutPremium, not the raw flag: if a catalog refresh drops
        // the route's premium price under an open checkout, premiumCost returns
        // nil, the guard below returns 0, and the sheet offers no hint while the
        // checkout CTA still says "Need N more".
        let selected = effectiveCheckoutPremium
            ? premiumCost(for: svc, country: cty)
            : cost(for: svc, country: cty)
        guard let c = selected else { return 0 }
        return max(0, c - balance)
    }

    /// Point the Home hero at something the user can actually act on, once per
    /// launch, after catalog + wallet + orders have loaded:
    ///  • returning user → mirror their most recent order as "Last used";
    ///  • brand-new user → default to an affordable, recognizable service the
    ///    welcome credit can buy, instead of WhatsApp/US (which costs far more
    ///    than the 1-credit grant and left every first-run CTA greyed out).
    func applyStartupSelection() {
        guard !didSeedStartupSelection else { return }
        didSeedStartupSelection = true

        if let recent = orders.first {
            lastService = services.first { $0.id == recent.service.id } ?? recent.service
            lastCountry = countries.first { $0.id == recent.country.id } ?? recent.country
            needsServiceChoice = false
            return
        }
        // 🔴 A first-run user gets a suggestion, NOT a purchase.
        //
        // The pair below is still computed, because the hero needs something
        // to price and the country ranking is genuinely useful once a service
        // IS chosen. What changed on 2026-08-08 is that it no longer counts as
        // the user's choice: `needsServiceChoice` keeps the Get-number button
        // hidden until they pick, so the first tap is a decision rather than a
        // transaction.
        //
        // Why: measured 2026-08-07, six deliveroo/us orders from four
        // brand-new users, every one on this exact default pair at exactly the
        // grant size, all issued a number, NONE producing a code — while a
        // deliberate order on the same route delivered in 86 seconds. Four of
        // the six were never even cancelled, just left to expire. They were
        // numbers nobody ever entered anywhere, because nobody had come for
        // that service. The same shape produced the olx/us cluster on 08-04
        // that was briefly investigated as sabotage.
        //
        // Better copy cannot fix it — `WaitingScreen` already says "Paste it
        // into <service>, then come back". The user understood; they simply
        // had no use for the number. So the fix has to be at SELECTION.
        if let (svc, cty) = affordableStarter() {
            lastService = svc
            lastCountry = cty
        }
        needsServiceChoice = true
    }

    /// A recognizable service + country pair the current balance can afford,
    /// ranked by the same evidence rule the rest of the app steers on.
    ///
    /// ⚠️ This does not merely choose "something affordable" — it chooses the
    /// ONE route the entire new-user cohort lands on, because
    /// `applyStartupSelection` points the Home hero at it and the hero is what
    /// they tap. Measured 2026-08-03/04: setting the signup grant to 1 credit
    /// sent **16 of 16 subsequent orders to olx**, from 9 different users, with
    /// zero olx orders before that minute — every one from a wallet holding
    /// exactly 1 credit.
    ///
    /// It used to return the FIRST entry in `preferred` with any affordable
    /// route, so array position picked the service and the route's actual
    /// quality was never compared across services. Grant size therefore
    /// silently selected the cohort's destination: 1 cr → olx/us (23%),
    /// 2–3 cr → deliveroo/Georgia (UNRATED), 5 cr → leboncoin/uk (52%). At the
    /// 3-credit grant that is an unrated pool while 618 routes are reachable
    /// and 58 of them publish above 60%.
    ///
    /// Worse, the list's own comment claimed it was "ordered by MEASURED
    /// delivery". That was true when written and is now false: the measurement
    /// was SMSPVA-era and describes a provider we no longer buy from. A frozen
    /// ranking is not a ranking.
    ///
    /// Every candidate is now scored with `routeKey`; curated order survives
    /// only as the final tie-break, where the evidence is genuinely silent.
    private func affordableStarter() -> (Service, Country)? {
        // Kept as the CANDIDATE SET, no longer as the ranking. These are
        // services a first-run user plausibly recognises, minus the ones that
        // measured worst: the original list led with telegram/instagram/google/
        // whatsapp/facebook, almost exactly the set measuring ~9% delivered
        // against ~52% for everything else.
        //
        // Meta and the messengers stay fully browsable; they're just not what a
        // brand-new user is pointed at.
        let preferred = ["leboncoin", "deliveroo", "glovo", "whatnot", "walmart",
                         "vinted", "wallapop", "subito", "olx", "uber",
                         "tiktok", "discord"]
        let shortlist = preferred.compactMap { id in services.first { $0.id == id } }

        // FIRST PASS — bounded by balance, so it can only return a route the
        // user is able to buy right now.
        if let pick = bestStarter(among: shortlist, affordableOnly: true) { return pick }
        if let pick = bestStarter(among: services, affordableOnly: true) { return pick }

        // SECOND PASS, ignoring balance entirely.
        //
        // Everything above is bounded by `price <= balance`, so at a ZERO
        // balance every service returns nil and we used to fall through to
        // `return nil` — which leaves the SEED default in place. That seed is
        // whatsapp/us, which is `hidden`, so `cost()` returns nil and a
        // brand-new user's very first screen renders its primary CTA as a
        // disabled **"Unavailable / Pick another country"**.
        //
        // Survivable while the signup grant was 3–5 credits and this path was
        // rare. The grant went to 0 on 2026-08-03 (`20260803070000`), so it is
        // now what EVERY new user sees — on a product whose activation is a
        // single-session event with a median signup→first-order of 123 seconds.
        //
        // An unaffordable but REAL route is strictly better: the CTA becomes a
        // priced "Buy credits / Need N more" that opens the credits sheet. That
        // is an honest description of the situation and a way out of it.
        // "Unavailable" is neither — it reads as "this product is broken".
        if let pick = bestStarter(among: shortlist, affordableOnly: false) { return pick }
        return bestStarter(among: services, affordableOnly: false)
    }

    /// Best (service, country) pair among `candidates`, scored by `routeKey`.
    ///
    /// The candidate list's own order is the LAST tie-break rather than the
    /// first, so a curated shortlist still expresses brand preference — but
    /// only where the evidence has nothing to say. Any earlier and list
    /// position outranks a measured pool rate, which is the bug this replaced.
    ///
    /// `affordableOnly` picks the country resolver: `bestAffordableCountry`
    /// can only return something within `balance` (nil otherwise, which is what
    /// lets an unaffordable service drop out of the running), while
    /// `bestCountry` ignores balance for the zero-balance second pass.
    private func bestStarter(among candidates: [Service],
                             affordableOnly: Bool) -> (Service, Country)? {
        var best: (pair: (Service, Country), key: (Int, Int, Int, Int, Int, Int))?
        for (position, svc) in candidates.enumerated() {
            guard let cty = affordableOnly ? bestAffordableCountry(for: svc)
                                           : bestCountry(for: svc),
                  let price = cost(for: svc, country: cty) else { continue }
            let k = routeKey(svc, cty, price: price)
            let key = (k.0, k.1, k.2, k.3, k.4, position)
            if best == nil || key < best!.key { best = ((svc, cty), key) }
        }
        return best?.pair
    }

    /// Affordable country for `service`, chosen by the same evidence-first rule
    /// as `bestCountry(for:)` rather than by lowest price.
    ///
    /// nil means "nothing here is within `balance`", which is what lets
    /// `affordableStarter` move on and try another service. Do NOT make this
    /// fall back to an unaffordable route — that search is the whole point of
    /// the first pass, and collapsing it would pin every user to the first
    /// preferred service regardless of what they can buy.
    private func bestAffordableCountry(for service: Service) -> Country? {
        guard let best = bestCountry(for: service),
              let c = cost(for: service, country: best), c <= balance
        else { return affordableFallbackCountry(for: service) }
        return best
    }

    /// Best country for `service` the current balance can actually reach.
    ///
    /// This used to return the outright CHEAPEST affordable route with no
    /// regard for evidence, and that fallback is the common path for a new
    /// user, because the evidence-first pick is usually unaffordable at the
    /// 3-credit signup grant. Measured 2026-07-28: it lands a brand-new user on
    /// **leboncoin/co — 2 cr, never tested, in a country measuring 17% delivery
    /// over 30 days** — while leboncoin/ch is 4-of-4 but costs 7.
    ///
    /// Cheapest is the one ranking rule guaranteed to surface the inventory
    /// nobody has yet been willing to pay for. Now tiers exactly like
    /// `bestCountry`: proven → untested-in-a-good-country → untested-unknown →
    /// untested-in-a-bad-country → measured-failing, cheapest within a tier,
    /// and still bounded by `balance` so it can only return something buyable.
    ///
    /// The country tier matters because at 3 credits the affordable set is
    /// almost entirely untested (1,606 routes, against **2** with a record),
    /// so route-level evidence has nothing to say and price used to decide by
    /// default. Country-level evidence at least distinguishes Bulgaria (0 of 7)
    /// from Switzerland (4 of 4).
    ///
    /// Still a mitigation, not a cure: landing new users on genuinely proven
    /// inventory is a pricing question (grant size vs route price), not a
    /// ranking one.
    private func affordableFallbackCountry(for service: Service) -> Country? {
        var best: (country: Country, key: RouteKey)?
        for c in countries {
            guard let price = cost(for: service, country: c), price <= balance else { continue }
            let key = routeKey(service, c, price: price)
            if best == nil || key < best!.key { best = (c, key) }
        }
        return best?.country
    }

    /// Lowest = best. How good one (service, country) route is as something to
    /// put in front of a user who has no history with it.
    ///
    /// Tiers: 0 proven-delivering · 1 untested with a rated pool · 2 untested
    /// and unrated · 3 untested where the pool publishes 0% · 4 measured
    /// failing. Tiers 1–3 come straight from `rankedUntestedKey`, offset by 1.
    ///
    /// Shared by `affordableFallbackCountry` (which COUNTRY to open a service
    /// in) and `affordableStarter` (which SERVICE to open at all), so the two
    /// cannot drift apart about what "better" means. It was previously inline
    /// in the first of those and had no second caller, which is exactly how the
    /// starter ended up picking by array position instead.
    private func routeKey(_ service: Service, _ country: Country,
                          price: Int) -> RouteKey {
        if let ratio = deliveryRecord(for: service, country: country).ratio {
            // Route-level zero is stronger evidence than country-level zero, so
            // it sorts BELOW an untested route in a bad country. Our OWN
            // measurement always outranks the provider's, so the vendor slot is
            // neutral here — these two branches are decided by orders we
            // actually placed.
            return ratio > 0 ? (0, 0, 0, -Int(ratio * 100), price)   // proven
                             : (4, 0, 0, 0, price)                   // proven-bad
        }
        // Untested: the provider's pool rate first, then the country's own
        // record, then price. Offset by 1 so a route with NO record can never
        // outrank one we have measured delivering.
        //
        // This is the branch that matters: at the 3-credit grant the affordable
        // set is almost entirely untested, so before this existed price decided
        // by default — which is how a new user reached google/ke (1 cr, 0 of 9)
        // instead of google/cm (2 cr, provider reports 59.3%).
        let k = rankedUntestedKey(service, country, price: price)
        return (k.0 + 1, k.1, k.2, k.3, k.4)
    }

    // ─────────── Catalog / profile / wallet bootstrap ───────────

    func refreshWallet(using api: WalletAPI) async {
        do { balance = try await api.currentWallet().balance }
        catch { /* keep current */ }
    }

    /// When the catalog was last successfully loaded.
    ///
    /// The routes payload is ~3 MB / 18.5k rows and took 4.2s measured against
    /// production, decoded on the main actor. It was refetched on EVERY
    /// foreground — so every app switch, share sheet and trip to Settings
    /// during an eSIM install cost 3 MB of the user's data plan and a visible
    /// hitch. Prices move hourly at most (sync-prices runs at :17), so a
    /// 10-minute floor loses nothing.
    @ObservationIgnored
    private var lastCatalogLoad: Date?

    /// Credits from a just-completed purchase. The app had NO purchase
    /// confirmation anywhere — no receipt, no toast, no "+N credits" — so a
    /// successful buy was visually identical to a failed one.
    var creditPurchaseBanner: Int?

    // The daily credit was REMOVED from the client on 2026-08-02. It had been
    // disabled server-side (migration 20260801150000, owner decision) and the
    // no-op daily_credit_status/claim_daily_credit RPCs stay in the DB only so
    // 1.6/1.7 builds keep working; this build simply never calls them.

    func refreshProfile(using api: ProfileAPI) async {
        profile = try? await api.currentProfile()
    }

    func refreshMaintenance(using api: MaintenanceAPI) async {
        if let m = try? await api.current() { maintenance = m }
    }

    /// `minInterval` skips the fetch when the catalog is already fresh enough.
    /// Cold launch passes 0 (always load); the foreground path passes 600.
    /// Returns whether we now hold a live catalog.
    ///
    /// This used to be `-> Void` with a bare `catch { /* keep current state */ }`,
    /// which meant an offline launch silently kept the 30-service `SeedData`
    /// stub and `routes = []` — rendering a complete Home screen on which every
    /// service read "Unavailable". Indistinguishable from "this product is
    /// broken". The caller needs to be able to tell the difference.
    @discardableResult
    func loadCatalog(using api: CatalogAPI, minInterval: TimeInterval = 0) async -> Bool {
        if minInterval > 0, let last = lastCatalogLoad,
           Date().timeIntervalSince(last) < minInterval {
            return true    // fresh enough — we already have one
        }
        do {
            let catalog = try await api.fetch()
            lastCatalogLoad = Date()
            services = catalog.services
            countries = catalog.countries
            routes = catalog.routes

            // Rebuild the lookup index — used by cost(for:country:).
            var idx: [String: Route] = [:]
            idx.reserveCapacity(catalog.routes.count)
            for r in catalog.routes {
                idx["\(r.serviceId)|\(r.countryId)"] = r
            }
            routeIndex = idx

            if let match = services.first(where: { $0.id == lastService.id }) {
                lastService = match
            } else if let first = services.first {
                lastService = first
            }
            if let match = countries.first(where: { $0.id == lastCountry.id }) {
                lastCountry = match
            } else if let first = countries.first {
                lastCountry = first
            }
            return true
        } catch {
            // Keep whatever we already have — a foreground refresh that fails
            // must not wipe a good catalog. The BOOL is what tells a cold start
            // it never got one.
            return false
        }
    }

    // ─────────── eSIM ───────────

    func loadEsimCatalog(using api: EsimPlansAPI) async {
        guard let plans = try? await api.fetch() else { return }
        esimPlans = plans
        var idx: [String: EsimPlan] = [:]
        for p in plans { idx[p.id] = p }
        esimPlanIndex = idx
        // Derived once per fetch — see the note on `esimCountries`.
        esimCountries = AppState.groupByCountry(plans)
        esimPlansByCountry = Dictionary(grouping: plans) { $0.countryCode ?? "??" }
            .mapValues { $0.sorted { ($0.retailCredits ?? 0) < ($1.retailCredits ?? 0) } }
        // Re-resolve any already-loaded orders against the fresh catalog.
        esimOrders = esimOrders.map { EsimOrder(server: $0.server, plan: idx[$0.server.planId ?? ""]) }
    }

    func loadEsimOrders(using api: EsimOrdersAPI) async {
        guard let rows = try? await api.list() else { return }
        esimOrders = rows.map { EsimOrder(server: $0, plan: esimPlanIndex[$0.planId ?? ""]) }
    }

    /// eSIM plans grouped by country (cheapest tier per country), for the store.
    ///
    /// **Stored, not computed.** It was a computed property that walked all
    /// **1,081** plans and rebuilt a dictionary — and because `AppState` is
    /// `@Observable`, that ran on every body evaluation of any view touching it:
    /// twice per `HomeScreen` redraw and once per `EsimStoreScreen` redraw, i.e.
    /// constantly while the map is being dragged. It also handed `EsimMapView` a
    /// freshly-allocated array each time, so SwiftUI saw new input and rebuilt
    /// every annotation. The catalog only changes when it is fetched, so it is
    /// derived exactly there.
    private(set) var esimCountries: [EsimCountryEntry] = []

    private static func groupByCountry(_ plans: [EsimPlan]) -> [EsimCountryEntry] {
        var byCode: [String: (name: String, minCr: Int, count: Int)] = [:]
        for p in plans {
            let code = p.countryCode ?? "??"
            // SKIP unpriced plans rather than folding in Int.max. `?? Int.max`
            // meant a country whose plans were all unpriced surfaced its minimum
            // verbatim as "from 9223372036854775807 cr". It also disagreed with
            // esimPlans(forCountry:), which uses `?? 0` for the same field — the
            // two functions took opposite views of a missing price.
            guard let cr = p.retailCredits else { continue }
            if let ex = byCode[code] {
                byCode[code] = (ex.name, min(cr, ex.minCr), ex.count + 1)
            } else {
                byCode[code] = (p.name, cr, 1)
            }
        }
        return byCode
            .map { EsimCountryEntry(code: $0.key, name: $0.value.name,
                                    fromCredits: $0.value.minCr, planCount: $0.value.count) }
            .sorted { $0.name < $1.name }
    }
    /// Plans for one country, cheapest first.
    ///
    /// Indexed for the same reason as `esimCountries`: this was a filter+sort
    /// over all 1,081 plans, and `EsimCountryPlansScreen` calls it about four
    /// times per body evaluation (`visible`, `durations`, `hiddenCount`, the
    /// disclosure count).
    private(set) var esimPlansByCountry: [String: [EsimPlan]] = [:]

    func esimPlans(forCountry code: String) -> [EsimPlan] {
        esimPlansByCountry[code] ?? []
    }

    // MARK: eSIM usage metrics
    //
    // Every figure here is arithmetic over rows the provider wrote — credits we
    // charged, megabytes `check-esim-usage` reported. Nothing is modelled or
    // estimated, which is why there is no "average speed" or "coverage
    // quality": we do not measure those, and the standing rule is that we show
    // nothing rather than a plausible-looking guess.

    /// eSIMs that can still change state — worth polling and worth showing first.
    var liveEsimOrders: [EsimOrder] { esimOrders.filter { $0.status.keepsPolling } }

    /// Total data consumed across every eSIM ever bought, in MB.
    var esimTotalUsedMb: Int { esimOrders.reduce(0) { $0 + $1.dataUsedMb } }

    /// Credits spent on eSIMs. Refunded orders are excluded — the money came
    /// back, so counting it as spend would overstate what the product cost.
    var esimCreditsSpent: Int {
        esimOrders.filter { $0.status != .refunded }.reduce(0) { $0 + $1.server.costCredits }
    }

    /// Distinct countries the user has held an eSIM for.
    var esimCountriesVisited: Int {
        Set(esimOrders.compactMap { $0.plan?.countryCode }).count
    }

    /// Soonest expiry among live eSIMs, for the "expires in N days" line.
    var esimNextExpiry: Date? {
        liveEsimOrders.compactMap(\.expiresAt).min()
    }

    // ─────────── Temporary email ───────────

    /// Services that can offer an email address at all.
    ///
    /// The provider REQUIRES a target site, which we take from `service.domain`
    /// — and 11 of 265 visible services have none. Filtering here is the
    /// difference between an absent row and a tap that fails at checkout with
    /// `email_unsupported_service`.
    var emailCapableServices: [Service] {
        services.filter { !($0.domain ?? "").isEmpty }
    }

    var emailSupported: Bool { !(configuringService.domain ?? "").isEmpty }

    /// Refresh the live domain list for whatever service is selected.
    ///
    /// Always refetched, never cached: stock is per (service, domain) and
    /// genuinely moves — hotmail.com measured 1,028 for google.com and 2 for
    /// discord.com in one sweep. A stale "available" is a promise we break at
    /// the moment the user taps buy.
    @MainActor
    func loadEmailDomains(using api: EmailAPI) async {
        let svc = configuringService
        guard !(svc.domain ?? "").isEmpty else {
            emailDomains = []; emailDomain = nil; return
        }
        isLoadingEmailDomains = true
        defer { isLoadingEmailDomains = false }
        do {
            let res = try await api.domains(serviceId: svc.id)
            emailDomains = res.domains
            // Keep the selection only if it is still buyable; otherwise fall to
            // the first in-stock option so the CTA is never armed on a dead one.
            if let cur = emailDomain,
               let same = res.domains.first(where: { $0.domain == cur.domain }),
               same.inStock {
                emailDomain = same
            } else {
                emailDomain = res.domains.first(where: { $0.inStock })
            }
        } catch {
            emailDomains = []
            emailDomain = nil
            lastError = (error as? APIError)?.userMessage
        }
    }

    @MainActor
    func loadEmailOrders(using api: EmailAPI) async {
        // Screenshot frames seed this collection directly. The read below is
        // RLS-filtered and would succeed with an EMPTY list, silently wiping
        // the sample — which is how the thread frame came back black.
        if ScreenshotMode.isActive { return }
        do { emailOrders = try await api.list() } catch { /* keep what we have */ }
    }

    // MARK: - Rented second number

    /// Refresh the caller's line. Swallows its own failure: the Number tab
    /// renders the store when `line == nil`, and blanking a live line because
    /// one request timed out would tell a paying subscriber they have no
    /// number. Keeping the previous value is strictly better.
    @MainActor
    /// The international rate card.
    ///
    /// Failure is deliberately silent and non-destructive: an empty list means
    /// the dialer shows no price and refuses international numbers, which is
    /// the safe direction. Quoting a stale price would be worse than quoting
    /// none, and the SERVER re-quotes authoritatively at call time regardless —
    /// this exists so the user sees the cost before they dial, not so the
    /// client can decide it.
    func loadVoiceRates(using api: LineAPI) async {
        guard let fresh = try? await api.voiceRates() else { return }
        voiceRates = fresh
    }

    func loadLine(using api: LineAPI) async {
        // Screenshot frames seed this collection directly. The read below is
        // RLS-filtered and would succeed with an EMPTY list, silently wiping
        // the sample — which is how the thread frame came back black.
        if ScreenshotMode.isActive { return }
        guard let fresh = try? await api.fetchAll() else { return }
        lines = fresh
        // Drop a selection whose line is gone — released, or refunded away —
        // rather than leaving the tab pointed at a number that no longer
        // exists, which resolves to nil and renders the store over the top of
        // the user's other, perfectly live numbers.
        if let id = selectedLineId, !fresh.contains(where: { $0.id == id }) {
            selectedLineId = nil
        }
    }

    /// Threads belonging to the line on screen.
    ///
    /// 🔴 Filtered CLIENT-side because `line_threads` is fetched for the whole
    /// user: with two numbers the list silently mixed both, so a conversation
    /// gave no clue which of your numbers it was on — and replying sends from
    /// whichever line the server resolves, which is not necessarily this one.
    var threadsForSelectedLine: [LineThread] {
        guard let id = line?.id else { return [] }
        return lineThreads.filter { $0.lineId == id }
    }

    /// Calls belonging to the line on screen. Same reasoning as above.
    var callsForSelectedLine: [LineCall] {
        guard let id = line?.id else { return [] }
        return lineCalls.filter { $0.lineId == id }
    }

    /// Quote live availability for a city.
    ///
    /// `city == nil` asks the server for its default, which is also how the
    /// city LIST is discovered — the server owns which area codes it will try,
    /// so a client-side list would offer cities we can no longer fill. The
    /// error paths carry that list too, which is why they are decoded rather
    /// than dropped: "no numbers in Toronto" has to be able to offer Montreal.
    @MainActor
    func loadLineNumbers(using api: LineAPI, city: String? = nil) async {
        isLoadingLineNumbers = true
        defer { isLoadingLineNumbers = false }
        do {
            let res = try await api.availability(city: city ?? lineCity)
            if !res.cities.isEmpty { lineCities = res.cities }
            lineCity = res.city
            lineOffers = res.numbers
            // Preselect the first so the confirm step always has something, but
            // the user can pick any of them.
            lineOffer = res.first
            lineUnavailableReason = res.numbers.isEmpty ? .noStock : nil
            // A fresh search invalidates any hold on the PREVIOUS number.
            // Leaving it would let the card show one number and the countdown
            // describe another.
            lineReservation = nil
        } catch {
            lineOffers = []
            lineOffer = nil
            lineReservation = nil
            lineUnavailableReason = Self.lineReason(from: error)
            // Recover the city list even from a refusal, so a paused or dry
            // store can still offer somewhere else to look.
            if let list = Self.lineCities(from: error), !list.isEmpty {
                lineCities = list
            }
        }
    }

    /// Conversation list. Swallows its own failure — an empty inbox and a
    /// failed fetch look identical on screen, and blanking a thread list the
    /// user was reading is the worse of the two.
    @MainActor
    func loadLineThreads(using api: LineAPI) async {
        // Screenshot frames seed this collection directly. The read below is
        // RLS-filtered and would succeed with an EMPTY list, silently wiping
        // the sample — which is how the thread frame came back black.
        if ScreenshotMode.isActive { return }
        if let fresh = try? await api.threads() { lineThreads = fresh }
    }

    @MainActor
    func loadLineCalls(using api: LineAPI) async {
        // Screenshot frames seed this collection directly. The read below is
        // RLS-filtered and would succeed with an EMPTY list, silently wiping
        // the sample — which is how the thread frame came back black.
        if ScreenshotMode.isActive { return }
        if let fresh = try? await api.calls() { lineCalls = fresh }
    }

    /// Unread across every conversation, for the tab-bar dot.
    var lineUnreadCount: Int {
        lineThreads.reduce(0) { $0 + $1.unreadCount }
    }

    /// Messages for one conversation, newest-last for display.
    ///
    /// The server returns newest-FIRST so the row limit keeps recent messages;
    /// ordering ascending with a limit would page in the oldest and render a
    /// thread that looks empty.
    @MainActor
    func loadLineMessages(using api: LineAPI, threadId: String) async {
        // Screenshot frames seed this collection directly. The read below is
        // RLS-filtered and would succeed with an EMPTY list, silently wiping
        // the sample — which is how the thread frame came back black.
        if ScreenshotMode.isActive { return }
        guard let fresh = try? await api.messages(threadId: threadId) else { return }
        lineMessages[threadId] = fresh.reversed()
    }

    /// Send, then reconcile against what the server actually recorded.
    ///
    /// Deliberately NOT optimistic. A send can be refused for two reasons the
    /// client cannot predict — the allowance is counted in SEGMENTS decided
    /// server-side, and the line may have lapsed since the view loaded — so
    /// painting the bubble first would show a message that then has to be
    /// taken away. The composer is fast enough without it.
    @MainActor
    func sendLineMessage(using api: LineAPI, to: String, text: String) async -> Bool {
        do {
            // 🔴 THE THREAD'S OWN LINE, not the one the tab happens to be
            // showing. A conversation belongs to the number it started on, and
            // a reply has to leave from that number or the far end sees a text
            // from a stranger — with our other number's allowance spent on it.
            //
            // The two differ in an ordinary flow: tapping a message push opens
            // the thread directly (`ThreadScreen` reads the UNFILTERED thread
            // list, deliberately, so a push always resolves), while
            // `selectedLineId` still points wherever the user last was.
            // Falling back to the visible line only covers a brand-new
            // conversation, which has no thread yet.
            let threadLineId = openThreadId
                .flatMap { id in lineThreads.first { $0.id == id } }?.lineId
            let res = try await api.send(to: to, text: text,
                                         lineId: threadLineId ?? line?.id)
            guard res.ok else { return false }
            if let tid = res.threadId {
                openThreadId = tid
                await loadLineMessages(using: api, threadId: tid)
            }
            await loadLineThreads(using: api)
            // The allowance moved, and the meter is on screen above the
            // composer — refreshing the line is what keeps it honest.
            await loadLine(using: api)
            return true
        } catch let err as APIError {
            lastError = err.userMessage
            return false
        } catch {
            lastError = String(localized: "Couldn't send that message. Please try again.")
            return false
        }
    }

    @MainActor
    func setThreadBlocked(using api: LineAPI, threadId: String, blocked: Bool) async {
        do {
            try await api.threadAction(threadId: threadId, action: blocked ? "block" : "unblock")
            await loadLineThreads(using: api)
        } catch let err as APIError {
            lastError = err.userMessage
        } catch { /* the list refresh below is cosmetic */ }
    }

    @MainActor
    func reportThread(using api: LineAPI, threadId: String) async {
        try? await api.threadAction(threadId: threadId, action: "report")
    }

    /// Clears the unread badge. Swallows failure: a badge that lingers is a
    /// cosmetic annoyance, and surfacing an error banner for it would be worse
    /// than the problem.
    @MainActor
    func markThreadRead(using api: LineAPI, threadId: String) async {
        try? await api.threadAction(threadId: threadId, action: "read")
        if let i = lineThreads.firstIndex(where: { $0.id == threadId }),
           lineThreads[i].unreadCount > 0 {
            let t = lineThreads[i]
            lineThreads[i] = LineThread(
                id: t.id, lineId: t.lineId, peerE164: t.peerE164,
                lastMessageAt: t.lastMessageAt, lastPreview: t.lastPreview,
                unreadCount: 0, blocked: t.blocked, createdAt: t.createdAt)
        }
    }

    /// Clear everything the Number tab owns. Called on LEAVING the tab, because
    /// the reservation and the quote are read at `flow == nil` and so cannot be
    /// cleared by `flow.didSet` — see the note there.
    @MainActor
    func clearLineDraft() {
        lineOffers = []
        lineOffer = nil
        lineReservation = nil
        lineUnavailableReason = nil
        lineCity = nil
        // The composed call's price goes with the draft. Leaving it set would
        // let `creditsShortfall` keep sizing packs for a call that is no longer
        // on screen — the same shape as the stale `checkoutEsimPlan` and the
        // stale `emailDomain` before it.
        callCreditsNeeded = nil
        callDestinationLabel = nil
    }

    /// Map a refusal onto the one thing we actually know. `lines_paused` is a
    /// statement; everything else is not, and must not be dressed up as one —
    /// an empty result and a failed fetch look identical from here.
    private static func lineReason(from error: Error) -> LineUnavailableReason {
        guard case let APIError.http(_, body) = error,
              let code = errorCode(in: body) else { return .unknown }
        switch code {
        case "lines_paused":         return .paused
        case "no_numbers_available": return .noStock
        case "provider_unreachable": return .unknown
        default:                     return .unknown
        }
    }

    private static func lineCities(from error: Error) -> [LineCity]? {
        guard case let APIError.http(_, body) = error,
              let data = body?.data(using: .utf8) else { return nil }
        struct Envelope: Decodable { let cities: [LineCity]? }
        return (try? JSONDecoder.relay.decode(Envelope.self, from: data))?.cities
    }

    private static func errorCode(in body: String?) -> String? {
        guard let data = body?.data(using: .utf8) else { return nil }
        struct Envelope: Decodable { let error: String? }
        return (try? JSONDecoder.relay.decode(Envelope.self, from: data))?.error
    }

    /// Buy the selected address. Free domains move no credits, so the balance
    /// refresh afterwards is still correct — it just does not change.
    @MainActor
    func confirmGetEmail(using api: EmailAPI, wallet: WalletAPI) async {
        guard !isBuyingEmail, let dom = emailDomain, dom.inStock else { return }
        let svc = configuringService
        isBuyingEmail = true
        defer { isBuyingEmail = false }
        do {
            let order = try await api.create(serviceId: svc.id, domain: dom.domain)
            emailOrders.insert(order, at: 0)
            activeEmailOrder = order
            intent = .email
            flow = .emailWaiting
            await refreshWallet(using: wallet)
        } catch {
            lastError = (error as? APIError)?.userMessage
                ?? String(localized: "Couldn't get an address. Please try again.")
        }
    }

    /// Poll one activation. `hasCode` — not `status` — decides we are done, the
    /// same rule the SMS side had to learn.
    @MainActor
    func refreshEmailOrder(using api: EmailAPI) async {
        guard let cur = activeEmailOrder else { return }
        guard let fresh = try? await api.check(orderId: cur.id) else { return }
        activeEmailOrder = fresh
        if let i = emailOrders.firstIndex(where: { $0.id == fresh.id }) {
            emailOrders[i] = fresh
        }
        if fresh.hasCode, flow == .emailWaiting { flow = .emailCode }
        // Terminal without a code must EXIT, not spin forever. The server sweep
        // expires and refunds the order; before this branch existed the screen
        // kept rendering "Waiting for the code" with nothing left to wait for —
        // the SMS apply() rule ("cover every terminal status") not applied here.
        if fresh.status.isTerminal, !fresh.hasCode, flow == .emailWaiting {
            lastError = fresh.wasRefunded
                ? String(localized: "No code arrived. Your \(fresh.costCredits) credits are back in your balance.")
                : String(localized: "No code arrived for that address.")
            flow = nil
        }
    }

    func startEsimCheckout(_ plan: EsimPlan) {
        checkoutEsimPlan = plan
        intent = .esim          // declare it; never let creditsShortfall guess
        flow = .esimCheckout
    }
    func openEsimDetail(_ order: EsimOrder) {
        activeEsimOrder = order
        flow = .esimDetail
    }

    /// @MainActor for the same atomic double-tap guard reasoning as confirmGetNumber.
    @MainActor
    func confirmBuyEsim(using api: EsimOrdersAPI, wallet: WalletAPI) async {
        guard let plan = checkoutEsimPlan, !isBuyingEsim else { return }
        isBuyingEsim = true
        defer { isBuyingEsim = false }
        do {
            let server = try await api.create(planId: plan.id)
            let order = EsimOrder(server: server, plan: esimPlanIndex[server.planId ?? ""] ?? plan)
            esimOrders.insert(order, at: 0)
            activeEsimOrder = order
            flow = .esimDetail
            await refreshWallet(using: wallet)
        } catch let apiErr as APIError {
            lastError = apiErr.userMessage
        } catch {
            lastError = "Couldn't buy that eSIM. Please try again."
        }
    }

    func refreshEsimUsage(using api: EsimOrdersAPI) async {
        guard let current = activeEsimOrder else { return }
        guard let server = try? await api.checkUsage(orderId: current.id) else { return }
        let updated = EsimOrder(server: server, plan: current.plan)
        activeEsimOrder = updated
        if let idx = esimOrders.firstIndex(where: { $0.id == updated.id }) { esimOrders[idx] = updated }
    }

    func loadOrders(using api: OrdersAPI) async {
        // Screenshot frames seed this collection directly. The read below is
        // RLS-filtered and would succeed with an EMPTY list, silently wiping
        // the sample — which is how the thread frame came back black.
        if ScreenshotMode.isActive { return }
        do {
            let rows = try await api.list()
            // A code that appears here and wasn't on the previous fetch is new
            // information for the foreground review prompt: the user may have
            // read it straight off a lock-screen push and never opened
            // `OtpScreen` at all. `hadPriorState` skips the very first
            // population of a session — an empty prior list can't tell "just
            // arrived" from "arrived last week", and every cold launch starts
            // from `orders == []`. See `reviewableRecentDelivery`.
            let hadPriorState = !orders.isEmpty
            let previouslyDelivered = Set(orders.compactMap { $0.otp != nil ? $0.id : nil })
            let resolved = rows.compactMap { resolve($0) }
            orders = resolved
            if hadPriorState {
                for order in resolved where order.otp != nil && !previouslyDelivered.contains(order.id) {
                    recordCodeDelivered(orderId: order.id)
                }
            }
        } catch {
            // keep current
        }
    }

    /// Put the user back on the waiting screen for an order that was still in
    /// flight when the app was killed.
    ///
    /// Without this, force-quitting during a wait stranded a PAID order: the
    /// screen was gone, nothing polled it, and the only trace was a row in
    /// history. The server still resolves and refunds it either way, but the
    /// user had no way to receive the code they'd paid for.
    ///
    /// Cold launch only — a backgrounded app keeps `flow` in memory, so this
    /// must never run on scenePhase changes or it would yank someone out of
    /// whatever they navigated to.
    func resumeInFlightOrder() {
        guard flow == nil, activeOrder == nil else { return }
        // Newest first (list() orders by created_at desc). Skip pre-reservation
        // rows with no number yet — there's nothing to show and the expiry
        // sweep closes them.
        guard let live = orders.first(where: {
            $0.status == .waiting && $0.server.smspvaNumber != nil
        }) else { return }
        // Don't resurrect an ancient row. Inside this window the order is
        // either genuinely live or about to be closed+refunded by the cron —
        // and resuming shows that outcome honestly instead of hiding it.
        guard live.expiresAt > Date().addingTimeInterval(-600) else { return }
        activeOrder = live
        flow = .waiting
    }

    /// Build a UI Order from a server row using the loaded catalog.
    /// Falls back to placeholder Service/Country so the order is still
    /// renderable if the catalog reference is stale.
    func resolve(_ s: ServerOrder) -> Order {
        let svc = services.first { $0.id == s.serviceId } ?? AppState.fallbackService
        let cty = countries.first { $0.id == s.countryId } ?? AppState.fallbackCountry
        return Order(server: s, service: svc, country: cty)
    }

    // ─────────── Checkout / waiting / OTP ───────────

    func startCheckout(service: Service? = nil, country: Country? = nil) {
        let svc = service ?? lastService
        let cty = country ?? lastCountry
        intent = .sms
        checkoutService = svc
        checkoutCountry = cty
        // Open on real-SIM where standard is measurably a dead end.
        checkoutPremium = defaultPremium(for: svc, country: cty)
        flow = .checkout
    }

    /// Calls create-order. On success, deducts credits and transitions to
    /// the Waiting flow. On failure, sets lastError and stays on Checkout.
    ///
    /// @MainActor is load-bearing: AppState is @Observable but not otherwise
    /// actor-isolated, so without this the double-tap guard below is a racy
    /// check-then-set. Two taps spawn two Tasks that run off the main actor and
    /// can both read isPlacingOrder == false before either sets it, each placing
    /// a (charged) order. Pinning to the main actor makes guard+set atomic: the
    /// second tap runs only after the first has set the flag and suspended.
    /// Leave the waiting screen and open checkout for ANOTHER number, without
    /// touching the one already running.
    ///
    /// This is not a reroll. A reroll releases the current number first, so it
    /// is destructive and correctly blocked by the 180s hold — which left a user
    /// whose number the site had just rejected with nothing to do for three
    /// minutes. This adds a second number alongside the first: the original
    /// keeps running, keeps its hold, and still refunds on expiry if no code
    /// arrives. Costs another order's credits, which is the honest trade and is
    /// why the button states the price.
    func orderAnotherNumber() {
        guard let order = activeOrder else { return }
        // Deliberately does NOT clear activeOrder — the order is still live and
        // ResumeBar reads the list, so both remain reachable.
        wantsConcurrentOrder = true
        startCheckout(service: order.service, country: order.country)
    }

    /// Set by `orderAnotherNumber`, consumed by the next `confirmGetNumber`.
    /// Cleared on every exit from checkout so it can never leak into an
    /// unrelated order — the same failure mode as the stale checkout draft.
    var wantsConcurrentOrder = false

    @MainActor
    func confirmGetNumber(using orders: OrdersAPI, wallet: WalletAPI) async {
        guard let svc = checkoutService, let cty = checkoutCountry else { return }
        guard !isPlacingOrder else { return }   // no double-charge on double-tap
        isPlacingOrder = true
        defer { isPlacingOrder = false }
        let concurrent = wantsConcurrentOrder
        do {
            let server = try await orders.create(serviceId: svc.id, countryId: cty.id,
                                                 premium: effectiveCheckoutPremium,
                                                 allowConcurrent: concurrent,
                                                 fromDefault: needsServiceChoice)
            let order = resolve(server)
            lastService = svc
            lastCountry = cty
            activeOrder = order
            self.orders.insert(order, at: 0)
            flow = .waiting
            await refreshWallet(using: wallet)
        } catch let apiErr as APIError {
            lastError = apiErr.userMessage
        } catch {
            lastError = "Something went wrong. Please try again."
        }
    }

    /// One-shot check for the active order. Called repeatedly from the
    /// Waiting screen's polling task and once from the "Check now" button.
    ///
    /// `check-order` polls the live SMS provider, so it 502s
    /// (`provider_unreachable`) whenever the provider is flaky. This used to
    /// `catch { /* transient */ }` and keep waiting — which meant that while
    /// the provider was down, the 60s cron could expire AND refund the order
    /// while the screen sat on "Waiting / 00:00" forever. That is the single
    /// worst state in the app: the user has been made whole and has no idea.
    /// Now a failed check falls back to the authoritative row read (see
    /// `reconcileActiveOrder`) once it's plausible the order actually ended.
    func pollActiveOrder(using orders: OrdersAPI, wallet: WalletAPI) async {
        // A reroll deliberately cancels the current order before creating its
        // replacement. Reading the row in that window sees `canceled` and
        // would bounce the user to the recovery card mid-reroll — while a new
        // order they just paid for is being created behind it.
        guard let current = activeOrder, !isPlacingOrder else { return }
        do {
            let server = try await orders.check(orderId: current.id)
            pollFailureStreak = 0
            await apply(server: server, for: current, wallet: wallet)
        } catch {
            pollFailureStreak += 1
            // A single blip mid-wait is genuinely transient — keep waiting.
            // But once the provider has failed us twice, or the reservation
            // window is up, stop trusting the provider-dependent path and go
            // ask the database what actually happened.
            if pollFailureStreak >= 2 || isPastExpiry(current) {
                await reconcileActiveOrder(using: orders, wallet: wallet)
            }
        }
    }

    /// The "Check now" button. Unlike the background poll it must NEVER
    /// dead-end: if the provider-dependent check fails for any reason, fall
    /// straight through to the authoritative row read. A user who taps this is
    /// explicitly asking "what is actually going on?" and deserves an answer,
    /// not a silently swallowed 502.
    func checkNow(using orders: OrdersAPI, wallet: WalletAPI) async {
        guard let current = activeOrder, !isPlacingOrder else { return }
        do {
            let server = try await orders.check(orderId: current.id)
            pollFailureStreak = 0
            await apply(server: server, for: current, wallet: wallet)
        } catch {
            await reconcileActiveOrder(using: orders, wallet: wallet)
        }
    }

    /// Resolve the active order against the ORDER ROW, not the provider.
    ///
    /// This is the recovery path for every way the provider-dependent poll can
    /// fail: 502s, airplane mode, an order the cron expired while we were
    /// backgrounded. It never throws to the caller — if even this read fails
    /// (truly offline) we stay put and try again, because inventing a terminal
    /// state we haven't confirmed would be its own lie.
    func reconcileActiveOrder(using orders: OrdersAPI, wallet: WalletAPI) async {
        guard let current = activeOrder, !isPlacingOrder else { return }
        do {
            let server = try await orders.fetch(orderId: current.id)
            pollFailureStreak = 0
            await apply(server: server, for: current, wallet: wallet)
        } catch {
            // Still unreachable. WaitingScreen keeps the honest "confirming"
            // state and calls us again; nothing is asserted.
        }
    }

    /// Single place where a server order row moves the UI. Terminal statuses
    /// all leave the waiting screen and surface the refund.
    private func apply(server: ServerOrder, for current: Order, wallet: WalletAPI) async {
        let updated = resolve(server)
        if let idx = self.orders.firstIndex(where: { $0.id == updated.id }) {
            self.orders[idx] = updated
        } else {
            self.orders.insert(updated, at: 0)
        }

        // A code can now exist on a NON-received order: the late-code rescue
        // writes `otp` onto a canceled row after refunding. Check for the code
        // before branching on status, or a rescued order falls into the
        // terminal branch and shows "no code arrived" while holding one.
        if server.otp != nil {
            activeOrder = updated
            await refreshWallet(using: wallet)
            flow = .otp
            return
        }

        switch server.status {
        case .received:
            activeOrder = updated
            flow = .otp
        case .expired, .canceled, .refunded:
            // All three are terminal AND refunded: `poll-active-orders` and
            // `cancel-order` both `wallet_credit` the full cost before writing
            // the status. (`refunded` is never written by the backend today —
            // handled so a future status can't silently strand the UI again,
            // which is exactly what `default: break` did for `canceled`.)
            await refreshWallet(using: wallet)
            recovery = RecoveryContext(
                service: current.service,
                failedCountry: current.country,
                reason: server.status == .canceled ? .canceled : .expired,
                refundedCredits: updated.costCredits
            )
            flow = .recovery
            activeOrder = nil
        case .waiting:
            // Still genuinely in flight — keep the live row (the number may
            // have only just been assigned) and stay on the waiting screen.
            activeOrder = updated
        }
    }

    /// True once the reservation window has elapsed (plus a grace period, so
    /// we don't race the cron that closes the order — it runs every 60s).
    func isPastExpiry(_ order: Order, grace: TimeInterval = 5) -> Bool {
        Date() >= order.expiresAt.addingTimeInterval(grace)
    }

    // MARK: - The minimum hold

    /// Seconds a paid order must be held before it can be destroyed, PER
    /// PROVIDER. Mirrors `MIN_HOLD_BY_PROVIDER` in `cancel-order`.
    ///
    /// ⚠️ **These must equal the server's values, and this table may only ever
    /// be RAISED AHEAD of the server, never lowered behind it.** A client that
    /// offers cancel before the server allows it collects a 429 on a button the
    /// user has already tapped; a client that holds longer than the server
    /// merely waits. That asymmetry is why the sequencing is: client first,
    /// server second.
    ///
    /// 5sim's measured p90 arrival is 155s, so its server-side hold is intended
    /// to go to 155 — deliberately NOT yet, because a shipped client rendering
    /// a 90s countdown against a 155s server hold produces exactly the broken
    /// button above (measured 2026-08-18: 13 of the last 29 5sim cancels landed
    /// in that 85–158s gap). Raise the 5sim row here first, ship it, and only
    /// then raise `MIN_HOLD_BY_PROVIDER["5sim"]` to 155.
    static let minHoldByProvider: [String: Int] = [
        "5sim":    90,   // → 155 once this client is in the field, see above
        "herosms": 90,   // max arrival ever observed is 86s
        "smspva":  90,   // retired from routing; kept so an in-flight row resolves
    ]

    /// Used for an unrecorded or unknown provider. Matches the server's
    /// `MIN_HOLD_FALLBACK`, so an order whose provider we cannot read behaves
    /// exactly as it did before this table existed.
    static let minHoldFallback = 90

    static func minHoldSeconds(forProvider provider: String?) -> Int {
        guard let provider, let hold = minHoldByProvider[provider] else {
            return minHoldFallback
        }
        return hold
    }

    /// When the SERVER last said the hold on an order expires.
    ///
    /// The table above is our mirror of the server's constants and can be stale
    /// by a release; `cancel-order`'s 429 carries `retry_after_seconds`, which
    /// is the server's own arithmetic on its own clock and therefore always
    /// right. Recording it re-locks the button for exactly that long instead of
    /// leaving a live control that fails every time it is pressed.
    ///
    /// Keyed by order id and never pruned: it holds at most a handful of
    /// entries per session, each a `Date`.
    private(set) var serverHoldUntil: [String: Date] = [:]

    /// Seconds still to run on the server-declared hold, or nil if we have
    /// never been told or it has passed.
    func serverHoldRemaining(forOrder id: String) -> Int? {
        guard let until = serverHoldUntil[id] else { return nil }
        let left = Int(until.timeIntervalSinceNow.rounded(.up))
        return left > 0 ? left : nil
    }

    /// Record `retry_after_seconds` off a refused cancel/reroll.
    private func noteServerHold(from error: APIError, orderId: String) {
        guard let secs = error.retryAfterSeconds, secs > 0 else { return }
        serverHoldUntil[orderId] = Date().addingTimeInterval(TimeInterval(secs))
    }

    /// `@MainActor` for the same reason `confirmGetNumber` carries it: AppState
    /// is `@Observable` but not otherwise actor-isolated, so without it the
    /// `!isPlacingOrder` guard below is a racy check-then-set and two taps can
    /// both read `false` before either writes `true`. The siblings got the
    /// annotation; the two money-mutating methods reachable from the same
    /// waiting screen did not.
    @MainActor
    func cancelWaiting(using orders: OrdersAPI, wallet: WalletAPI) async {
        // !isPlacingOrder matters: the ✕ used to stay live during a reroll, so
        // this could fire mid-reroll, release the flag early (re-opening the
        // window it exists to close) and then null activeOrder AFTER the reroll
        // had installed the fresh one — leaving flow == .waiting with no order,
        // which renders an empty screen over a live paid order.
        guard let order = activeOrder, !isPlacingOrder else { return }
        // Same guard as reroll: while the cancel is in flight the background
        // poll/reconcile must not read the row and claim the outcome first
        // (it would land on "No code arrived" instead of "Number released").
        isPlacingOrder = true
        defer { isPlacingOrder = false }
        do {
            let server = try await orders.cancel(orderId: order.id)
            let updated = resolve(server)
            if let idx = self.orders.firstIndex(where: { $0.id == updated.id }) {
                self.orders[idx] = updated
            }
            // The backend does a last-chance poll before canceling: if the
            // code was already in flight, the "cancel" comes back as a
            // delivered order. Show the code — it's what they paid for.
            if updated.status == .received {
                activeOrder = updated
                flow = .otp
                return
            }
            await refreshWallet(using: wallet)
            // Refund confirmed — offer a steer instead of a dead end (72 of
            // the last 122 orders were re-orders; the demand doesn't vanish
            // with the number).
            recovery = RecoveryContext(service: order.service,
                                       failedCountry: order.country,
                                       reason: .canceled,
                                       refundedCredits: updated.costCredits)
            flow = .recovery
        } catch let apiErr as APIError {
            // Cancel FAILED — the order is still WAITING and still charged, so
            // stay on the waiting screen and let the banner explain.
            //
            // This used to set `flow = nil` and then null `activeOrder`
            // unconditionally below, which dumped the user to Home with a live
            // paid order that nothing was polling any more — the number gone
            // from every screen and the code reachable only by push. The 180s
            // minimum hold made that reachable ON PURPOSE: every early ✕ tap
            // returns 429 `cancel_too_early`.
            //
            // Take the server's own countdown when it sent one: our mirror of
            // its constants can be a release behind, and re-locking the control
            // is what stops the user tapping a button that cannot work yet.
            noteServerHold(from: apiErr, orderId: order.id)
            lastError = apiErr.userMessage
        } catch {
            lastError = "Couldn't cancel that order. Please try again."
        }
    }

    /// Swap the current number for a fresh one without leaving the wait screen.
    ///
    /// This is already how people use the app — 72 of the last 122 orders were
    /// re-orders placed within 10 minutes of the previous one, median gap 19
    /// seconds — but until now it took six taps (✕ → home → picker → country →
    /// checkout → get). It's also economically free: cancelling refunds the
    /// credits in full and the new order charges the same, so the user only
    /// ever pays for the number that actually delivers.
    ///
    /// `differentCountry` matters when a platform rejected the number outright:
    /// the whole range is usually flagged, so another number from it will fail
    /// the same way. Falls back to the same route when there's no alternative.
    @MainActor
    func rerollNumber(using orders: OrdersAPI, wallet: WalletAPI,
                      differentCountry: Bool) async {
        guard let order = activeOrder, !isPlacingOrder else { return }
        let svc = order.service

        var next = order.country
        if differentCountry {
            let alternatives = countries.filter {
                $0.id != order.country.id
                && cost(for: svc, country: $0) != nil
                && (cost(for: svc, country: $0) ?? .max) <= balance + order.costCredits
            }
            // Prefer a route we've MEASURED delivering; break ties on the
            // CHEAPEST, not the priciest.
            //
            // This used to sort by (rate, cost) descending. With no measured
            // rate — the normal case — every candidate tied at -1 and the max
            // picked the most expensive country the balance could cover, so
            // tapping "rejected it" could silently charge 40cr for Thailand
            // seconds after the sheet quoted 3cr for the Netherlands. That is
            // the exact "priciest wins" heuristic already deleted from
            // bestCountry(for:) and CountrySheet; rerollNumber was missed.
            // Two further faults fixed here, both from ranking on `successRate`:
            //
            //  a. It counted SMSPVA's SEEDED grade as evidence, so a reroll
            //     could steer a user who just failed onto a route we had never
            //     sold, purely on the vendor's opinion of its own inventory.
            //  b. `?? -1` sorted UNTESTED below measured-zero (key 1 vs 0), so
            //     the retry preferred a route we had measured never delivering
            //     over one we simply hadn't tried. Exactly backwards at the one
            //     moment the user has already been let down once.
            //
            //  c. Untested routes then tied on PRICE, i.e. the retry after a
            //     failure steered to the cheapest country in the catalog —
            //     Colombia — which is where a good share of first failures
            //     happen in the first place. Retrying into the same bargain
            //     bin is the worst possible answer here.
            //
            // Same tiering as bestCountry / affordableFallbackCountry: proven →
            // untested ranked by the POOL's published rate → measured-failing.
            //
            //  d. It ranked untested routes by the COUNTRY's record alone, so
            //     it could not see `pool_rate_pct` at all — the very number the
            //     retry screen is about to show the user. Retrying onto a pool
            //     the provider reports at 0% while an 80% pool sat one row down
            //     is the same dead end as (c), one signal later.
            func retryKey(_ c: Country) -> (Int, Int, Int, Int, Int) {
                let price = cost(for: svc, country: c) ?? .max
                guard let ratio = deliveryRecord(for: svc, country: c).ratio else {
                    let k = rankedUntestedKey(svc, c, price: price)
                    return (k.0 + 1, k.1, k.2, k.3, k.4)              // untested
                }
                return ratio > 0 ? (0, 0, 0, -Int(ratio * 100), price)   // proven
                                 : (4, 0, 0, 0, price)                   // proven-bad
            }
            next = alternatives.min { retryKey($0) < retryKey($1) } ?? order.country
        }

        isPlacingOrder = true
        defer { isPlacingOrder = false }

        // Release the old number first so its credits are back before we spend
        // again — a reroll must never need a bigger balance than the original.
        //
        // ABORT if that release fails. This used to be `try?` with the create
        // running unconditionally afterwards, which meant a rejected cancel
        // left the original order `waiting` AND charged for a replacement —
        // two live paid orders from one tap. That is now reachable on purpose:
        // the server refuses cancels inside the 180s minimum hold, so a reroll
        // at 30s returns an error rather than a released number.
        do {
            let server = try await orders.cancel(orderId: order.id)
            let updated = resolve(server)
            if let idx = self.orders.firstIndex(where: { $0.id == updated.id }) {
                self.orders[idx] = updated
            }
            // The cancel can come back DELIVERED (last-chance provider poll).
            // Rerolling away from a code we just fetched would throw away the
            // thing the user paid for.
            if updated.status == .received {
                activeOrder = updated
                flow = .otp
                return
            }
        } catch let apiErr as APIError {
            // A reroll releases the number exactly like a cancel, so it hits
            // the same hold and carries the same `retry_after_seconds`.
            noteServerHold(from: apiErr, orderId: order.id)
            lastError = apiErr.userMessage
            return
        } catch {
            lastError = "Couldn't release the current number. Please try again."
            return
        }
        await refreshWallet(using: wallet)

        do {
            // Carry the tier across. A reroll used to always create a STANDARD
            // order, silently downgrading a buyer who had paid the Real-SIM
            // uplift to a random Donor* pool number — the exact "never silently
            // downgrade premium" rule the backend enforces, broken on the client.
            let server = try await orders.create(serviceId: svc.id, countryId: next.id,
                                                 premium: order.server.tier == "premium")
            let fresh = resolve(server)
            lastService = svc
            lastCountry = next
            activeOrder = fresh
            self.orders.insert(fresh, at: 0)
            flow = .waiting               // stay put; only the number changes
            await refreshWallet(using: wallet)
        } catch let apiErr as APIError {
            // The old number is already released and refunded — recover, don't
            // dead-end. The banner still explains why this attempt failed.
            lastError = apiErr.userMessage
            recovery = RecoveryContext(service: svc, failedCountry: next, reason: .canceled,
                                       refundedCredits: order.costCredits)
            flow = .recovery
            activeOrder = nil
        } catch {
            lastError = "Couldn't get another number. Please try again."
            recovery = RecoveryContext(service: svc, failedCountry: next, reason: .canceled,
                                       refundedCredits: order.costCredits)
            flow = .recovery
            activeOrder = nil
        }
    }

    func finishOtp() {
        activeOrder = nil
        // Orders is a cover now, not a tab — assigning `flow` last so the
        // OTP cover is replaced rather than dismissed to nothing.
        flow = .orders
    }

    /// Best country for `service` by MEASURED evidence only — the sole basis
    /// on which the recovery card may state a rate as fact. nil when nothing
    /// measured ≥ 40% is bookable (below that, "delivers best" is technically
    /// honest but useless advice). Highest rate wins; ties go to the cheaper.
    func bestMeasuredCountry(for service: Service) -> (country: Country, rate: Int)? {
        let candidates = countries.compactMap { c -> (country: Country, rate: Int, price: Int)? in
            guard let info = rateInfo(for: service, country: c), info.isMeasured,
                  info.rate >= 40, let price = cost(for: service, country: c) else { return nil }
            return (c, info.rate, price)
        }
        guard let best = candidates.max(by: { ($0.rate, -$0.price) < ($1.rate, -$1.price) })
        else { return nil }
        return (best.country, best.rate)
    }

    /// Retry from the recovery card. Lands on Checkout (not straight into an
    /// order) so price/balance are confirmed the normal way; the backend's
    /// retry steering makes the new attempt draw a fresh number on a rotated
    /// carrier. Steers to the measured-best country when one exists, else the
    /// same route.
    /// - Parameter country: the country the CARD OFFERED, when it offered one.
    ///
    /// ⚠️ This parameter is the fix for a silent contradiction, not a
    /// convenience. The recovery card has two suggestion sources: our own
    /// measured record (`bestMeasuredCountry`) and, when we have measured
    /// nothing, the vendor's network-wide ranking (`bestRankedCountry`). This
    /// function only ever consulted the FIRST — and the ranked branch exists
    /// precisely when the measured one returns nil, so on that branch
    /// `suggested` collapsed to `r.failedCountry`: the button said "Try Poland"
    /// and re-ordered the country that had just failed. The caller now passes
    /// what it rendered, so the label and the order cannot disagree.
    func retryFromRecovery(country: Country? = nil) {
        guard let r = recovery else { return }
        let suggested = country ?? bestMeasuredCountry(for: r.service)?.country ?? r.failedCountry
        recovery = nil
        startCheckout(service: r.service, country: suggested)
    }

    func dismissRecovery() {
        recovery = nil
        flow = nil
    }

    func buyAgain(_ order: Order) {
        startCheckout(service: order.service, country: order.country)
    }

    // ─────────── Fallbacks ───────────

    private static let fallbackService = Service(
        id: "fallback", name: "Service", category: "Other",
        glyph: "S", icon: "questionmark", domain: nil,
        tintHex: "#1B2330", smspvaCode: "opt0",
        cost: 1, successRate: 95, etaSeconds: 30, sortOrder: 100
    )
    private static let fallbackCountry = Country(
        id: "fallback", name: "Country", flag: "🌐",
        dialCode: "+0", smspvaCode: "XX",
        stock: .high, avgSeconds: 30, sortOrder: 100
    )
}

extension WaitingAnimation {
    var displayName: String {
        switch self { case .pulse: "Pulse"; case .breathe: "Breathe"; case .orbit: "Orbit" }
    }
}

extension OtpAnimation {
    var displayName: String {
        switch self { case .cascade: "Cascade"; case .reveal: "Reveal"; case .flip: "Flip" }
    }
}
