import Combine
import SwiftUI

/// The code arrived. The whole job of this screen is to get those digits into
/// the other app and then get out of the way.
///
/// It used to have no way out at all except the ✕ in the corner — while
/// `EmailCodeScreen`, the same moment one product line over, has a Done
/// primary. And the second thing under the code, above anything telling the
/// user what to do with it, was **"Get another \(service) number"**: an upsell
/// offered at the instant of success, before the success has been used. The
/// order is now Copy → what to do with it → Done, and the two "what next"
/// affordances sit BELOW Done where they belong.
struct OtpScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    @Environment(IAPStore.self) private var iap

    let order: Order
    @State private var copied = false
    @State private var appeared = false
    @State private var showCredits = false
    /// One `line_upsell_shown` per presentation — see `keepNumberCard`.
    @State private var upsellLogged = false
    /// The order as last read from the server. `order` is a snapshot taken when
    /// this cover was presented, so a second code promoted onto the row while
    /// the screen is open would never appear without re-reading it.
    @State private var live: Order?
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Everything on this screen reads through here, never `order` directly.
    private var current: Order { live ?? order }

    private var otpValue: String { current.otp ?? "" }
    private var otpDigits: [String] { otpValue.map { String($0) } }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    topBar
                    serviceStrip
                    codeCard
                    resendNotice
                    messageBubble
                    earlierCodes
                    balanceCard
                    keepNumberCard
                    whatNext
                }
                .padding(.top, 6)
                .padding(.bottom, 60)
            }
            .scrollIndicators(.hidden)
        }
        .onAppear(perform: arrive)
        .onReceive(tick) { now = $0 }
        .task(id: order.id) {
            // Only while a window is actually open — an ineligible pool must
            // never generate polling traffic. Ten seconds against a five-minute
            // window is ~30 reads worst case, and it stops the moment the
            // window lapses or the screen goes away.
            while !Task.isCancelled,
                  let until = current.resendWatchUntil, until > Date() {
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { return }
                guard let fresh = try? await OrdersAPI(client: api)
                    .fetch(orderId: order.id) else { continue }
                live = Order(server: fresh, service: order.service,
                             country: order.country)
            }
        }
        // Presented from HERE rather than routed through ContentView because
        // this screen is a fullScreenCover, and a cover's content does not
        // reliably inherit @Observable environment objects — the same reason
        // ContentView wraps every cover. CreditsSheet reads exactly these four,
        // so they are injected explicitly.
        .sheet(isPresented: $showCredits) {
            CreditsSheet(balance: state.balance, needed: shortfall) {
                await state.refreshWallet(using: WalletAPI(client: api))
                if let n = iap.lastGrantedCredits, n > 0 {
                    state.creditPurchaseBanner = n
                }
            }
            .environment(\.theme, theme)
            .environment(state)
            .environment(api)
            .environment(iap)
            .presentationDragIndicator(.visible)
            .presentationBackground(theme.bg)
        }
    }

    /// Everything that should happen the moment the digits are on screen.
    ///
    /// **The code is copied for the user.** It is a verification code with one
    /// use and one destination; making someone tap a button to move six digits
    /// they are about to paste is ceremony, not consent. The Copy button stays
    /// (the clipboard can be overwritten between here and the other app, and
    /// the button is the only way back) — it simply opens already confirmed.
    private func arrive() {
        guard !appeared else { return }
        appeared = true
        guard !otpValue.isEmpty else { return }
        // The service only — never the code, the number, or the order id.
        Analytics.shared.track("code_received",
                               ["service": .string(order.service.id)])

        UIPasteboard.general.string = otpValue
        copied = true
        // The screen the product exists for. A silent success on iOS reads as a
        // screen that did not respond.
        RHaptic.success()

        Task {
            // Return the button to its resting label so it stays usable rather
            // than sitting on a stale "Copied" for the life of the screen.
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            withAnimation(RMotion.content) { copied = false }
        }
    }

    private var topBar: some View {
        HStack {
            Color.clear.frame(width: 36, height: 36)
            Spacer()
            Text("Code received")
                .font(RFont.display(16, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(theme.text)
            Spacer()
            Button {
                state.finishOtp()
            } label: {
                Image(systemName: RIcon.close)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text2)
                    .frame(width: 36, height: 36)
                    .background(theme.chipBg, in: .circle)
            }
            .pressable()
        }
        .padding(.horizontal, 16)
    }

    private var serviceStrip: some View {
        HStack(spacing: 10) {
            ServiceLogo(service: order.service, size: 32, radius: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(order.service.name)
                    .font(RFont.display(15, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(theme.text)
                HStack(spacing: 6) {
                    Text(order.country.flag).font(.system(size: 12))
                    MonoText(order.number, size: 12, color: theme.text2)
                }
            }
            Spacer()
            // Real status, not a hardcoded .received. A rescued code lands on
            // a CANCELED order (refund stands, code given away) — asserting
            // "received" there would contradict the history row and the refund.
            StatusBadge(status: order.status)
        }
        .padding(.horizontal, 20)
    }

    private var codeCard: some View {
        HeroCard {
            VStack(spacing: 0) {
                MicroLabel("Verification code")

                HStack(spacing: 10) {
                    ForEach(Array(otpDigits.enumerated()), id: \.offset) { idx, d in
                        OtpDigit(digit: d, idx: idx, style: state.otpAnimation)
                    }
                }
                .padding(.top, 16)

                PrimaryButton(
                    label: copied ? String(localized: "Copied") : String(localized: "Copy code"),
                    icon: copied ? RIcon.check : RIcon.copy,
                    action: copy
                )
                .padding(.top, 22)

                // The instruction, not an upsell. This is the slot the "get
                // another number" button used to occupy.
                Text("Paste it into \(order.service.name) to finish verifying.")
                    .font(RFont.text(13))
                    .foregroundStyle(theme.text2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)

                GhostButton(label: String(localized: "Done"), icon: RIcon.check) {
                    state.finishOtp()
                }
                .padding(.top, 14)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 26)
        }
        .padding(.horizontal, 16)
    }

    /// Tells the user, in the only terms that are true, how long the number can
    /// still receive another code.
    ///
    /// 🔴 THE CLOCK RESTARTS ON EVERY MESSAGE — five minutes from the LAST SMS,
    /// not a budget from the first. So this always renders the time left on the
    /// CURRENT deadline and never a fraction of a fixed total.
    ///
    /// Absent entirely when `resendWatchUntil` is nil: that means the pool
    /// cannot take a second SMS, and advertising one would be a promise the
    /// provider has not made.
    @ViewBuilder private var resendNotice: some View {
        if let until = current.resendWatchUntil, until > now {
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: RIcon.inbox)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(theme.text3)
                        MicroLabel("Need another code?")
                        Spacer(minLength: 0)
                        MonoText(timeLeft(Int(until.timeIntervalSince(now))),
                                 size: 12, color: theme.text2)
                    }
                    Text("Ask \(current.service.name) to send it again and it arrives on this same number.")
                        .font(RFont.text(13))
                        .foregroundStyle(theme.text2)
                }
            }
        }
    }

    /// mm:ss. Deliberately not RelativeDateTimeFormatter: "in 4 minutes" reads
    /// as an estimate, and this is a hard provider deadline.
    private func timeLeft(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Only once a second code has actually arrived. One code needs no list —
    /// it is already the thing filling the screen.
    @ViewBuilder private var earlierCodes: some View {
        let history = current.codeHistory
        if history.count > 1 {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    MicroLabel("Earlier codes")
                    ForEach(Array(history.dropFirst()), id: \.at) { entry in
                        MonoText(entry.code, size: 15, color: theme.text2)
                    }
                }
            }
        }
    }

    private var messageBubble: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: RIcon.inbox)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.text3)
                    // Only claim "RAW MESSAGE" when it really is one.
                    MicroLabel(hasRawMessage ? "Raw message" : "Code received")
                    Spacer(minLength: 0)
                    Text(arrivedAgo)
                        .font(RFont.text(11))
                        .foregroundStyle(theme.text3)
                }
                Text(rawMessageAttributed)
                    .lineSpacing(2)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - What it costs to do this again

    /// What another number on this exact route costs, live. nil when the route
    /// has no price right now, in which case we say nothing about cost at all
    /// rather than quoting a median as if it were this route's.
    private var nextCost: Int? {
        state.cost(for: order.service, country: order.country)
    }

    /// Credits still needed for another one. 0 when they can already afford it.
    private var shortfall: Int {
        guard let nextCost else { return 0 }
        return max(0, nextCost - state.balance)
    }

    /// The pack this button would land on, resolved exactly the way
    /// `CreditsSheet` does: the smallest BUYABLE pack that covers the
    /// shortfall, the largest when nothing does, and the sheet's own default
    /// (`md`) when there is no shortfall. Resolved here rather than guessed so
    /// the button and the sheet it opens cannot name different packs.
    ///
    /// ⚠️ Only ever a pack StoreKit has actually returned. `visiblePacks`
    /// mirrors the sheet's own filter: an `optional` pack whose review is
    /// still pending must not be offered on a button either.
    private var topUpPack: CreditPack? {
        guard iap.hasLoadedProducts else { return nil }
        let buyable = CreditPack.all.filter { iap.has($0) }
        guard !buyable.isEmpty else { return nil }
        guard shortfall > 0 else {
            return buyable.first { $0.id == "md" } ?? buyable.first
        }
        return buyable.first { $0.credits >= shortfall } ?? buyable.last
    }

    /// "+12 credits · $5.49". A bare "Top up credits" asked for money without
    /// naming an amount or a price, so the only way to learn either was to
    /// open the sheet.
    ///
    /// ⚠️ Falls back to the bare label whenever StoreKit has not answered.
    /// `IAPStore.displayPrice` returns a hardcoded USD fallback in that case,
    /// and a US dollar figure shown to a French buyer is exactly the drift
    /// this repo has already paid for — nothing price-related renders until
    /// the store has spoken.
    private var topUpLabel: String {
        guard let pack = topUpPack else {
            return String(localized: "Top up credits")
        }
        return String(localized: "+\(pack.credits) credits · \(iap.displayPrice(pack))")
    }

    /// The only moment the product has PROVED itself, and until now the app
    /// said nothing here about money.
    ///
    /// The measured shape of this business is that 27 of 28 buyers paid BEFORE
    /// they had any evidence the thing works, and with the signup grant at 0
    /// every new user reaches this screen holding a balance they have just
    /// spent to zero. So the one place we can ask having actually delivered was
    /// silent, and the only forward affordance was a 13pt grey link to a
    /// checkout they could not afford.
    ///
    /// Rules it deliberately keeps:
    ///  • It states the BALANCE, which is a fact, and the price of another
    ///    number on THIS route, which is a live catalog price. No estimate, no
    ///    "most people buy", no urgency.
    ///  • It is a secondary control below Done, not a second primary. Done is
    ///    still the action this screen is for; the code is what they came for.
    ///  • It renders ONLY when they cannot already afford another number.
    ///    Someone holding credits needs no top-up and gets no ask.
    ///  • It never touches the review prompt (App Store 5.6.4): nothing here is
    ///    conditioned on a review and the prompt fires from `arrive()` either
    ///    way.
    @ViewBuilder
    private var balanceCard: some View {
        if let nextCost, shortfall > 0 {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        CoinIcon(size: 16, color: theme.text2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("You have \(state.balance) credits left")
                                .font(RFont.text(14, weight: .semibold))
                                .foregroundStyle(theme.text)
                            Text("Another \(order.service.name) number in \(order.country.name) costs \(nextCost) credits.")
                                .font(RFont.text(12))
                                .foregroundStyle(theme.text2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }

                    GhostButton(label: topUpLabel,
                                icon: RIcon.plus) {
                        RHaptic.select()
                        // Declare the product before opening the sheet — the
                        // sheet's context card and its preselected pack are
                        // both sized from `intent`, and this screen can be
                        // reached with an e-mail or eSIM intent still set.
                        state.intent = .sms
                        showCredits = true
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - The rented line, sold where the product has just worked

    /// 🔴 **THE TWO PRODUCT LINES HAD NEVER ONCE OVERLAPPED, AND THIS SCREEN IS
    /// WHY.** Measured 2026-09-09: of **19 line subscribers all-time, 1 had
    /// ever placed a temp-SMS order and 0 had ever received a code**; over the
    /// prior 30 days **69 users watched a code land, 21 ever opened the number
    /// store, 0 subscribed.** Every subscriber this product has ever had
    /// arrived cold. `EmailCodeScreen` has sold the mail plan at the identical
    /// moment since 2.3; the number line had no equivalent anywhere, so the
    /// warmest audience in the app was simply never asked.
    ///
    /// ⚠️ **0 of 69 is NOT yet evidence that these users won't pay.** 48 of
    /// them never saw the offer at all. Read this at ~100 `line_upsell_shown`:
    /// if `line_upsell_tapped` is near zero, the audiences really are disjoint
    /// and the answer is to stop cross-selling, not to shout louder.
    ///
    /// Rules, inherited from `balanceCard` and `EmailCodeScreen.nextAddressCard`:
    ///  • **Below Done, and below the top-up ask.** Done is still what this
    ///    screen is for. An upsell ABOVE the code is exactly what was removed
    ///    from this screen once already — see the type's own doc.
    ///  • **Only when they have no live line.** A subscriber is asked nothing.
    ///  • **Only once `linesLoaded` has answered**, so the card cannot flash in
    ///    front of someone who already owns a number.
    ///  • **No price.** The figure is StoreKit's and it is stated on
    ///    `LineCheckoutScreen`; quoting it here would be a second place to
    ///    drift, and this is an invitation rather than a paywall.
    ///  • **Only claims that hold.** Inbound codes and texts from US/Canadian
    ///    senders are proven (`line_messages`, 21 of 21). Nothing about calls,
    ///    nothing about texting the rest of the world — those live on the
    ///    checkout ledger where they can be read before paying.
    ///  • It never touches the review prompt (App Store 5.6.4).
    ///
    /// ⚠️ Not gated on `lines_paused`: `AppStatus` does not carry that key, so
    /// no client surface reads it — the Number tab's store behaves the same
    /// way, and the server refuses with `lines_paused`, which `ErrorBanner`
    /// already renders. Add the field and gate all of them together, or none.
    @ViewBuilder
    private var keepNumberCard: some View {
        if showsKeepNumber {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: RIcon.phone)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.text2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("This number goes away when the timer runs out")
                                .font(RFont.text(14, weight: .semibold))
                                .foregroundStyle(theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("A number of your own keeps receiving codes and texts from US and Canadian senders, for as long as you keep it.")
                                .font(RFont.text(12))
                                .foregroundStyle(theme.text2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }

                    GhostButton(label: String(localized: "See numbers you can keep"),
                                icon: RIcon.phone) {
                        RHaptic.select()
                        Analytics.shared.track("line_upsell_tapped")
                        // Dismiss FIRST, then navigate. This screen is a
                        // `fullScreenCover`; the number store is a TAB, so
                        // leaving the cover up would hide the destination
                        // behind it. Same order `whatNext` already uses.
                        state.flow = nil
                        state.intent = .line
                        state.tab = .line
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .padding(.horizontal, 16)
            .onAppear {
                // Once per presentation, not per body evaluation — SwiftUI
                // re-runs this view for the 1-second timer tick, which would
                // otherwise log an impression every second the screen is open
                // and make the funnel read as enormous engagement.
                guard !upsellLogged else { return }
                upsellLogged = true
                Analytics.shared.track("line_upsell_shown")
            }
        }
    }

    private var showsKeepNumber: Bool {
        state.linesLoaded && !state.lines.contains { $0.status.isLive }
    }

    /// Everything that is about the NEXT thing rather than this one, kept
    /// below Done and rendered as quiet chrome.
    ///
    /// The invite lived only in a card in the 4th tab and produced exactly ZERO
    /// referrals across 146 users — a placement failure, not a demand failure,
    /// so it stays on this screen. It just no longer competes with the code.
    private var whatNext: some View {
        VStack(spacing: 4) {
            Button {
                state.flow = nil
                state.startCheckout(service: order.service, country: order.country)
            } label: {
                Text("Get another \(order.service.name) number")
                    .font(RFont.text(13, weight: .medium))
                    .foregroundStyle(theme.text2)
                    .padding(.vertical, 10)
            }
            .pressable()

            if let invite = state.inviteMessage {
                ShareLink(item: invite) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Invite a friend and they start with \(AppState.inviteJoinerCredits) credits")
                            .font(RFont.text(13, weight: .medium))
                    }
                    .foregroundStyle(theme.text3)
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var hasRawMessage: Bool {
        !(current.server.rawMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }

    /// When the code actually landed, not a hardcoded "just now" — this card
    /// is also reached from order history, where "just now" was simply false.
    private var arrivedAgo: String {
        guard let at = current.server.arrivedAt else { return "" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: at, relativeTo: Date())
    }

    /// The REAL SMS body when we have it.
    ///
    /// This used to compose "[Service] Your verification code is NNNN. Do not
    /// share it." from the code alone and label it RAW MESSAGE — inventing the
    /// text and presenting it as the message we received. `orders.raw_message`
    /// holds the genuine body (written by check-order) and was decoded into
    /// ServerOrder but read by nothing, so anyone whose SMS carried a link,
    /// extra instructions, or a differently-formatted code never saw it.
    /// Falls back to showing just the code, clearly labelled, rather than
    /// fabricating a sentence around it.
    private var rawMessageAttributed: AttributedString {
        if let raw = current.server.rawMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            var body = AttributedString(raw)
            body.font = RFont.text(14)
            body.foregroundColor = theme.text
            // Highlight the code inside the real message so it stays scannable.
            if let r = body.range(of: otpValue) {
                body[r].font = RFont.mono(14, weight: .semibold)
            }
            return body
        }
        var code = AttributedString(otpValue)
        code.font = RFont.mono(14, weight: .semibold)
        code.foregroundColor = theme.text
        return code
    }

    private func copy() {
        UIPasteboard.general.string = otpValue
        RHaptic.copied()
        withAnimation(RMotion.content) { copied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation(RMotion.content) { copied = false }
        }
    }
}

private struct OtpDigit: View {
    @Environment(\.theme) private var theme
    let digit: String
    let idx: Int
    let style: OtpAnimation

    @State private var revealed = false

    var body: some View {
        Text(digit)
            .font(RFont.mono(30, weight: .medium))
            .foregroundStyle(theme.text)
            .frame(width: 44, height: 56)
            .background(theme.chipBg, in: .rect(cornerRadius: RRadius.sm))
            .offset(y: revealed ? 0 : offset)
            .blur(radius: revealed ? 0 : blur)
            .opacity(revealed ? 1 : 0)
            .rotation3DEffect(.degrees(revealed ? 0 : flipAngle),
                              axis: (x: 1, y: 0, z: 0),
                              perspective: 0.6)
            .onAppear {
                let d = delay
                withAnimation(.easeOut(duration: 0.5).delay(d)) {
                    revealed = true
                }
            }
    }

    private var delay: Double {
        switch style {
        case .cascade: Double(idx) * 0.12
        case .reveal:  0
        case .flip:    Double(idx) * 0.06
        }
    }
    private var offset: CGFloat {
        switch style {
        case .cascade: 8
        case .reveal:  28
        case .flip:    0
        }
    }
    private var blur: CGFloat {
        switch style {
        case .cascade: 4
        case .reveal:  0
        case .flip:    0
        }
    }
    private var flipAngle: Double {
        style == .flip ? 90 : 0
    }
}
