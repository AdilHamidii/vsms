import SwiftUI

/// What a temporary number actually does, shown ONCE before a user's first
/// order and from the ⓘ button on the Temp tab thereafter.
///
/// ── Why this exists (owner decision 2026-09-13) ───────────────────────────
/// A temp number failing is normal — it is how every reseller of this
/// inventory behaves, because the pools are lossy. The product already prices
/// that in: a number that delivers nothing is refunded automatically, so a
/// retry costs the user nothing. But nobody TOLD them, and the measurement is
/// stark: of 303 users who ordered at all in the 60 days to 2026-09-13, **166
/// placed exactly one order**, and three quarters of those left without the
/// code they came for. Success by persistence runs 25% → 34% → 52% → 64% →
/// 83% across the 1 / 2–3 / 4–6 / 7–12 / 13+ bands. The people who behave the
/// way the product works do fine; the majority quit at the first failure.
///
/// So this screen is not reassurance, it is instruction: what the band means,
/// that the retry is free, and when to stop retrying and move country instead.
///
/// ── 🔴 What the copy may and may not claim ────────────────────────────────
/// The advice is BRANCHED BY BAND, and that is the whole design. Measured on
/// settled orders since 2026-08-05, excluding app-picked routes (n = 295):
///
///     High (>60 published)    46.9% delivered per try   n = 98
///     Medium (30–60)          39.6%                     n = 111
///     Low (<30)               17.4%                     n = 86
///
/// So "try again" is right on High and WRONG on Low — 17% a try is about eight
/// attempts to reach where High gets in three, and the honest instruction
/// there is *pick another country*. Telling a user to persist on the worst
/// inventory in the catalogue is the same error as ranking it cheapest-first.
///
/// 🔴 **Never turn the counts into a promise.** Per-try probability tops out
/// at 47%, and a genuinely dead route makes attempts correlated rather than
/// independent, so "three tries and you'll have it" is false. The defensible
/// claim is DESCRIPTIVE and about people who already succeeded: of the 82
/// users who ever received a code, 62% had it on try 1, 82% by try 2, **89% by
/// try 3**, 100% by try 7. That is the sentence below, and it must stay in
/// that tense — it describes who got one, it does not forecast for someone who
/// has just failed three times.
///
/// 🔴 **No supplier is named or alluded to, and the figure is never ours.**
/// The band words are the vendor's NETWORK-WIDE rate, the same three words
/// `NetworkRateMeter` prints, and the copy says explicitly that it is not our
/// own delivery record. Dropping that attribution to solve the naming problem
/// would turn a third party's aggregate into an implied claim of our own.
///
/// ⚠️ **The band section hides under `delivery_metrics_hidden`.** When the
/// meter is off there is no band on screen to explain, and a legend for an
/// invisible control is worse than no legend. The refund, the retry advice and
/// support survive, because none of them depend on the meter.
struct DeliveryInfoSheet: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    /// "auto" when the Temp tab opened it, "button" from ⓘ. Read the two apart
    /// before judging the screen: the automatic showing is the one that has to
    /// change behaviour.
    let source: String

    /// WHERE a gated showing happened (branch `design-overhaul`):
    /// `"get_number"` — the store's Get-number tap, the primary showing — or
    /// `"checkout"` — the backstop inside the checkout cover, for routes into
    /// checkout that skip that tap. nil from the ⓘ. Sent as the `at` prop on
    /// both events so the two gated arms can be read apart while `source`
    /// stays `"auto"` and the series stays one series.
    var at: String? = nil

    /// 🔴 The acknowledgement GATE, and it is on only for the automatic
    /// showing (owner, 2026-09-13). The CTA stays grey and inert until the
    /// reader has both reached the bottom AND spent `Self.dwellSeconds` on the
    /// screen, which is the owner's explicit design: *"that'd make users
    /// understand its important to read"*. From the ⓘ it is off — that path is
    /// the user asking, and making someone re-earn a screen they chose to open
    /// is punishment, not instruction.
    var mustAcknowledge: Bool = false

    /// How long the gate holds even for a reader who flicks straight to the
    /// bottom.
    ///
    /// **10 seconds** (owner, 2026-09-13, raised from 5 after using it on a
    /// device). The cost of this number is measurable and should be watched
    /// rather than argued about: `delivery_info_shown` minus
    /// `delivery_info_acknowledged` on the `auto` arm is the count of people
    /// who hit the wall and left the tab instead of reading. If that gap opens
    /// up, this is the first thing to bring back down.
    private static let dwellSeconds = 10

    @State private var reachedEnd = false
    @State private var secondsLeft = DeliveryInfoSheet.dwellSeconds
    @State private var shownAt = Date()

    /// Both conditions, or neither matters: a timer alone rewards waiting
    /// without reading, and a scroll alone is satisfied by one flick.
    private var canContinue: Bool {
        !mustAcknowledge || (reachedEnd && secondsLeft == 0)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                headline
                refundCard
                if state.showsDeliveryMetrics { bands }
                tries

                // The last section doubles as the end sentinel.
                //
                // 🔴 `onAppear` DOES NOT WORK for this and shipping it would
                // have made the gate decorative. A `VStack` inside a
                // `ScrollView` realises every child eagerly, so an `onAppear`
                // fires at presentation while the view is still far below the
                // fold — the CTA was green on the first frame. Caught in the
                // simulator, not by reading the code.
                //
                // `onScrollVisibilityChange` asks the scroll view whether the
                // view is actually on screen, which is the real question.
                // iOS 18+, and the project floor is 18.0. It hangs off the
                // support CARD rather than a hairline spacer for two reasons:
                // a 1pt view's "visibility fraction" is a coin-flip against
                // any threshold, and reaching the last section IS reaching the
                // end as far as a reader is concerned.
                support
                    .onScrollVisibilityChange(threshold: 0.2) { visible in
                        if visible { reachedEnd = true }
                    }
            }
            .padding(.horizontal, 20)
            .padding(.top, 26)
            .padding(.bottom, 32)
        }
        .background(theme.bg)
        .safeAreaInset(edge: .bottom) { cta }
        // No swipe-away while the gate is on, or the gate is decorative.
        .interactiveDismissDisabled(mustAcknowledge && !canContinue)
        .onAppear {
            shownAt = Date()
            var props: [String: AnalyticsValue] = ["source": .string(source)]
            if let at { props["at"] = .string(at) }
            Analytics.shared.track("delivery_info_shown", props)
        }
        .task {
            guard mustAcknowledge else { secondsLeft = 0; return }
            while secondsLeft > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                secondsLeft -= 1
            }
        }
    }

    // MARK: - Sections

    private var headline: some View {
        VStack(alignment: .leading, spacing: 8) {
            MicroLabel("Before you start")
            Text("How temporary numbers work")
                .font(RFont.display(28, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(theme.text)
            Text("A temporary number borrows a real handset on a mobile network. Sometimes the app you're verifying refuses it, or the message never arrives. That's normal, and it's why the next part matters.")
                .font(RFont.text(15))
                .foregroundStyle(theme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// First, and deliberately: it removes the actual reason people stop. It
    /// is also simply true — every expired and every cancelled order in the 30
    /// days to 2026-09-13 carries a refund ledger row, all 311 of them.
    private var refundCard: some View {
        Card(fill: theme.liveSoft, border: theme.live.opacity(0.35)) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: RIcon.shield)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.live)
                VStack(alignment: .leading, spacing: 5) {
                    Text("You're never charged for a number that doesn't deliver")
                        .font(RFont.text(15, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("If no code arrives, your credits come straight back automatically. Trying again costs you nothing.")
                        .font(RFont.text(14))
                        .foregroundStyle(theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
    }

    private var bands: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(label: "What the delivery label means")

            bandRow(color: theme.live, word: "High",
                    advice: "Worth trying. Most codes land on the first or second go.")
            bandRow(color: theme.warn, word: "Medium",
                    advice: "Still good. Plan on a few tries before it lands.")
            bandRow(color: theme.fail, word: "Low",
                    advice: "Pick another country instead. Retrying here rarely pays off.")

            // 🔴 The FOURTH row, and it covers the MAJORITY of the catalogue:
            // 6,443 of 9,336 active routes publish no figure at all (2026-09-13
            // — every route on the second network, plus 64% of the first's).
            // Without it, the commonest thing a user sees is the one thing the
            // legend does not explain, which reads as "unrated means bad".
            //
            // ⚠️ The claim is "not distinguishable", not "proven equal", and
            // the sample is why. Settled orders since 2026-08-05, app-picked
            // excluded: routes WITH a figure delivered 35.6% per try (n = 295);
            // routes with none delivered 33.3% on the other network (n = 18)
            // and 28.6% overall (n = 28). Twenty-eight orders cannot separate
            // those. If that gap widens on a real sample, soften this row —
            // it is the only row making a positive claim about inventory we
            // have no vendor figure for.
            bandRow(color: theme.text3, word: "No label",
                    advice: "Just as worth trying. These come from a different network that doesn't publish a figure.")
        }
    }

    private func bandRow(color: Color, word: LocalizedStringKey,
                         advice: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Same bar-then-word shape as `NetworkRateMeter`, so the legend
            // looks like the thing it explains.
            Capsule()
                .fill(color)
                .frame(width: 22, height: 4)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(word)
                    .font(RFont.text(14, weight: .bold))
                    .foregroundStyle(color)
                Text(advice)
                    .font(RFont.text(14))
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var tries: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(label: "How many tries")
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    // Descriptive, past tense, about people who SUCCEEDED.
                    // Not a forecast — see the header.
                    //
                    // Green at the owner's request (2026-09-13), to pull the
                    // eye to the one sentence that changes behaviour. It is
                    // the semantic success colour, which is consistent here:
                    // this line and the refund card are the two pieces of good
                    // news on the screen, and they now read as a pair.
                    Text("Nine in ten people who get a code have it within three tries.")
                        .font(RFont.text(15, weight: .semibold))
                        .foregroundStyle(theme.live)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Each try gets you a different number, so a fresh attempt is a fresh chance. If three or four tries on the same country come up empty, switch country rather than keep going.")
                        .font(RFont.text(14))
                        .foregroundStyle(theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
        }
    }

    private var support: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(label: "Stuck?")
            Button {
                RHaptic.select()
                let url = LegalLinks.supportURL
                Analytics.shared.track("delivery_info_support_tapped",
                                       ["source": .string(source),
                                        "dest": .string(url.host ?? "")])
                UIApplication.shared.open(url)
            } label: {
                Card {
                    HStack(spacing: 12) {
                        Image(systemName: "message.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(theme.accent2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Chat with support")
                                .font(RFont.text(15, weight: .semibold))
                                .foregroundStyle(theme.text)
                            Text("If a code won't come through, tell us which app and country and we'll help you land it.")
                                .font(RFont.text(13))
                                .foregroundStyle(theme.text2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                }
            }
            .buttonStyle(.plain)
        }
    }

    /// Grey and inert until the gate opens, then the app's normal green. The
    /// two states are `PrimaryButton`'s own `disabled` rendering (chip fill +
    /// `text3`), so this screen invents no button of its own.
    private var cta: some View {
        VStack(spacing: 8) {
            // Says WHY it is grey. A disabled button with no explanation reads
            // as a bug, and a reader who thinks the screen is broken learns
            // nothing from it.
            if mustAcknowledge && !canContinue {
                Text(reachedEnd
                     ? "Just a moment…"
                     : "Scroll down to continue")
                    .font(RFont.text(13))
                    .foregroundStyle(theme.text3)
                    .transition(.opacity)
            }

            PrimaryButton(
                label: gateLabel,
                icon: canContinue ? RIcon.check : nil,
                disabled: !canContinue,
                action: {
                    RHaptic.select()
                    if mustAcknowledge {
                        // 🔴 Written HERE, on the acknowledgement, and not
                        // when the sheet was presented. Writing it on
                        // presentation would let a force-quit mid-read skip
                        // the screen forever — the one outcome the gate is
                        // for.
                        UserDefaults.standard.set(true, forKey: PrefKey.deliveryInfoAcked)
                        var props: [String: AnalyticsValue] = [
                            "seconds": .int(Int(Date().timeIntervalSince(shownAt))),
                        ]
                        if let at { props["at"] = .string(at) }
                        Analytics.shared.track("delivery_info_acknowledged", props)
                    }
                    dismiss()
                }
            )
            .animation(RMotion.content, value: canContinue)
            .padding(.horizontal, 20)
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(theme.bg)
    }

    /// ⚠️ Built with `String(localized:)` and interpolation, NOT a bare
    /// literal: `PrimaryButton` takes a `String` and resolves it against the
    /// catalog at runtime, so an interpolated value has to arrive already
    /// translated or it renders the format string.
    private var gateLabel: String {
        guard mustAcknowledge, !canContinue else {
            return String(localized: "I understand")
        }
        if secondsLeft > 0 {
            return String(localized: "I understand (\(secondsLeft))")
        }
        return String(localized: "I understand")
    }
}
