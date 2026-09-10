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
/// rebuilt here. In particular there is **no inbox, no order list and no
/// waiting-order card** — `ResumeBar` already floats above the tab bar on
/// every tab, so a second copy of a live order here would be a second place
/// for it to go stale.
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

    var openCredits: () -> Void = {}

    @State private var appeared = false
    /// `home_view` is once per APPEARANCE, not once per body evaluation.
    /// `AppState` is `@Observable` and this screen reads several of its
    /// collections, so an ungated `track` in `body` would fire on every
    /// redraw and make the one number this event answers meaningless.
    @State private var tracked = false

    /// The card order, resolved into a stored property when the view is
    /// initialised — once per `HomeScreen` init, not per body evaluation —
    /// the same rule, and the same reason, as `TabBar.items`: `AppState` is
    /// `@Observable` and this screen redraws on every collection it reads, so
    /// a computed order would hit UserDefaults on each redraw. The UserDefaults
    /// key is only ever written by `refreshAppStatus`, which runs after the
    /// reveal, so the order cannot change under the user within one appearance.
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
            }
            .padding(.top, 8)
            // The tab bar floats over the content, as on every other tab.
            .padding(.bottom, 140)
        }
        .scrollIndicators(.hidden)
        .onAppear {
            guard !tracked else { return }
            tracked = true
            Analytics.shared.track("home_view", ["has_line": .bool(hasLine)])
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

    /// Eyebrow names the outcome; the headline asks the question the screen
    /// exists to answer, or names what the user already owns.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                MicroLabel("Your numbers and codes, in one place").lineLimit(2)
                Spacer(minLength: 0)
                CreditPill(value: state.balance, action: {
                    track("credits")
                    openCredits()
                })
            }
            headline
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
                 price: { price }) {
            track("line")
            state.tab = .line
        }
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
    private func needCard<Price: View>(
        icon: String,
        title: Text,
        sub: Text,
        @ViewBuilder price: () -> Price = { EmptyView() },
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

    /// One event, one prop, one vocabulary:
    /// `sms | email | line | line_messages | line_call | credits`.
    private func track(_ card: String) {
        Analytics.shared.track("home_card_tapped", ["card": .string(card)])
    }
}
