import SwiftUI

/// Honest, up-front notice about the one thing this product can't guarantee:
/// that a code actually arrives.
///
/// Delivery is genuinely unreliable for some services — sites like Meta's
/// actively reject numbers they recognise as temporary — and a user who
/// discovers that *after* paying reads it as a scam. Saying it before the
/// purchase (and again while they wait) costs nothing, because rerolling and
/// refunds are already free. Pairing the warning with the remedy is what keeps
/// it from reading as a disclaimer.
///
/// Two densities: `.full` on Checkout (pre-purchase, has room to explain) and
/// `.compact` on Waiting (already anxious, wants one line and a way out).
///
/// ── Two fixes from the 2026-08 audit ─────────────────────────────────────
///
/// **The apology is gone from `.full`.** It ended with *"We're sorry for the
/// hassle"* — an apology for a failure that had not happened, positioned as the
/// last thing read before spending money. Apologising pre-emptively does not
/// make the risk smaller; it just makes the purchase feel like a mistake
/// already in progress. It survives in `.compact`, which renders on the WAITING
/// screen, where the hassle is real and the sentence is finally true.
///
/// **The measured evidence leads.** It used to sit third, below a generic
/// headline and a paragraph of prose — so the one sentence on the card that is
/// our own data was the one the eye reached last. Everything above it was
/// framing; this is the fact.
struct DeliveryNotice: View {
    @Environment(\.theme) private var theme

    enum Density { case full, compact }
    var density: Density = .full
    /// When set, the notice speaks about THIS service specifically instead of
    /// making the same generic claim to everyone. A user buying Leboncoin
    /// (62% delivered) and one buying Facebook (8%) were being told exactly
    /// the same thing, which is true but useless to both.
    var service: Service? = nil

    var body: some View {
        switch density {
        case .full:   fullNotice
        case .compact: compactNotice
        }
    }

    private var odds: Service.DeliveryOdds { service?.deliveryOdds ?? .unknown }

    private var headline: String {
        switch odds {
        case .poor:  return String(localized: "This one rarely works")
        case .mixed: return String(localized: "This one is hit or miss")
        case .good, .unknown: return String(localized: "Codes don't always arrive")
        }
    }

    private var accent: Color {
        switch odds {
        case .poor:  return theme.fail
        case .mixed: return theme.warn
        case .good:  return theme.live
        case .unknown: return theme.warn
        }
    }

    /// The evidence line states a raw record and can appear below the
    /// confidence threshold, so it must NOT inherit `accent` — that is keyed to
    /// the tier, which is `.unknown` on a small sample and paints warn. TikTok
    /// at 5 of 7 is the app's best first-order service and would have rendered
    /// its record in the warning colour.
    ///
    /// Bands come from `DeliveryBand`, the app's single definition — this used
    /// to carry its own fourth copy of the same arithmetic at its own
    /// thresholds (0.50 / 0.20), which happen to be the ones everything now
    /// agrees on.
    private var evidenceColor: Color {
        guard let r = service?.observedRatio else { return theme.text2 }
        return theme.deliveryColor(DeliveryBand.of(ratio: r))
    }

    private var evidenceWash: Color {
        guard let r = service?.observedRatio else { return theme.chipBg }
        return theme.deliverySoft(DeliveryBand.of(ratio: r))
    }

    /// ⚠️ Every branch says **credits come back**, never "you're not charged".
    ///
    /// Credits leave the wallet inside the same transaction that writes the
    /// order row, so "you're only charged if a code arrives" — which all four
    /// of these used to say — is false, and it is false on the same screen as a
    /// Cost row reading "N left after". Checkout's title block was corrected for
    /// exactly this; a component rendered 12pt below it must not reintroduce
    /// the contradiction.
    private var detail: String {
        guard let service else {
            return String(localized: "Some services block temporary numbers, so a code may never come through. If that happens your credits come straight back — and trying another number is free, as many times as you like.")
        }
        switch odds {
        case .poor:
            return String(localized: "\(service.name) blocks most temporary numbers, so a code often never arrives. Your credits come back every time one doesn't, and trying again is free — but it may not work at all.")
        case .mixed:
            return String(localized: "\(service.name) accepts temporary numbers some of the time. Your credits come back if no code arrives, and trying another number is free.")
        case .good, .unknown:
            return String(localized: "Some services block temporary numbers, so a code may never come through. If that happens your credits come straight back — and trying another number is free, as many times as you like.")
        }
    }

    private var fullNotice: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                // 1. WHAT WE MEASURED. First, largest, and the only figure on
                //    the card. Absent when the sample is too thin to state —
                //    `deliveryEvidence` is nil below 3 attempts, and silence is
                //    the honest answer there.
                if let evidence = service?.deliveryEvidence {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(evidence)
                            .font(RFont.display(17, weight: .semibold))
                            .tracking(-0.3)
                            .foregroundStyle(evidenceColor)
                            .fixedSize(horizontal: false, vertical: true)

                        // The window, stated once. A bare "5 of the last 7"
                        // has no timeframe and no owner, so it could equally
                        // be the provider's number about everyone's orders.
                        Text("Our own orders, last 30 days")
                            .font(RFont.text(12))
                            .foregroundStyle(theme.text3)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(evidenceWash, in: .rect(cornerRadius: RRadius.sm))
                }

                // 2. What that means, in words.
                HStack(spacing: 8) {
                    Image(systemName: RIcon.info)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent)
                    Text(headline)
                        .font(RFont.display(15, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(theme.text)
                }

                Text(detail)
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

    /// The waiting screen. The apology belongs HERE and only here: by this
    /// point the user has spent a credit and is watching a clock, so the hassle
    /// is no longer hypothetical.
    private var compactNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: RIcon.info)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.text3)
                .padding(.top, 1)
            Text("Some services block temporary numbers, so a code may not arrive. Your credits come back if it doesn't, and trying another is free. Sorry for the hassle; we're working on it.")
                .font(RFont.text(12))
                .tracking(-0.1)
                .foregroundStyle(theme.text3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
