import SwiftUI

/// Shown when an order ends without a code (expiry, cancel, or a failed
/// reroll) — replaces the old dead-end "dumped to Home with an error banner".
/// Reassures about the refund, then steers the retry to the country we've
/// MEASURED delivering best for this service. The steering line renders only
/// on measured evidence (never seeded estimates); without any, the card
/// offers a plain retry on the same route — the backend's retry steering
/// still gives that attempt a fresh number on a rotated carrier.
struct RecoveryScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state

    let context: RecoveryContext

    private var suggestion: (country: Country, rate: Int)? {
        state.bestMeasuredCountry(for: context.service)
    }

    // `suggestion` still STEERS — it is what the primary button retries into —
    // but it is no longer described. The two sentences that used to sit above
    // the button ("… has worked 3 of the last 5 times in Poland", "… has the
    // best record we've measured in Poland") were renderings of our own
    // delivery record, removed 2026-08-22; see the header of
    // `SuccessBadge.swift`.

    /// First fallback when we have measured nothing for this service — which
    /// is the common case, since route-level evidence covers a handful of
    /// routes: the best HIGH-band pool by the vendor's hourly published rate.
    /// Consulted before the weekly ranking because it is fresher and covers
    /// nearly the whole catalog. Never offers the country that just failed.
    private var poolSuggestion: (country: Country, rate: Int, price: Int)? {
        guard suggestion == nil else { return nil }
        return state.bestPoolRatedCountry(for: context.service, excluding: context.failedCountry)
    }

    /// Second fallback: the vendor's ranked top-10 for the service. Only
    /// consulted when both `suggestion` and `poolSuggestion` are nil: our own
    /// delivery always wins over a third party's, because it describes orders
    /// we actually placed.
    ///
    /// Never offers the country that just failed.
    private var rankedSuggestion: (country: Country, rank: CountryRank, price: Int)? {
        guard suggestion == nil, poolSuggestion == nil else { return nil }
        return state.bestRankedCountry(for: context.service, excluding: context.failedCountry)
    }

    /// The country the primary button names, when it names one. nil on the
    /// measured branch on purpose — `retryFromRecovery` resolves that one
    /// itself, keeping that path byte-identical.
    private var offeredCountry: Country? {
        poolSuggestion?.country ?? rankedSuggestion?.country
    }

    private var headline: String {
        switch context.reason {
        case .expired:  String(localized: "No code arrived")
        case .canceled: String(localized: "Number released")
        }
    }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                Spacer()
                card
                Spacer()
            }
        }
    }

    private var topBar: some View {
        HStack {
            Color.clear.frame(width: 36, height: 36)
            Spacer()
            Button {
                state.dismissRecovery()
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
        .padding(.bottom, 8)
    }

    private var card: some View {
        HeroCard {
            VStack(spacing: 0) {
                ServiceLogo(service: context.service, size: 52)
                    .padding(.top, 28)
                Text(headline)
                    .displayType(22, weight: .semibold)
                    .foregroundStyle(theme.text)
                    .padding(.top, 14)
                Text("You weren't charged. Your credits are back in your balance.")
                    .font(RFont.text(14))
                    .foregroundStyle(theme.text2)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                    .padding(.horizontal, 24)

                // A receipt, not a reassurance. The sentence above is the same
                // claim the app always made; this is the number that makes it
                // checkable against the balance the user can see.
                if let credits = context.refundedCredits {
                    HStack(spacing: 6) {
                        Image(systemName: RIcon.check)
                            .font(.system(size: 12, weight: .bold))
                        Text("+\(credits) credits refunded")
                            .font(RFont.text(13, weight: .semibold))
                    }
                    .foregroundStyle(theme.live)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(theme.liveSoft, in: .capsule)
                    .padding(.top, 12)
                }

                // When we can point at a better country the card says so. When
                // we cannot — which is the common case, since route-level
                // evidence covers a handful of routes — the CTA used to read
                // "Try again / Fresh number" over nothing at all, so the offer
                // was "do the thing that just failed, again". It is not: the
                // backend's retry steering excludes every number this user has
                // already burned on this service and rotates off the carrier
                // that just failed.
                //
                // Deliberately NOT a rate, a percentage, or any claim about
                // odds. It states a MECHANISM, which is a thing we know to be
                // true, rather than an outcome, which we do not.
                // Shown whenever there is no network-rate chip below — which
                // now includes the measured-suggestion case, since that chip
                // was removed with the rest of the record surfaces. The user
                // still gets a reason to press the button.
                if poolSuggestion == nil && rankedSuggestion == nil {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: RIcon.refresh)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.text2)
                            .padding(.top, 1)
                        Text("Trying again isn't the same attempt: you'll get a different number, on a different carrier from the one that just failed.")
                            .font(RFont.text(13, weight: .medium))
                            .foregroundStyle(theme.text)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(theme.chipBg, in: .rect(cornerRadius: RRadius.sm))
                    .padding(.top, 18)
                    .padding(.horizontal, 20)
                }

                // This chip relays a network-wide aggregate over traffic that is
                // not ours, and its wording says so — the colour deliberately
                // does not borrow `theme.live`.
                //
                // "network-wide" rather than naming a supplier — see the note
                // in CountrySheet.providerTopCountries. The distinguishing work
                // is done by the closing sentence, which says plainly that we
                // have not tested it.
                // The pool-rate steer. Same rules as every other render of the
                // network figure: a colour-banded WORD via `NetworkRateMeter`
                // (never the percentage), hidden entirely while the owner has
                // the metric off, and a sentence that says plainly it is not
                // our own record. The country name is a proper noun, not a
                // claim, so it renders even when the meter does not.
                if let pool = poolSuggestion {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            FlagCircle(country: pool.country, size: 24)
                            Text(pool.country.name)
                                .font(RFont.text(13, weight: .semibold))
                                .foregroundStyle(theme.text)
                            Spacer(minLength: 8)
                            if state.showsDeliveryMetrics {
                                NetworkRateMeter(pct: pool.rate)
                            }
                        }
                        Text("The best network-wide delivery rate for this service right now. Not our own record — we haven't tested it ourselves.")
                            .font(RFont.text(13, weight: .medium))
                            .foregroundStyle(theme.text)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(theme.chipBg, in: .rect(cornerRadius: RRadius.sm))
                    .padding(.top, 18)
                    .padding(.horizontal, 20)
                }

                if let ranked = rankedSuggestion {
                    HStack(spacing: 8) {
                        FlagCircle(country: ranked.country, size: 24)
                        Text("\(ranked.country.name) ranks highest for \(context.service.name) network-wide: \(Int(ranked.rank.vendorPercent.rounded()))% in the last 24h. We haven't tested it ourselves yet.")
                            .font(RFont.text(13, weight: .medium))
                            .foregroundStyle(theme.text)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(theme.chipBg, in: .rect(cornerRadius: RRadius.sm))
                    .padding(.top, 18)
                    .padding(.horizontal, 20)
                }

                PrimaryButton(
                    label: suggestion.map { String(localized: "Try \($0.country.name)") }
                        ?? poolSuggestion.map { String(localized: "Try \($0.country.name)") }
                        ?? rankedSuggestion.map { String(localized: "Try \($0.country.name)") }
                        ?? String(localized: "Try again"),
                    sub: suggestion.flatMap { state.cost(for: context.service, country: $0.country) }
                        .map { "\($0) cr" }
                        ?? poolSuggestion.map { "\($0.price) cr" }
                        ?? rankedSuggestion.map { "\($0.price) cr" }
                        ?? String(localized: "Fresh number"),
                    icon: RIcon.refresh
                ) {
                    RHaptic.select()
                    // 🔴 PASS THE COUNTRY THE BUTTON JUST NAMED.
                    //
                    // This used to assign `state.lastCountry` and then call
                    // `retryFromRecovery()` with no argument — but that function
                    // never read `lastCountry`. It resolved
                    // `bestMeasuredCountry() ?? failedCountry`, and the ranked
                    // branch exists precisely when `bestMeasuredCountry` is nil,
                    // so the retry landed on THE COUNTRY THAT HAD JUST FAILED
                    // while the button said "Try Poland". Silent, and on the one
                    // screen every failed first order ends up at.
                    //
                    // nil on the measured branch keeps that path byte-identical:
                    // the function resolves the measured country itself.
                    state.retryFromRecovery(country: offeredCountry)
                }
                .padding(.top, 22)
                .padding(.horizontal, 20)

                Button {
                    state.dismissRecovery()
                } label: {
                    Text("Not now")
                        .font(RFont.text(14, weight: .medium))
                        .foregroundStyle(theme.text2)
                        .padding(.vertical, 6)
                }
                .pressable()
                .padding(.top, 14)
                .padding(.bottom, 24)
            }
        }
        .padding(.horizontal, 16)
    }
}
