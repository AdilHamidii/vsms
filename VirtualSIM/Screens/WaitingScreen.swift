import SwiftUI

/// The screen a user stares at with their money already spent.
///
/// It used to show FIVE controls at t=0, three of them about failure: the
/// number, Copy, "Check now", "<service> rejected it — get another" under a
/// three-line 11pt disclaimer, and "You can cancel in 90s". All of that before
/// the user had time to switch apps and paste the number anywhere. A screen
/// that opens by listing the ways this can go wrong teaches the user to expect
/// it to.
///
/// It is now staged on `elapsed`, which already ticks once per second:
///
/// | from | what appears |
/// |---|---|
/// | 0s  | the number, one full-width Copy, the ring |
/// | 25s | the rejection path, the delivery notice, our record |
/// | 90s | Cancel & refund (the server's own `MIN_HOLD_SECONDS`) |
///
/// 25s is not arbitrary: a site rejects a number at its signup form within
/// ~20 seconds, so that is the first moment the "it was rejected" escape is
/// information rather than a suggestion. Before it, the only thing the user can
/// usefully do is copy the number, so that is the only thing offered.
struct WaitingScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    @Environment(PushManager.self) private var push

    let order: Order
    @State private var elapsed: Int = 0   // seeded from order.createdAt in .task
    @State private var copied = false
    @State private var showCancelConfirm = false

    private var reservation: Int { max(60, Int(order.expiresAt.timeIntervalSince(order.createdAt))) }
    private var remaining: Int { max(0, Int(order.expiresAt.timeIntervalSinceNow)) }

    /// The reservation window is over but the server hasn't confirmed the
    /// outcome yet. The old UI just sat on a frozen "00:00" here — which,
    /// while the provider was flaky, could persist forever even though the
    /// 60s cron had already expired the order AND refunded it. Never present
    /// a dead countdown as if it were still a countdown.
    private var isFinalizing: Bool { remaining == 0 }

    /// How long we have been finalizing. Derived from `elapsed` rather than a
    /// second timer so it ticks with everything else on the screen.
    private var finalizingFor: Int { max(0, elapsed - reservation) }

    /// Reconcile has not resolved in a minute and a half.
    ///
    /// `isFinalizing` had NO timeout: if the order row never came back the
    /// user sat on "Time's up. Confirming with the network…" forever, with no
    /// statement about their credits and nowhere to go. The server has already
    /// refunded by this point — both terminal paths refund unconditionally —
    /// so the honest thing is to say so and offer history, not to keep
    /// spinning.
    private var isStalled: Bool { isFinalizing && finalizingFor >= 90 }

    // MARK: - Disclosure

    private enum Phase { case fresh, options, full }

    /// The first moment the "rejected it" escape is information rather than a
    /// suggestion. See the type comment.
    private static let disclosureSeconds = 25

    private var phase: Phase {
        if elapsed >= Self.minHoldSeconds { return .full }
        if elapsed >= Self.disclosureSeconds { return .options }
        return .fresh
    }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    topBar
                    serviceStrip
                    numberCard
                    waitingCard

                    if phase != .fresh {
                        recoveryBlock.transition(revealTransition)
                        refundReassurance.transition(revealTransition)
                        if state.showMetrics { metric.transition(revealTransition) }
                    }
                    if phase == .full {
                        cancelAction.transition(revealTransition)
                    }
                }
                .animation(RMotion.panel, value: phase)
                .padding(.top, 6)
                .padding(.bottom, 60)
            }
            .scrollIndicators(.hidden)
        }
        .task {
            // Tick once per second, measured from the ORDER, not from when this
            // view appeared.
            //
            // It used to anchor on a local `Date()` captured at .task time. The
            // view's identity survives a reroll (flow stays .waiting), so @State
            // persisted: after a reroll `elapsed` was already past the 180s
            // hold, unlocking ✕ and both reroll buttons on a number seconds old
            // — every tap then returning 429 cancel_too_early — while the
            // ELAPSED cell kept counting the PREVIOUS order and rendered
            // impossible pairs like "ELAPSED 03:22 / EXPIRES IN 07:58".
            // Conversely resumeInFlightOrder() showed a 7-minute-old order as
            // ELAPSED 00:00 and locked cancel for longer than the order had
            // left to live.
            //
            // It is now load-bearing for the DISCLOSURE too: a resumed order
            // arrives with its controls already unlocked, which is correct —
            // staging is about the user's first 90 seconds with a number, not
            // about how long this view has been on screen.
            while !Task.isCancelled {
                elapsed = max(0, Int(Date().timeIntervalSince(order.createdAt)))
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        .task {
            // The one moment a notification has obvious value: a paid order
            // is in flight and the user wants to background the app. Small
            // delay so the dialog doesn't fight the cover animation. No-op
            // unless permission is still notDetermined.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await push.requestAuthorizationAndRegister()
        }
        .task {
            // Poll the server for the SMS every 4s while we're on this screen.
            let ordersAPI = OrdersAPI(client: api)
            let walletAPI = WalletAPI(client: api)
            while !Task.isCancelled, state.flow == .waiting {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await state.pollActiveOrder(using: ordersAPI, wallet: walletAPI)
            }
        }
        .task {
            // Reconcile-on-timeout. Once the window has closed, the provider
            // poll is no longer the authority on whether this order is over —
            // the order row is, and the cron writes the terminal status +
            // refund there within ~60s. Keep asking until the UI leaves
            // `.waiting`, so a failing provider can no longer strand the user
            // on a screen that says "Waiting" about an order that ended.
            let ordersAPI = OrdersAPI(client: api)
            let walletAPI = WalletAPI(client: api)
            while !Task.isCancelled, state.flow == .waiting {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard state.flow == .waiting, state.isPastExpiry(order) else { continue }
                await state.reconcileActiveOrder(using: ordersAPI, wallet: walletAPI)
            }
        }
        .confirmationDialog(
            "Cancel this order?",
            isPresented: $showCancelConfirm,
            titleVisibility: .visible
        ) {
            Button("Cancel order & refund \(order.costCredits) credits", role: .destructive) {
                RHaptic.warn()
                Task {
                    await state.cancelWaiting(
                        using: OrdersAPI(client: api),
                        wallet: WalletAPI(client: api)
                    )
                }
            }
            Button("Keep waiting", role: .cancel) { }
        } message: {
            Text("Your \(order.costCredits) credits go back to your balance. If a code is already on its way, you'll lose it.")
        }
    }

    private var revealTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)),
            removal: .opacity
        )
    }

    /// Minimum hold before a paid order can be destroyed. Mirrors
    /// MIN_HOLD_SECONDS in cancel-order — the server refuses early cancels, so
    /// leaving these enabled would only produce an error banner.
    ///
    /// 180 -> 90 (2026-08-03). Measured over 90 days: on HeroSMS, which serves
    /// most volume, no code has ever arrived later than 86s, and 0 of 21 orders
    /// still alive at 90s went on to deliver. The 90-180s stretch was dead time.
    ///
    /// This constant may only ever be RAISED ahead of the server, never lowered
    /// ahead of it: a client that offers cancel before the server allows it just
    /// collects a 429. Ship the backend change first — which also means shipped
    /// 1.6/1.7 (still 180 here) stay safe, they simply keep the stricter hold.
    private static let minHoldSeconds = 90

    /// Seconds left before cancel/reroll unlock, or nil once they're free.
    /// Driven by `elapsed`, which already ticks once per second.
    private var holdRemaining: Int? {
        let left = Self.minHoldSeconds - elapsed
        return left > 0 ? left : nil
    }

    private var topBar: some View {
        HStack {
            Color.clear.frame(width: 36, height: 36)
            Spacer()
            Text("Active rental")
                .font(RFont.display(16, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(theme.text)
            Spacer()
            // ✕ LEAVES; it does not cancel.
            //
            // It read as "back" and destroyed a paid, in-flight order — first
            // instantly, then behind a confirmation. Both were wrong: the user
            // has to go and paste the number into another app, and coming back
            // is the normal path. Leaving is free, the order keeps running, and
            // `ResumeBar` above the tab bar brings them back — which is what
            // makes non-destructive close honest rather than a disappearance.
            //
            // Cancelling is still available, as an explicit labelled action
            // lower down (`cancelAction`), still gated by the 90s hold.
            //
            // ⚠️ It must NOT be gated on `holdRemaining`. It was, until
            // 2026-08-01 — a leftover from when this button was the cancel,
            // and the single most user-hostile bug in the app: the ✕ no longer
            // destroyed anything, yet it stayed dead for the first 180 seconds,
            // so a user whose number had just been rejected by the site was
            // trapped on this screen for three minutes with no way to go and
            // order another. The hold exists to protect the ORDER from being
            // destroyed early, not to protect the screen from being left.
            Button {
                state.flow = nil
            } label: {
                Image(systemName: RIcon.close)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text2)
                    .frame(width: 36, height: 36)
                    .background(theme.chipBg, in: .circle)
            }
            .pressable()
            // isPlacingOrder stays: leaving the ✕ live during a reroll let
            // cancelWaiting fire mid-reroll and null activeOrder after the
            // fresh one was installed, rendering an empty screen over a live
            // paid order.
            .disabled(state.isPlacingOrder)
            .accessibilityLabel(Text("Close. Your number keeps running"))
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
                    Text(order.country.name)
                        .font(RFont.text(12))
                        .foregroundStyle(theme.text2)
                }
            }
            Spacer()
            StatusBadge(status: .waiting)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - The number

    /// The one object this screen is about, so it is the one hero surface.
    ///
    /// Copy is a full-width PRIMARY. It used to be a grey chip sharing its row
    /// with "Check now", which put the only useful action at t=0 at the same
    /// visual weight as a button that did nothing the 4-second poll wasn't
    /// already doing.
    private var numberCard: some View {
        HeroCard {
            VStack(alignment: .leading, spacing: 0) {
                MicroLabel("Your number")
                MonoText(order.number, size: 32, weight: .medium, color: theme.text)
                    .padding(.top, 10)
                    .textSelection(.enabled)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)

                PrimaryButton(
                    label: copied ? String(localized: "Copied") : String(localized: "Copy number"),
                    icon: copied ? RIcon.check : RIcon.copy,
                    action: copy
                )
                .padding(.top, 18)

                Text("Paste it into \(order.service.name), then come back. The code lands here.")
                    .font(RFont.text(12))
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 22)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - The wait

    /// Where the measured p90 sits inside the reservation window, or nil when
    /// we have measured nothing for this service.
    ///
    /// Nil is a real answer and must stay one — see `WaitingAnimationView`,
    /// which then draws no milestone at all rather than inventing a plausible
    /// place to put it.
    private var expectedFraction: Double? {
        guard let p90 = order.service.arrivalP90Seconds, p90 > 0 else { return nil }
        return min(1, Double(p90) / Double(reservation))
    }

    /// The countdown appears ONLY in the final minute.
    ///
    /// The rule this screen broke: never put a running deadline next to a
    /// destructive button. In the last 60 seconds it stops being pressure and
    /// becomes information — the number is genuinely about to be released — so
    /// it renders, once, in `theme.warn`.
    private var countdownText: String? {
        guard !isFinalizing, remaining <= 60 else { return nil }
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }

    private var waitingCard: some View {
        Card {
            VStack(spacing: 18) {
                WaitingAnimationView(
                    kind: state.waitingAnimation,
                    progress: Double(elapsed) / Double(reservation),
                    expectedFraction: expectedFraction,
                    countdown: countdownText,
                    isFinalizing: isFinalizing
                )

                VStack(spacing: 5) {
                    Text(headline)
                        .font(RFont.display(18, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(theme.text)
                        .multilineTextAlignment(.center)
                    // MEASURED arrival only. This used to quote the seed
                    // `etaSeconds` (~28s) against a measured ~53s median —
                    // promising a deadline we miss, right after payment,
                    // which is what makes people cancel at 63s.
                    Text(subheadline)
                        .font(RFont.text(13))
                        .tracking(-0.1)
                        .foregroundStyle(theme.text2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Only when reconcile has genuinely stalled. Anything sooner
                // would be an escape hatch offered before there is anything to
                // escape from.
                if isStalled {
                    GhostButton(label: String(localized: "See it in Orders"),
                                icon: RIcon.inbox,
                                fillsWidth: false) {
                        state.flow = .orders
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .padding(.vertical, 26)
        }
        .padding(.horizontal, 16)
    }

    private var headline: String {
        if isStalled {
            return String(localized: "Still confirming")
        }
        if isFinalizing {
            return String(localized: "Time's up. Confirming with the network…")
        }
        return String(localized: "Waiting for \(order.service.name) code…")
    }

    private var subheadline: String {
        if isStalled {
            // The server refunds unconditionally on both terminal paths, so
            // this is a statement of what has ALREADY happened, not a promise.
            return String(localized: "Your \(order.costCredits) credits are safe. Every order that ends without a code is refunded in full. The outcome will show in Orders.")
        }
        if isFinalizing {
            return String(localized: "If no code arrived, your \(order.costCredits) credits are refunded automatically.")
        }
        return order.service.typicalWaitSentence
            ?? String(localized: "Your code appears here the moment it arrives.")
    }

    // MARK: - Recovery (25s+)

    /// The two ways a number dies, each with a one-tap recovery.
    ///
    /// "Rejected" is the common case for high-security services: the site
    /// refuses the number at its signup form within ~20 seconds, so no timer
    /// can detect it — only the user knows. Inside the hold the escape has to
    /// be ADDITIVE (a second number alongside this one) because a reroll
    /// releases the first, which is exactly what the hold forbids. Once the
    /// hold lifts the reroll is strictly better — it refunds what it releases —
    /// so the block swaps over.
    @ViewBuilder
    private var recoveryBlock: some View {
        Card(elevation: .flat, fill: theme.elev2) {
            VStack(alignment: .leading, spacing: 10) {
                MicroLabel("If the site rejected it")
                if holdRemaining != nil {
                    concurrentAction
                } else {
                    rerollActions
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .padding(.horizontal, 16)
    }

    /// "Get another number" — additive, not a swap.
    ///
    /// Deliberately states the price. The reroll it stands in for is free (it
    /// refunds the number it releases), so a button that silently charged again
    /// would be the same shape of lie as a ✕ that destroyed a paid order.
    ///
    /// Leaving the screen is what makes this safe: the current number stays
    /// live, `ResumeBar` keeps it reachable, and if a code lands on it the push
    /// still arrives — so ordering a second number never forfeits the first.
    @ViewBuilder
    private var concurrentAction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                RHaptic.select()
                state.orderAnotherNumber()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: RIcon.refresh)
                        .font(.system(size: 13, weight: .semibold))
                    Text("Get another number")
                        .font(RFont.text(14, weight: .semibold))
                    Spacer(minLength: 0)
                    Text("\(order.costCredits) cr")
                        .font(RFont.mono(13, weight: .medium))
                        .foregroundStyle(theme.text2)
                }
                .foregroundStyle(theme.text)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(theme.elev, in: .rect(cornerRadius: RRadius.sm))
            }
            .pressable()
            .disabled(state.isPlacingOrder)

            Text("This number keeps running and still refunds itself if no code arrives.")
                .font(RFont.text(11))
                .foregroundStyle(theme.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var rerollActions: some View {
        HStack(spacing: 8) {
            rerollButton(
                title: String(localized: "Another country"),
                icon: RIcon.globe,
                differentCountry: true
            )
            rerollButton(
                title: String(localized: "Another number"),
                icon: RIcon.refresh,
                differentCountry: false
            )
        }
    }

    // Reroll releases the number exactly like a cancel, so it is held for the
    // same 90s. Without this the button would just surface a server error.
    private func rerollButton(title: String, icon: String,
                              differentCountry: Bool) -> some View {
        Button {
            RHaptic.select()
            Task {
                await state.rerollNumber(
                    using: OrdersAPI(client: api),
                    wallet: WalletAPI(client: api),
                    differentCountry: differentCountry
                )
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(LocalizedStringKey(title))
                    .font(RFont.text(13, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(theme.text)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(theme.elev, in: .rect(cornerRadius: RRadius.sm))
        }
        .pressable()
        .disabled(state.isPlacingOrder)
        .opacity(state.isPlacingOrder ? 0.5 : 1)
    }

    // MARK: - Cancel (90s+)

    /// Cancel + refund, as an explicit labelled action rather than a ✕.
    ///
    /// The ✕ used to be this, which is why it needed a confirmation dialog: a
    /// glyph that reads as "back" must not destroy a paid order. It is now
    /// simply ABSENT until the hold lifts, rather than present-but-refusing
    /// with a "You can cancel in 90s" countdown — that line was a third clock
    /// on a screen whose whole problem was clocks, and it advertised quitting
    /// during the exact window where most codes land.
    private var cancelAction: some View {
        Button {
            showCancelConfirm = true
        } label: {
            Text("Cancel & refund \(order.costCredits) cr")
                .font(RFont.text(13, weight: .medium))
                .foregroundStyle(theme.text2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .pressable()
        .disabled(state.isPlacingOrder)
        .padding(.horizontal, 16)
    }

    // No SMS provider delivers 100% of the time (numbers get flagged, some
    // services block non-native SIMs). Make the safety net explicit so an
    // undelivered code costs the user nothing and doesn't read as a scam —
    // cancelWaiting issues a full refund.
    private var refundReassurance: some View {
        DeliveryNotice(density: .compact)
            .padding(.horizontal, 24)
    }

    // MEASURED delivery only, and nothing at all when we have no measurement.
    //
    // This used to render `order.service.successRate` — seed data that sits at
    // 86-99% for all 268 services (avg 91%) and which Service.swift explicitly
    // says "must never be shown as fact". Worst of all it fired here, right
    // after the user paid, promising ~91% on clusters that actually measure ~9%.
    //
    // It then spent a year rendering the MEASURED rate as a PERCENTAGE, which
    // is the other half of the same mistake: "0% of Facebook codes in Denmark
    // have arrived" is routinely a 2-sample claim (the demotion gate is
    // asymmetric — migration 20260725120000) wearing the confidence of a
    // 200-sample one. `deliveryRecord` gives the raw pair, which carries its
    // own uncertainty and needs no asterisk. Same rule, same wording, as
    // `SuccessBadge`.
    @ViewBuilder
    private var metric: some View {
        if case let .measured(codes, attempts) = state.deliveryRecord(
            for: order.service, country: order.country), attempts > 0 {
            HStack(spacing: 8) {
                Image(systemName: RIcon.spark)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.text3)
                Text("\(order.service.name) in \(order.country.name) has worked \(codes) of \(attempts) times.")
                    .font(RFont.text(12))
                    .tracking(-0.1)
                    .foregroundStyle(theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
        }
    }

    private func copy() {
        UIPasteboard.general.string = order.number
        RHaptic.copied()
        withAnimation(RMotion.content) { copied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation(RMotion.content) { copied = false }
        }
    }
}
