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

    /// Our own record, as the raw pair — falling back to the percentage ONLY if
    /// the route somehow has no sample, which `deliveryRecord` treats as
    /// not-tested and we then do not claim at all.
    private func deliveryLine(for s: (country: Country, rate: Int)) -> LocalizedStringKey {
        if case .measured(let codes, let attempts) =
            state.deliveryRecord(for: context.service, country: s.country) {
            return "\(context.service.name) has worked \(codes) of the last \(attempts) times in \(s.country.name)."
        }
        return "\(context.service.name) has the best record we've measured in \(s.country.name)."
    }

    /// Fallback when we have measured nothing for this service — which is the
    /// common case, since route-level evidence covers a handful of routes.
    /// Only consulted when `suggestion` is nil: our own delivery always wins
    /// over a third party's, because it describes orders we actually placed.
    ///
    /// Never offers the country that just failed.
    private var rankedSuggestion: (country: Country, rank: CountryRank, price: Int)? {
        guard suggestion == nil else { return nil }
        return state.bestRankedCountry(for: context.service, excluding: context.failedCountry)
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
                if suggestion == nil, rankedSuggestion == nil {
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

                if let suggestion {
                    HStack(spacing: 8) {
                        FlagCircle(country: suggestion.country, size: 24)
                        // ⚠️ The RAW PAIR, never a percentage.
                        //
                        // This is OUR OWN measurement (`rate_source = 'measured'`),
                        // not a vendor aggregate, and the promotion gate is
                        // three conclusive attempts — so "67% measured" is
                        // routinely 2 of 3. `SuccessBadge` states the rule:
                        // a percentage off a 7-order sample wears the confidence
                        // of a 700-order one. This was the last surface in the
                        // app still breaking it, and the `>= 40` gate means the
                        // first values to appear are small-sample highs, i.e.
                        // exactly the case the rule exists for.
                        Text(deliveryLine(for: suggestion))
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

                // Deliberately styled apart from the measured chip above: that
                // one states what OUR orders did, this one relays a
                // network-wide aggregate over traffic that is not ours. Same
                // screen, two different kinds of claim, so the wording marks
                // the difference every time and the colour does not borrow
                // `theme.live`, which means "measured success" everywhere else.
                //
                // "network-wide" rather than naming a supplier — see the note
                // in CountrySheet.providerTopCountries. The distinguishing work
                // is done by the closing sentence, which says plainly that we
                // have not tested it.
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
                        ?? rankedSuggestion.map { String(localized: "Try \($0.country.name)") }
                        ?? String(localized: "Try again"),
                    sub: suggestion.flatMap { state.cost(for: context.service, country: $0.country) }
                        .map { "\($0) cr" }
                        ?? rankedSuggestion.map { "\($0.price) cr" }
                        ?? String(localized: "Fresh number"),
                    icon: RIcon.refresh
                ) {
                    RHaptic.select()
                    // Move the selection to the ranked country before retrying;
                    // otherwise the button would name one country and reorder
                    // the one that just failed. `retryFromRecovery` already
                    // handles the measured case internally.
                    if suggestion == nil, let ranked = rankedSuggestion {
                        state.lastCountry = ranked.country
                    }
                    state.retryFromRecovery()
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
