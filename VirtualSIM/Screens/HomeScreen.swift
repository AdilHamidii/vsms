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

                if hasLine, let line = state.line {
                    lineCard(line)
                        .padding(.horizontal, 16)
                        .padding(.top, 18)
                        .riseIn(appeared, index: 1)
                }

                sectionHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 26)
                    .riseIn(appeared, index: 2)

                VStack(spacing: 10) {
                    ForEach(productOrder, id: \.self) { tab in
                        switch tab {
                        case .temp:
                            smsCard
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
                .riseIn(appeared, index: 3)

                serviceGrid
                    .padding(.horizontal, 16)
                    .padding(.top, 26)
                    .riseIn(appeared, index: 4)

                recentOrHowItWorks
                    .padding(.horizontal, 16)
                    .padding(.top, 26)
                    .riseIn(appeared, index: 5)

                inviteCard
                    .padding(.horizontal, 16)
                    .padding(.top, 26)
                    .riseIn(appeared, index: 6)
            }
            .padding(.top, 8)
            // The tab bar floats over the content, as on every other tab.
            .padding(.bottom, 140)
        }
        .scrollIndicators(.hidden)
        .onAppear {
            guard !tracked else { return }
            tracked = true
            Analytics.shared.track("home_view", [
                "has_line": .bool(hasLine),
                "has_orders": .bool(hasHistory),
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
        .accessibilityLabel(Text("Set your name"))
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

    /// Same reason as `headline`: two literals, not a ternary.
    @ViewBuilder
    private var sectionHeader: some View {
        if hasLine {
            SectionHeader(label: String(localized: "Need something else?"))
        } else {
            SectionHeader(label: String(localized: "Pick one"))
        }
    }

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

    private var smsCard: some View {
        needCard(icon: RIcon.message,
                 title: Text("A code for an app"),
                 sub: Text("A temporary number that receives one code.")) {
            track("sms")
            state.emailMode = false
            state.tab = .temp
        }
    }

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
                    GridTile(label: Text(verbatim: service.name)) {
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

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(label: String(localized: "How it works"))
            VStack(alignment: .leading, spacing: 14) {
                HowStep(number: 1,
                        title: Text("Pick the app and a country."),
                        sub: Text("Any app that texts you a code."))
                HowStep(number: 2,
                        title: Text("Paste the number into that app."),
                        sub: Text("Yours for the whole wait."))
                HowStep(number: 3,
                        title: Text("The code lands here."),
                        sub: Text("No code, no charge."))
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
    private var recentItems: [RecentItem] {
        (state.orders.map(RecentItem.sms) + state.emailOrders.map(RecentItem.email))
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
                : Text(verbatim: Self.age(order.createdAt)),
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

    // MARK: - Invite

    /// Rendered only when there is genuinely a code to share.
    ///
    /// Both halves are checked because they fail independently: `inviteMessage`
    /// is nil without a referral code, and a card showing a code with no way to
    /// send it — or a Share button with nothing in it — is worse than no card.
    /// `AccountScreen.codeBlock` carries the loading and error states; this is
    /// a secondary surface and simply says nothing until the profile lands.
    @ViewBuilder
    private var inviteCard: some View {
        if let message = state.inviteMessage, let code = state.profile?.referralCode {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Invite a friend")
                        .font(RFont.text(16, weight: .bold))
                        .foregroundStyle(theme.text)
                    // 🔴 Verbatim from `AccountScreen.invite` so both surfaces
                    // resolve the SAME catalog key — and so the two credit
                    // amounts stay server-derived in one place. Never retype
                    // this sentence with the numerals in it.
                    Text("Share your code. A friend who joins with it starts with **\(AppState.inviteJoinerCredits) free credits**, and you get **5 credits** when they buy their first pack.")
                        .font(RFont.text(14))
                        .lineSpacing(2)
                        .foregroundStyle(theme.text2)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Text(verbatim: code)
                            .font(RFont.mono(16, weight: .semibold))
                            .foregroundStyle(theme.text)
                            .padding(.horizontal, 14)
                            .frame(height: 46)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.chipBg, in: .rect(cornerRadius: RRadius.sm))

                        ShareLink(item: message) {
                            HStack(spacing: 6) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Share")
                                    .font(RFont.display(14, weight: .semibold))
                                    .tracking(-0.2)
                            }
                            .foregroundStyle(theme.onInk)
                            .padding(.horizontal, 16)
                            .frame(height: 46)
                            .background(theme.ink, in: .rect(cornerRadius: RRadius.sm))
                        }
                        // ShareLink owns its own tap, so the event rides
                        // alongside it rather than replacing it — a plain
                        // `.onTapGesture` here would swallow the share.
                        .simultaneousGesture(TapGesture().onEnded {
                            track("invite")
                        })
                    }
                }
                .padding(18)
            }
        }
    }

    /// One event, one prop, one vocabulary:
    /// `sms | email | line | line_messages | line_call | credits |
    ///  more_services | recent_sms | recent_email | invite`.
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    // Catalog names are not all short — `google` is published
                    // as "Google / YouTube / Gmail" — so a long one truncates.
                    // The inset keeps the ellipsis off the tile's hairline
                    // rather than letting the text run into the border.
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
