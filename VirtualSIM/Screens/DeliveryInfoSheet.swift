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
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    /// "auto" when it opened itself before a first order, "button" from ⓘ.
    /// Read the two apart before judging the screen: the automatic showing is
    /// the one that has to change behaviour.
    let source: String

    /// Called only when the sheet opened itself in front of an order the user
    /// had already asked for, so the tap is not thrown away. nil from the ⓘ
    /// button, where there is no pending order to continue into.
    var onContinue: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                headline
                refundCard
                if state.showsDeliveryMetrics { bands }
                tries
                support
            }
            .padding(.horizontal, 20)
            .padding(.top, 26)
            .padding(.bottom, 32)
        }
        .background(theme.bg)
        .safeAreaInset(edge: .bottom) { cta }
        .onAppear {
            Analytics.shared.track("delivery_info_shown", ["source": .string(source)])
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

            // The attribution is load-bearing: this data is network-wide and
            // is NOT our own record. Never drop it to shorten the screen.
            Text("These are network-wide figures for the pool your number comes from, not our own delivery record.")
                .font(RFont.text(12))
                .foregroundStyle(theme.text3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
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
                    Text("Nine in ten people who get a code have it within three tries.")
                        .font(RFont.text(15, weight: .semibold))
                        .foregroundStyle(theme.text)
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
                Analytics.shared.track("delivery_info_support_tapped",
                                       ["source": .string(source)])
                UIApplication.shared.open(LegalLinks.supportWhatsApp(userId: session.userId))
            } label: {
                Card {
                    HStack(spacing: 12) {
                        Image(systemName: "message.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(theme.accent2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Message us on WhatsApp")
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

    private var cta: some View {
        VStack(spacing: 0) {
            PrimaryButton(
                label: onContinue == nil ? "Got it" : "Get my number",
                icon: onContinue == nil ? RIcon.check : RIcon.bolt,
                action: {
                    RHaptic.select()
                    let go = onContinue
                    dismiss()
                    // The order the user already asked for. Deferred so the
                    // sheet is gone before the flow cover is presented —
                    // presenting one over the other's dismissal drops it.
                    if let go {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: go)
                    }
                }
            )
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
        .background(theme.bg)
    }
}
