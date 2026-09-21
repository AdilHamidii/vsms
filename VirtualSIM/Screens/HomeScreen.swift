import SwiftUI

/// The tab the app opens on (owner decision 2026-09-10).
///
/// ── Why it exists ─────────────────────────────────────────────────────────
///
/// The app sells three things and, until this screen, named none of them
/// anywhere a new user would look. They landed on whichever product tab
/// `/tabs` happened to lead with, and a quarter of first sessions bounced
/// between the two — which is a user asking "which of these is the one I
/// want?" and getting no answer from the interface. That cohort produced most
/// of the support taps.
///
/// ── What it is, and what it deliberately is NOT ───────────────────────────
///
/// A **router** for a user with no live line, and a **light dashboard** once
/// they own one. Every card jumps to a screen that already exists; nothing is
/// rebuilt here. In particular there is **no inbox and no waiting-order card**
/// — `ResumeBar` already floats above the tab bar on every tab, so a second
/// copy of a live order here would be a second place for it to go stale. The
/// Recent group below is deliberately a different thing: at most three
/// FINISHED-or-running rows that open exactly what the Orders screen opens,
/// through `AppState.openOrder` / `openEmailOrder` rather than a second copy
/// of that routing.
///
/// ── Two rules this screen is built around ─────────────────────────────────
///
/// 🔴 **It renders from local state on the FIRST FRAME.** `coldStart` has
/// already answered `lines` and `lineThreads` before the reveal, so nothing
/// here waits on a fetch. The `.task` does exactly two things and neither
/// gates a pixel — see it below.
///
/// 🔴 **Card order is `AppTab.productOrder`, not a literal.** That is the same
/// definition `TabBar` reads, so a bar led by Number and a Home screen led by
/// the temp card is impossible by construction — the bug the `currentOrder`
/// shape exists to prevent, one layer up.
struct HomeScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    @Environment(SubscriptionStore.self) private var subs
    @Environment(CallController.self) private var calling
    /// The greeting needs the signed-in address, because a `display_name` that
    /// merely equals the e-mail handle is NOT a name — see
    /// `AppState.greetingName(email:)`.
    @Environment(Session.self) private var session

    var openCredits: () -> Void = {}
    /// Raises the full service picker. `ContentView` hands over the same
    /// closure `TempScreen` gets, so the More tile and the Temp tab's own
    /// picker are one sheet, not two.
    var openServices: () -> Void = {}

    @State private var appeared = false
    /// `home_view` is once per APPEARANCE, not once per body evaluation.
    /// `AppState` is `@Observable` and this screen reads several of its
    /// collections, so an ungated `track` in `body` would fire on every
    /// redraw and make the one number this event answers meaningless.
    @State private var tracked = false
    @State private var showNameSheet = false
    /// See `howItWorks` — a disclosure, deliberately not persisted.
    @State private var howItWorksOpen = false

    /// The card order, resolved into a stored property when the view is
    /// initialised — once per `HomeScreen` init, not per body evaluation —
    /// the same rule, and the same reason, as `TabBar.items`: `AppState` is
    /// `@Observable` and this screen redraws on every collection it reads, so
    /// a computed order would hit UserDefaults on each redraw. Not once per
    /// SESSION, though: `ContentView` re-inits this struct on any change it
    /// observes (opening and closing the credits sheet, say), and the key is
    /// written by `refreshAppStatus` AFTER the reveal — so on the one launch
    /// that carries a `/tabs` flip, a re-init can pick the new order up before
    /// the next cold launch. Two cards swapping places once, on that launch
    /// only; `TabBar.items` has the same property. Harmless, and cheaper than
    /// a static cache that would then disagree with the bar.
    private let productOrder = AppTab.productOrder

    /// The user holds a rented number RIGHT NOW.
    ///
    /// `linesLoaded` is part of the predicate on purpose: before the fetch
    /// lands `lines` is empty, which is indistinguishable from "not a
    /// subscriber" — and offering a subscriber the number card for a second
    /// before it flips is exactly the kind of flash `coldStart` orders its
    /// steps to avoid. Same gate `OtpScreen.keepNumberCard` uses.
    private var hasLine: Bool {
        state.linesLoaded && (state.line?.status.isLive ?? false)
    }

    private var hasHistory: Bool {
        !state.orders.isEmpty || !state.emailOrders.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .riseIn(appeared, index: 0)

                // Directly UNDER the greeting (owner, 2026-09-15), and above
                // everything else on the screen: an announcement is the owner
                // telling users something about the service right now — an
                // outage, a provider switch — which outranks every card below
                // it but reads better after the greeting than in front of it.
                // It lived on the Temp tab until 2026-09-15; Home is element 0
                // of every `launchOrder` by construction, so it is now seen on
                // every cold launch rather than only by Temp visitors.
                if let announcement = state.visibleAnnouncement {
                    AnnouncementBanner(announcement: announcement) {
                        state.dismissAnnouncement()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                if hasLine, let line = state.line {
                    lineCard(line)
                        .padding(.horizontal, 16)
                        .padding(.top, 18)
                        .riseIn(appeared, index: 1)
                }

                // 🔴 The GRID sits in the `.temp` slot where a separate "A code
                // for an app" card used to, and that fold is the point of this
                // screen's 2026-09-21 rewrite. Home asked the same question
                // twice in two vocabularies — an outcome card ("A code for an
                // app") immediately above a brand grid ("Get a code for" +
                // logos) — and the user had to work out they were the same
                // destination. Worse, the CARD was the poorer of the two: it
                // landed on Temp with nothing selected, so the user still owed
                // a `ServiceSheet` trip, while a tile pre-fills the service via
                // `commitServicePick`. Folding removed a decision AND a step.
                //
                // ⚠️ `home_card_tapped{card:"sms"}` therefore STOPS being
                // emitted from this release. The same intent is now
                // `service_selected{source:"home"}` (a tile) or
                // `home_card_tapped{card:"more_services"}`. Do not read the
                // `sms` arm going to zero as the SMS product dying.
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(productOrder, id: \.self) { tab in
                        switch tab {
                        case .temp:
                            serviceGrid
                                .padding(.bottom, 6)
                            emailCard
                        case .line:
                            // Absent for a subscriber: the card above IS their
                            // number, and one live line per user is enforced by
                            // a partial unique index, not by convention.
                            if !hasLine { numberCard }
                        default:
                            EmptyView()
                        }
                    }
                }
                .padding(.horizontal, 16)
                // There is no header above this stack in either state now, so
                // the stack itself owns the gap the header used to provide.
                .padding(.top, 26)
                .riseIn(appeared, index: 2)

                recentOrHowItWorks
                    .padding(.horizontal, 16)
                    .padding(.top, 26)
                    .riseIn(appeared, index: 3)
            }
            .padding(.top, 8)
            // The tab bar floats over the content, as on every other tab.
            .padding(.bottom, 140)
        }
        .scrollIndicators(.hidden)
        .onAppear {
            guard !tracked else { return }
            tracked = true
            // ⚠️ `has_line` is `false` whenever lines have not loaded yet, and
            // this fires on the FIRST frame — so on its own it cannot tell a
            // non-subscriber from a subscriber whose `my_line` read is still in
            // flight. On 2026-09-16 a subscriber who swapped three times logged
            // 0 true / 8 false, and the flag was nearly read as proof a buyer
            // never saw his number. `lines_loaded` is what makes it readable:
            // trust `has_line` only where `lines_loaded` is true. The event is
            // deliberately NOT delayed until load — that would break the series
            // and never fire at all for a user whose lines fail to load.
            Analytics.shared.track("home_view", [
                "has_line": .bool(hasLine),
                "has_orders": .bool(hasHistory),
                "lines_loaded": .bool(state.linesLoaded),
            ])
        }
        // Env objects injected explicitly rather than inherited: sheet content
        // does not reliably inherit `@Observable` environment objects from its
        // presenter, which is the reason `EnvBundle` exists at all — and that
        // modifier is private to `ContentView`, so every sheet raised from a
        // screen (`TempScreen`'s paywall, `ThreadScreen`'s name sheet) lists
        // what it needs the same way.
        .sheet(isPresented: $showNameSheet) {
            NameSheet()
                .environment(\.theme, theme)
                .environment(state)
                .environment(api)
                .environment(session)
                .presentationDetents([.height(280)])
                .presentationDragIndicator(.visible)
                .presentationBackground(theme.bg)
        }
        .task {
            withAnimation(RMotion.content) { appeared = true }
            // ⚠️ THE CALL LOAD GOES FIRST, and the order is the whole point:
            // these two awaits used to run in sequence behind `loadProduct`,
            // so a subscriber's missed-call count waited on a StoreKit round
            // trip that prices a card they are not even shown. The count reads
            // 0 until this lands — the honest direction to be wrong in, since
            // it undercounts for a moment rather than claiming a call that was
            // not missed — so the shorter that moment is, the better.
            //
            // 🔴 `loadLine` and `loadLineThreads` are deliberately NOT called
            // here — `coldStart` answers both before the reveal, and a second
            // read re-creates a documented flash.
            if state.line?.status.isLive == true {
                await state.loadLineCalls(using: LineAPI(client: api))
            }
            // Cheap and idempotent (`loadProduct` returns immediately once the
            // product is in hand). It prices the number card — and until it
            // answers that card simply carries no price line rather than a
            // literal one.
            await subs.loadProduct()
        }
    }

    // MARK: - Header

    /// Eyebrow greets the user; the headline asks the question the screen
    /// exists to answer, or names what the user already owns.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                greetingButton
                Spacer(minLength: 0)
                CreditPill(value: state.balance, action: {
                    track("credits")
                    openCredits()
                })
            }
            headline
        }
    }

    /// The greeting, and the only way to set the name it uses.
    ///
    /// The pencil is the whole affordance — there is no Settings row for this
    /// — so the eyebrow itself is the button rather than the glyph alone: a
    /// 10pt pencil is well under the 44pt minimum on its own, and the label
    /// beside it is what tells the user what the pencil would edit.
    private var greetingButton: some View {
        Button {
            RHaptic.select()
            showNameSheet = true
        } label: {
            HStack(spacing: 6) {
                greeting
                Image(systemName: "pencil")
                    .font(.system(size: 10, weight: .semibold))
                    // The hint below already says what the pencil means, so
                    // leaving it visible to VoiceOver only adds a symbol name
                    // in front of the greeting.
                    .accessibilityHidden(true)
            }
            .font(RFont.text(11, weight: .heavy))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(theme.text3)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .frame(minHeight: 30, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(PressScaleStyle(scale: 0.97))
        // 🔴 A HINT, not the label. `.accessibilityLabel` REPLACES what the
        // button's own label would read, so putting the affordance there
        // traded the greeting for it — a VoiceOver user heard "Set your name,
        // button" and never heard the greeting the sighted user sees. The
        // greeting stays the label (it is the content); the hint says what
        // happens on a tap, which is exactly what hints are for.
        .accessibilityHint(Text("Set your name"))
    }

    /// Six complete sentences, never a daypart word interpolated into one.
    ///
    /// Same rule as `lineStatus` and `headline`: German and the Romance
    /// languages inflect what surrounds an inserted noun, and a ternary between
    /// two string literals resolves to `String`, which selects
    /// `Text.init<S: StringProtocol>` and skips the catalog entirely.
    ///
    /// A nameless greeting is the honest fallback, not a degraded one:
    /// `greetingName` returns nil precisely when the stored `display_name` is
    /// the e-mail handle `handle_new_user()` seeded, and greeting somebody by
    /// their address reads as the app quoting a database row back at them.
    @ViewBuilder
    private var greeting: some View {
        if let name = state.greetingName(email: session.email) {
            switch Daypart.current() {
            case .morning:   Text("Good morning, \(name)")
            case .afternoon: Text("Good afternoon, \(name)")
            case .evening:   Text("Good evening, \(name)")
            }
        } else {
            switch Daypart.current() {
            case .morning:   Text("Good morning")
            case .afternoon: Text("Good afternoon")
            case .evening:   Text("Good evening")
            }
        }
    }

    // An if/else over two `Text("literal")` calls rather than one ternary. A
    // ternary between two string literals resolves to `String`, which selects
    // `Text.init<S: StringProtocol>` — so the copy silently stops being
    // localized and never reaches the catalog at all.
    @ViewBuilder
    private var headline: some View {
        if hasLine {
            Text("Your number")
                .font(RFont.display(28, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("What do you need?")
                .font(RFont.display(28, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // ⚠️ There is no `sectionHeader` any more (2026-09-21). It rendered
    // "Pick one" / "Need something else?" directly above the card stack —
    // whose own first element is now the grid's "Get a code for" — so BOTH
    // states drew two headers in a row with nothing between them. Caught in
    // the simulator, not by reading the code, which is the argument for
    // capturing a frame of any screen whose sections you reorder.
    //
    // "Get a code for" does the separating work on its own, and it is the more
    // specific of the two. Do not reinstate an outer label: for a new user it
    // restates the headline ("What do you need?"), and for a subscriber the
    // tinted line card above is already a visual boundary.

    // MARK: - The line dashboard

    /// What is waiting on the rented number, and the two ways into it.
    ///
    /// Counts only — no message previews and no caller numbers. This screen is
    /// a signpost, and a preview here would be a second rendering of content
    /// `LineScreen` owns, free to disagree with it.
    private func lineCard(_ line: Line) -> some View {
        HeroCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(verbatim: PhoneFormat.national(line.e164))
                    .font(RFont.display(22, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(theme.text)

                lineStatus
                    .font(RFont.text(13))
                    .foregroundStyle(theme.text2)

                HStack(spacing: 10) {
                    PrimaryButton(label: "Messages") {
                        track("line_messages")
                        state.tab = .line
                    }
                    // 🔴 HIDDEN, never disabled, when no voice client is
                    // attached. A disabled button still advertises the
                    // feature, and on a build without the SDK that is a
                    // promise the app cannot keep. Same rule as
                    // `LineScreen.actionFAB`.
                    if calling.isVoiceAvailable {
                        GhostButton(label: "Call", fillsWidth: false) {
                            track("line_call")
                            state.flow = .dialer
                        }
                    }
                }
            }
            .padding(18)
        }
    }

    /// Unread texts and missed calls, as whole sentences per count.
    ///
    /// Written as complete literals rather than an interpolated noun: a
    /// pluralised word dropped into a sentence cannot be translated, because
    /// German and the Romance languages inflect what surrounds it.
    @ViewBuilder
    private var lineStatus: some View {
        let unread = state.lineUnreadCount
        let missed = state.lineCalls.filter {
            $0.direction == .inbound && $0.status.isMissed
        }.count

        if unread == 0 && missed == 0 {
            Text("No new messages")
        } else if missed == 0 {
            if unread == 1 { Text("1 new message") } else { Text("\(unread) new messages") }
        } else if unread == 0 {
            if missed == 1 { Text("1 missed call") } else { Text("\(missed) missed calls") }
        } else if unread == 1 && missed == 1 {
            Text("1 new message · 1 missed call")
        } else if unread == 1 {
            Text("1 new message · \(missed) missed calls")
        } else if missed == 1 {
            Text("\(unread) new messages · 1 missed call")
        } else {
            Text("\(unread) new messages · \(missed) missed calls")
        }
    }

    // MARK: - The need-cards

    // ⚠️ There is no `smsCard` any more (2026-09-21). "A code for an app" was
    // folded into `serviceGrid` — see the note in `body`. Do not restore it:
    // a second route to Temp that selects no service is exactly the redundant
    // decision the fold removed, and it sent the user on a `ServiceSheet` trip
    // the tiles make unnecessary. The "my app isn't here" case is the More tile.

    private var emailCard: some View {
        needCard(icon: "envelope",
                 title: Text("A throwaway email"),
                 sub: Text("An Outlook or Hotmail address you use once.")) {
            track("email")
            state.emailMode = true
            state.tab = .temp
        }
    }

    private var numberCard: some View {
        needCard(icon: RIcon.phone,
                 title: Text("A number that's yours"),
                 // Verbatim from `LineStoreScreen` so the 13 translations it
                 // already carries apply here too.
                 sub: Text("A real American or Canadian number for your calls, texts and codes."),
                 price: { price },
                 extra: { numberChips }) {
            track("line")
            state.tab = .line
        }
    }

    /// What the subscription actually buys, in three words the price line does
    /// not carry.
    ///
    /// Decorative for VoiceOver (`accessibilityHidden`): the row is one Button
    /// and its label already names the product and its price, so reading three
    /// more nouns after it lengthens the announcement without adding a choice.
    /// The card's own sub-line is the accessible version of this.
    private var numberChips: some View {
        HStack(spacing: 6) {
            getChip(RIcon.phone, Text("Calls"))
            getChip(RIcon.message, Text("Texts"))
            getChip("envelope", Text("App codes"))
        }
        .padding(.top, 4)
        .accessibilityHidden(true)
    }

    private func getChip(_ icon: String, _ label: Text) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
            label
                .font(RFont.text(12, weight: .semibold))
        }
        .foregroundStyle(theme.text2)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(theme.chipBg, in: .capsule)
    }

    /// 🔴 STOREKIT OR NOTHING. Never a literal price: the store charges by
    /// storefront, and an intro offer disappears for an Apple ID that has
    /// already used one. Until StoreKit answers the card carries no price line
    /// at all, which is the only honest empty state.
    @ViewBuilder
    private var price: some View {
        if let intro = subs.monthlyIntroPriceDisplay {
            Text("\(intro) first month")
        } else if let monthly = subs.monthlyPriceDisplay {
            Text("\(monthly) a month")
        }
    }

    /// One row: what you might need, in the user's words, and where it goes.
    ///
    /// The whole row is the target, and nothing is combined: the row is a
    /// plain `Button`, so VoiceOver already reads it as ONE element carrying
    /// the button trait. See the note on the modifier list below.
    private func needCard<Price: View, Extra: View>(
        icon: String,
        title: Text,
        sub: Text,
        @ViewBuilder price: () -> Price = { EmptyView() },
        @ViewBuilder extra: () -> Extra = { EmptyView() },
        action: @escaping () -> Void
    ) -> some View {
        Button {
            RHaptic.select()
            action()
        } label: {
            Card(radius: RRadius.md, elevation: .flat,
                 fill: theme.elev, border: theme.sep) {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .frame(width: 36, height: 36)
                        .background(theme.inkSoft, in: .rect(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        title
                            .font(RFont.text(16, weight: .semibold))
                            .foregroundStyle(theme.text)
                        sub
                            .font(RFont.text(13))
                            .foregroundStyle(theme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                        price()
                            .font(RFont.text(13, weight: .semibold))
                            .foregroundStyle(theme.ink)
                        extra()
                    }
                    Spacer(minLength: 0)
                    Image(systemName: RIcon.chev)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.text3)
                }
                .padding(14)
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
        }
        // No `.accessibilityElement(children: .combine)`: a Button already
        // exposes ONE element built from its label, and combining on top of it
        // can drop the `.isButton` trait — announcing the row as static text.
        // The whole row stays the tap target through `.contentShape` above.
        .buttonStyle(PressScaleStyle(scale: 0.99))
    }

    // MARK: - The service grid

    /// Seven logos in a fixed order, then More.
    ///
    /// 🔴 **The order is a STATIC demand list, not a ranking, and the tiles
    /// carry no rate.** Anything sorted by a delivery figure would be this
    /// app steering a user onto inventory, and the standing rule is that a
    /// pick the APP makes is judged by a different bar than a list the user
    /// scrolls — see `rankedUntestedKey`. These are the seven services users
    /// actually arrive asking for; the grid is a shortcut past the picker,
    /// not a recommendation.
    ///
    /// A tap is the **user's own pick**: it goes through
    /// `AppState.commitServicePick`, the same path `ServiceSheet.onPick` uses,
    /// so `needsServiceChoice` clears and the order stops being a
    /// `from_default` one. It deliberately does NOT choose a country — the
    /// user's own country selection survives, and `commitServicePick` only
    /// relocates it when the picked service has no route where they are
    /// standing (`pickDestination`, which is also what the picker rows print).
    ///
    /// A featured id missing from the catalog is skipped silently. The list is
    /// a hardcoded seven against a 468-service catalog, so a service that is
    /// renamed or retired must degrade to six tiles rather than to a hole.
    private var serviceGrid: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(label: String(localized: "Get a code for"))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8),
                                     count: 4),
                      spacing: 8) {
                ForEach(featuredServices) { service in
                    GridTile(label: Text(verbatim: Self.tileLabel(service))) {
                        RHaptic.select()
                        Analytics.shared.track("service_selected", [
                            "service": .string(service.id),
                            "source": .string("home"),
                        ])
                        state.commitServicePick(service)
                        state.emailMode = false
                        state.tab = .temp
                    } icon: {
                        ServiceLogo(service: service, size: 38, radius: 11)
                    }
                }
                GridTile(label: Text("More")) {
                    RHaptic.select()
                    track("more_services")
                    state.emailMode = false
                    state.tab = .temp
                    openServices()
                } icon: {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(theme.text2)
                        .frame(width: 38, height: 38)
                        .background(theme.chipBg, in: .rect(cornerRadius: 11))
                }
            }
        }
    }

    /// One pass over the catalog, not seven `first(where:)` scans.
    ///
    /// `AppState` is `@Observable` and this screen redraws on every collection
    /// it reads, so anything walking `services` runs on each redraw — the same
    /// cost that made `esimCountries` a stored property rather than a computed
    /// one. Seven linear scans over 468 services is ~3,300 comparisons per
    /// redraw; this is 468, and it keeps the demand order rather than the
    /// catalog's.
    private var featuredServices: [Service] {
        let wanted = Set(Self.featuredServiceIds)
        var found: [String: Service] = [:]
        found.reserveCapacity(wanted.count)
        for service in state.services where wanted.contains(service.id) {
            found[service.id] = service
        }
        return Self.featuredServiceIds.compactMap { found[$0] }
    }

    private static let featuredServiceIds = [
        "whatsapp", "telegram", "instagram", "google", "tiktok", "discord", "tinder",
    ]

    /// The ONE product word for a tile, not the catalog's full name.
    ///
    /// Several catalog names list every product behind one route — `google` is
    /// published as **"Google / YouTube / Gmail"** — because the picker rows,
    /// which are full-width and searchable, want all of them. A 4-up tile is
    /// ~80pt wide and cannot show that: it shrank to the `minimumScaleFactor`
    /// floor and truncated anyway, so the tile read "Google / YouTub…" while
    /// its six neighbours read one clean word.
    ///
    /// Taking the first segment is a DISPLAY choice local to this grid. It
    /// never touches the tap — that still commits the whole `Service` — and it
    /// is not localized (`Text(verbatim:)`) because these are brand names.
    /// `lineLimit(1)` stays on the tile as the backstop for a first segment
    /// that is itself long.
    private static func tileLabel(_ service: Service) -> String {
        let head = service.name.split(separator: "/", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return head.isEmpty ? service.name : head
    }

    // MARK: - Recent, or how it works

    /// A user with history gets their history; a user without gets the
    /// explanation.
    ///
    /// The two are the same slot on purpose. "How it works" is dead weight to
    /// anyone who has already bought a code, and an empty Recent card is the
    /// state a first-run screen must never render — the whole reason this tab
    /// exists is that a new user could not tell what the app was for.
    @ViewBuilder
    private var recentOrHowItWorks: some View {
        if hasHistory { recent } else { howItWorks }
    }

    /// Collapsed by default (owner decision, 2026-09-21).
    ///
    /// Three numbered steps explaining a flow the user has not started is the
    /// same mistake `DeliveryInfoSheet` makes at the top of the Temp tab —
    /// teaching before being asked. It stays on the screen because a first-run
    /// user genuinely may not know what the app is for, but it stays SHUT, so
    /// the cost of carrying it is one row rather than a third of the scroll.
    ///
    /// ⚠️ Deliberately NOT persisted. This is a disclosure, not a preference:
    /// re-collapsing on the next launch is correct, because by then the user
    /// has either read it or stopped needing it. A `PrefKey` here would be a
    /// device-global flag to maintain forever for a row that costs one tap.
    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                RHaptic.select()
                withAnimation(RMotion.content) { howItWorksOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    SectionHeader(label: String(localized: "How it works"))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.text3)
                        .rotationEffect(.degrees(howItWorksOpen ? 0 : -90))
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("How it works"))
            .accessibilityHint(Text(howItWorksOpen ? "Collapse" : "Expand"))

            if howItWorksOpen {
                howItWorksSteps
            }
        }
    }

    private var howItWorksSteps: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HowStep(number: 1,
                        title: Text("Pick the app and a country."),
                        sub: Text("Any app that texts you a code."))
                HowStep(number: 2,
                        title: Text("Paste the number into that app."),
                        sub: Text("Yours for the whole wait."))
                // 🔴 Verbatim from the Onboarding promises card so both
                // surfaces resolve the SAME catalog key. It says the credits
                // COME BACK, never that nothing is charged: credits are
                // deducted at order time and returned on every terminal path,
                // and this is the only line on Home that states a money
                // outcome. `TempScreen.refundPromise` says the same thing with
                // the window in it; a How-it-works sub-line has no room for a
                // number, and a number here would be a second copy to drift.
                HowStep(number: 3,
                        title: Text("The code lands here."),
                        sub: Text("Credits come back when no code arrives"))
            }
            .padding(.horizontal, 4)
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(label: String(localized: "Recent"))
            Card(radius: 24, elevation: .flat, fill: theme.elev, border: theme.sep) {
                VStack(spacing: 0) {
                    let items = recentItems
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        switch item {
                        case .sms(let order):
                            recentSmsRow(order, isLast: idx == items.count - 1)
                        case .email(let mail):
                            recentEmailRow(mail, isLast: idx == items.count - 1)
                        }
                    }
                }
            }
        }
    }

    /// Both products, newest first, capped at three.
    ///
    /// The cap is what keeps this a signpost rather than a second Orders
    /// screen: three rows is enough to answer "did my code arrive?" without
    /// this tab growing a history surface that then has to stay in step with
    /// the real one.
    ///
    /// 🔴 **Each list is trimmed BEFORE the merge, not after.** `OrdersAPI`
    /// sends no `limit`, so `state.orders` is the user's ENTIRE history, and
    /// this screen is `@Observable`-driven — it re-evaluates on every
    /// collection it reads. Merging first meant allocating two full arrays of
    /// wrappers, sorting all of them, and ISO-parsing every e-mail row's
    /// `created_at` on each redraw, to keep three. Both endpoints already
    /// return `created_at.desc`, so the newest three of each list necessarily
    /// contain the newest three of the union — the merge only has to decide
    /// how those six interleave. Same reason `featuredServices` walks the
    /// catalog once instead of seven times.
    ///
    /// ⚠️ **That rests on both lists being newest-first, which is an
    /// invariant of `AppState`, not of this file.** Verified 2026-09-10:
    /// `OrdersAPI.list` and `EmailAPI.list` both send
    /// `order=created_at.desc`, and every local mutation is an
    /// `insert(_, at: 0)` — never an append. If a list ever gains a row at the
    /// end, this trim silently drops the newest orders instead of the oldest.
    private var recentItems: [RecentItem] {
        let sms = state.orders.prefix(3).map(RecentItem.sms)
        let mail = state.emailOrders.prefix(3).map(RecentItem.email)
        return (sms + mail)
            .sorted { $0.sortDate > $1.sortDate }
            .prefix(3)
            .map { $0 }
    }

    /// Trailing edge, in the order that decides it: a code that EXISTS beats
    /// the status.
    ///
    /// Same rule as `AppState.openOrder` and `ServerEmailOrder.hasCode` — a
    /// late-code rescue writes `otp` onto a CANCELED row, and gating the code
    /// on `status == .received` is exactly how a delivered code became
    /// invisible in the one place it was stored.
    private func recentSmsRow(_ order: Order, isLast: Bool) -> some View {
        RecentRow(
            subtitle: order.status == .waiting
                ? Text("Waiting for the code")
                : Text("\(Self.age(order.createdAt)) · \(Self.smsStatusWord(order))"),
            isLast: isLast,
            action: {
                track("recent_sms")
                state.openOrder(order)
            },
            leading: { ServiceLogo(service: order.service, size: 40, radius: 12) },
            title: {
                HStack(spacing: 6) {
                    Text(verbatim: order.service.name)
                        .font(RFont.text(15, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    FlagImage(country: order.country, size: 16, radius: 5)
                }
            },
            trailing: {
                if let otp = order.otp {
                    Text(verbatim: otp)
                        .font(RFont.mono(16, weight: .semibold))
                        .foregroundStyle(theme.text)
                } else if order.status == .waiting {
                    LivePill()
                } else {
                    Text("Get another")
                        .font(RFont.text(13, weight: .semibold))
                        .foregroundStyle(theme.ink)
                }
            })
    }

    /// A Button ONLY when the tap leads somewhere — `emailDestination`
    /// returns nil for a terminal codeless row, and a row that presses like a
    /// button and then does nothing reads as a broken app. Mirrors
    /// `OrdersScreen.emailTap`.
    private func recentEmailRow(_ mail: ServerEmailOrder, isLast: Bool) -> some View {
        let destination = state.emailDestination(for: mail)
        return RecentRow(
            subtitle: Self.emailSubtitle(mail),
            isLast: isLast,
            action: destination.map { dest in
                {
                    track("recent_email")
                    state.openEmailOrder(mail, dest)
                }
            },
            leading: {
                Image(systemName: "envelope")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.text2)
                    .frame(width: 40, height: 40)
                    .background(theme.chipBg, in: .rect(cornerRadius: 12))
            },
            title: {
                Text(verbatim: mail.domain)
                    .font(RFont.text(15, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
            },
            trailing: {
                if mail.hasCode, let code = mail.code {
                    Text(verbatim: code)
                        .font(RFont.mono(16, weight: .semibold))
                        .foregroundStyle(theme.text)
                } else if mail.status == .waiting {
                    LivePill()
                }
            })
    }

    /// Age plus the status word, or the status word alone when the row carries
    /// no parseable timestamp.
    ///
    /// The words are `EmailOrderRow`'s, verbatim, so the two surfaces share
    /// catalog keys and cannot come to describe the same row differently. An
    /// unparseable `created_at` falls back to the word rather than to
    /// `.distantPast`, which would render "56 years ago".
    private static func emailSubtitle(_ mail: ServerEmailOrder) -> Text {
        let word = emailStatusWord(mail)
        guard let created = parseCreatedAt(mail.createdAt) else {
            return Text(verbatim: word)
        }
        return Text("\(age(created)) · \(word)")
    }

    /// Exactly `StatusBadge`'s vocabulary — the words `OrderRow` already shows
    /// for the same order on the Orders tab — so the two surfaces cannot come
    /// to describe one order differently. The e-mail half of this card does
    /// the same against `EmailOrderRow`; a settled row that named its age and
    /// nothing else was the odd one out, and "2 hours ago" beside a
    /// "Get another" button never said what actually happened.
    ///
    /// A code that EXISTS beats the status, the same rule as the trailing edge
    /// and as `emailStatusWord`: a late-code rescue writes `otp` onto a
    /// CANCELED row, and calling that row "Canceled" while the code sits next
    /// to it is the same lie one column over.
    private static func smsStatusWord(_ order: Order) -> String {
        if order.otp != nil { return String(localized: "Received") }
        switch order.status {
        case .waiting:  return String(localized: "Waiting")
        case .received: return String(localized: "Received")
        case .expired:  return String(localized: "Expired")
        case .refunded: return String(localized: "Refunded")
        case .canceled: return String(localized: "Canceled")
        }
    }

    /// Exactly `EmailOrderRow.statusPill`'s vocabulary. `hasCode` decides,
    /// never `status == .received` — a code can land on a row the provider
    /// already closed.
    private static func emailStatusWord(_ mail: ServerEmailOrder) -> String {
        if mail.hasCode { return String(localized: "Code received") }
        switch mail.status {
        case .waiting:  return String(localized: "Waiting")
        case .expired:  return String(localized: "Expired")
        case .canceled: return String(localized: "Canceled")
        case .failed:   return String(localized: "Failed")
        case .received: return String(localized: "Code received")
        }
    }

    /// `dateTimeStyle = .named` ("yesterday", "2 hours ago") rather than
    /// `Order.ago`'s abbreviated form: this is a three-row signpost with room
    /// for words, where the Orders list is a dense column that needs "2h".
    ///
    /// ⚠️ `.named` is a `dateTimeStyle`, NOT a `unitsStyle` — the units enum
    /// has no such case and the two are set independently.
    private static func age(_ date: Date) -> String {
        relativeNamed.localizedString(for: date, relativeTo: Date())
    }

    private static let relativeNamed: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.dateTimeStyle = .named
        f.unitsStyle = .full
        return f
    }()

    /// ⚠️ The same two-formatter parse as `OrdersScreen.HistoryItem.sortDate`,
    /// which is private to that file. PostgREST emits `timestamptz` WITH
    /// fractional seconds, which a default `ISO8601DateFormatter` REJECTS — so
    /// a single plain formatter returns nil for every real row, and a
    /// minutes-old activation sorts to the bottom, i.e. it looks like the
    /// order vanished. Static, because a formatter per comparison per body
    /// evaluation is real cost.
    private static func parseCreatedAt(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return isoFrac.date(from: raw) ?? iso.date(from: raw)
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    /// One row of Recent, from either product.
    private enum RecentItem: Identifiable {
        case sms(Order)
        case email(ServerEmailOrder)

        // Prefixed so an SMS id and an email id can never collide in a ForEach.
        var id: String {
            switch self {
            case .sms(let o):   "sms-\(o.id)"
            case .email(let e): "email-\(e.id)"
            }
        }
        var sortDate: Date {
            switch self {
            case .sms(let o):   o.createdAt
            // distantPast keeps an unparseable timestamp at the bottom rather
            // than at "now".
            case .email(let e): HomeScreen.parseCreatedAt(e.createdAt) ?? .distantPast
            }
        }
    }


    /// One event, one prop, one vocabulary:
    /// `email | line | line_messages | line_call | credits | more_services |
    ///  recent_sms | recent_email`.
    ///
    /// ⚠️ **Three arms left this screen on 2026-09-21 and the series is
    /// deliberately NOT renamed.** `sms` is gone because its card was folded
    /// into the grid — that intent now arrives as
    /// `service_selected{source:"home"}` or `more_services`. `invite`, `vroam`
    /// and `vroam_dismissed` still fire, from `AccountScreen`, under this same
    /// event name so the existing series continues rather than restarting at
    /// zero. So from this release those three arms mean the ACCOUNT tab, not
    /// Home — the same kind of documented lie as `TempScreen`'s
    /// `source: "home"`, which has meant the Temp tab since 2026-09-10. Read a
    /// step change in any of the four as THIS, not as behaviour moving.
    private func track(_ card: String) {
        Analytics.shared.track("home_card_tapped", ["card": .string(card)])
    }
}

// MARK: - Pieces

/// One tile in the service grid, or the More tile that follows them.
///
/// Generic over its icon so a `ServiceLogo` and an SF Symbol share one tile
/// definition — two near-identical tile bodies is how a grid ends up with one
/// cell a different height from the rest.
private struct GridTile<Icon: View>: View {
    @Environment(\.theme) private var theme
    let label: Text
    let action: () -> Void
    @ViewBuilder let icon: Icon

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                icon
                label
                    .font(RFont.text(12, weight: .semibold))
                    .foregroundStyle(theme.text2)
                    // Backstop only. The caller is expected to hand over one
                    // product word (`HomeScreen.tileLabel`); this keeps a long
                    // one on a single line, and the inset keeps the ellipsis
                    // off the tile's hairline rather than running into it.
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
            .padding(.bottom, 12)
            .background(theme.elev, in: .rect(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(theme.sep, lineWidth: 1)
            }
            .contentShape(.rect(cornerRadius: 18))
        }
        .pressable()
    }
}

/// One numbered step of "How it works".
private struct HowStep: View {
    @Environment(\.theme) private var theme
    let number: Int
    let title: Text
    let sub: Text

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: "\(number)")
                .font(RFont.text(13, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(theme.ink)
                .frame(width: 28, height: 28)
                .background(theme.inkSoft, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(RFont.text(15, weight: .semibold))
                    .foregroundStyle(theme.text)
                sub
                    .font(RFont.text(13))
                    .foregroundStyle(theme.text2)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        // One element per step: the digit is ordinal decoration, and read on
        // its own it announces "1" before the sentence it belongs to.
        .accessibilityElement(children: .combine)
    }
}

/// One row of the Recent group — a Button only when the tap leads somewhere.
///
/// Both products share this chrome so the two rows cannot drift to different
/// heights or divider insets. Same `onTap == nil` rule as `OrderRow` and
/// `EmailOrderRow`: a row that presses and then does nothing reads as broken.
private struct RecentRow<Leading: View, Title: View, Trailing: View>: View {
    @Environment(\.theme) private var theme
    let subtitle: Text
    var isLast: Bool
    var action: (() -> Void)?
    @ViewBuilder let leading: Leading
    @ViewBuilder let title: Title
    @ViewBuilder let trailing: Trailing

    var body: some View {
        if let action {
            Button {
                RHaptic.select()
                action()
            } label: {
                content
            }
            .pressable()
        } else {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                leading
                VStack(alignment: .leading, spacing: 2) {
                    title
                    subtitle
                        .font(RFont.text(13))
                        .foregroundStyle(theme.text2)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                trailing
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(.rect)

            if !isLast {
                Rectangle().fill(theme.sep).frame(height: 0.5)
            }
        }
    }
}

/// "Live" — a running order, in the semantic success colour.
///
/// `theme.live`, not `theme.ink`: green here means "this is happening", which
/// is the same claim the waiting screen makes. The accent is the brand and
/// says nothing about state.
private struct LivePill: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Text("Live")
            .font(RFont.text(12, weight: .semibold))
            .foregroundStyle(theme.live)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(theme.liveSoft, in: .capsule)
    }
}
