import SwiftUI

/// Honest, up-front notice about the one thing this product can't guarantee:
/// that a code actually arrives.
///
/// Delivery is genuinely unreliable for some services — sites like Meta's
/// actively reject numbers they recognise as temporary — and a user who
/// discovers that *after* paying reads it as a scam. Saying it before the
/// purchase (and again while they wait) costs nothing, because the refund is
/// automatic. Pairing the warning with the remedy is what keeps it from
/// reading as a disclaimer. ⚠️ Rerolling is NOT free — it buys another number
/// — so only `.full`, which is not sitting under a priced reroll button, says
/// anything about trying again.
///
/// Two densities: `.full` on Checkout (pre-purchase, has room to explain) and
/// `.compact` on Waiting (already anxious, wants one line and a way out).
///
/// ── What is NOT here any more ────────────────────────────────────────────
///
/// **The apology is gone from BOTH.** It ended with *"We're sorry for the
/// hassle"* — an apology for a failure that had not happened, positioned as the
/// last thing read before spending money. It survived in `.compact` on the
/// argument that the hassle is real by then; it is not, while the clock is
/// still running and the code may still land.
///
/// **Our own delivery record is gone from both** (owner decision 2026-08-22 —
/// see the header of `SuccessBadge.swift`). The card used to lead with
/// "5 of the last 7 attempts got a code" and to swap its headline and its
/// paragraph for per-service odds ("This one rarely works"). Both were
/// renderings of that record, so the notice no longer takes a `service` at all
/// and says the same true thing to everyone: codes don't always arrive, and
/// credits come back when they don't.
struct DeliveryNotice: View {
    @Environment(\.theme) private var theme

    enum Density { case full, compact }
    var density: Density = .full

    var body: some View {
        switch density {
        case .full:   fullNotice
        case .compact: compactNotice
        }
    }

    /// ⚠️ It says **credits come back**, never "you're not charged".
    ///
    /// Credits leave the wallet inside the same transaction that writes the
    /// order row, so "you're only charged if a code arrives" — which this used
    /// to say — is false, and it is false on the same screen as a Cost row
    /// reading "N left after".
    private var fullNotice: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: RIcon.info)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.warn)
                    Text("Codes don't always arrive")
                        .font(RFont.display(15, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(theme.text)
                }

                Text("Some services block temporary numbers, so a code may never come through. If that happens your credits come straight back, and trying another number is free, as many times as you like.")
                    .font(RFont.text(13))
                    .tracking(-0.1)
                    .foregroundStyle(theme.text2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The waiting screen. Two sentences, and deliberately fewer than `.full`.
    ///
    /// ⚠️ **"trying another is free" is gone, and must not come back here.**
    /// This renders directly under a button reading "Get another number · N cr"
    /// — a price and a promise of free, one above the other. The reroll costs
    /// credits; only the refund is free, and that is what the second sentence
    /// says.
    ///
    /// The apology went with it. "Sorry for the hassle; we're working on it"
    /// apologised for something that has not happened yet — the code may still
    /// be seconds away — and reads as the app conceding failure while the
    /// clock is still running.
    private var compactNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: RIcon.info)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.text3)
                .padding(.top, 1)
            Text("Some services block temporary numbers, so a code may not arrive. Your credits come back if it doesn't.")
                .font(RFont.text(12))
                .tracking(-0.1)
                .foregroundStyle(theme.text3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
