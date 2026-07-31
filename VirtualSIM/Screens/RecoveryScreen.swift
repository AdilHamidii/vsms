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
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var card: some View {
        Card {
            VStack(spacing: 0) {
                ServiceLogo(service: context.service, size: 52)
                    .padding(.top, 28)
                Text(headline)
                    .font(RFont.display(21, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(theme.text)
                    .padding(.top, 14)
                Text("You weren't charged — your credits are back in your balance.")
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

                if let suggestion {
                    HStack(spacing: 8) {
                        FlagCircle(country: suggestion.country, size: 24)
                        Text("\(context.service.name) delivers best in \(suggestion.country.name) right now — \(suggestion.rate)% measured.")
                            .font(RFont.text(13, weight: .medium))
                            .foregroundStyle(theme.text)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(theme.chipBg, in: .rect(cornerRadius: 14))
                    .padding(.top, 18)
                    .padding(.horizontal, 20)
                }

                // Deliberately styled apart from the measured chip above: that
                // one states what OUR orders did, this one relays what the
                // provider reports across all of their customers. Same screen,
                // two different kinds of claim, so the wording attributes it
                // every time and the colour does not borrow `theme.live`, which
                // means "measured success" everywhere else in the app.
                if let ranked = rankedSuggestion {
                    HStack(spacing: 8) {
                        FlagCircle(country: ranked.country, size: 24)
                        Text("Our provider ranks \(ranked.country.name) highest for \(context.service.name) — they report \(Int(ranked.rank.vendorPercent.rounded()))% there in the last 24h. We haven't tested it ourselves yet.")
                            .font(RFont.text(13, weight: .medium))
                            .foregroundStyle(theme.text)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(theme.chipBg, in: .rect(cornerRadius: 14))
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
                }
                .buttonStyle(.plain)
                .padding(.top, 14)
                .padding(.bottom, 24)
            }
        }
        .padding(.horizontal, 16)
    }
}
