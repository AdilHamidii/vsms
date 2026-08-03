import SwiftUI

enum CountrySort: String, Hashable, CaseIterable {
    case bestSuccess, cheapest, `default`

    var label: String {
        switch self {
        case .bestSuccess: "Best success"
        case .cheapest:    "Cheapest"
        case .default:     "A–Z"
        }
    }
    var icon: String {
        switch self {
        case .bestSuccess: RIcon.shield
        case .cheapest:    RIcon.coin
        case .default:     RIcon.filter
        }
    }
}

struct CountrySheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state
    var onPick: (Country) -> Void

    // Default to Best success — steer users onto the countries that actually
    // deliver for this service instead of the cheapest/first one.
    @State private var sort: CountrySort = .bestSuccess

    /// The service the user is currently configuring. Must go through
    /// `configuringService` — reading `checkoutService ?? lastService` here is
    /// what priced this whole sheet for the last checked-out service while
    /// Home showed a different one.
    private var currentService: Service { state.configuringService }

    private var sorted: [Country] {
        var list = state.availableCountries
        switch sort {
        case .default:  break
        case .cheapest:
            // Unavailable routes (nil price) sink to the bottom of the list.
            let costFor: (Country) -> Int = {
                state.cost(for: currentService, country: $0) ?? .max
            }
            list.sort { costFor($0) < costFor($1) }
        case .bestSuccess:
            // Available first, then by EVIDENCE tier, then price.
            // Tiers: proven → untested → proven-bad. Untested ties break to
            // the CHEAPEST: the old pricier-first rule was a SMSPool-era pool
            // heuristic; SMSPVA carrier prices carry no quality signal, so it
            // just floated the most expensive countries to the top.
            //
            // Tiering is on MEASURED evidence only. It used to read
            // `successRate`, which includes SMSPVA's seeded per-country grade —
            // so a route we had never sold was filed under "proven" and sorted
            // above genuinely untested ones. 323 routes carry a seeded rate
            // against 10 measured, so "Best success" was mostly sorting on a
            // vendor's opinion of its own inventory.
            //
            // Within the untested block, order by the COUNTRY's own measured
            // record before price. Ranking untested routes by price put the
            // cheapest country in the catalog at the top of "Best success" for
            // almost every service — which is Colombia, and its two measured
            // routes read 1 of 3 and 0 of 2. A sort literally labelled "Best
            // success" was leading with the bargain bin.
            // Since 1.7 the provider's reported rate ranks the untested block,
            // ahead of the country's record and ahead of price. It is specific
            // to THIS (service, country) pair, where countryRatio is that
            // country's record across every service — so it is the better
            // signal wherever we have it, and it is the reason this sort now
            // leads with countries that actually deliver rather than with
            // whatever happens to be cheapest.
            //
            // Our OWN measurement still wins outright (tier 0 / tier 4 below):
            // a third party's aggregate never outranks orders we placed.
            // A missing vendor rate scores 0 — neutral, never a penalty, since
            // the source is a top-10 list and absence carries no information.
            // Rank by the pool's published delivery rate, high to low, with
            // UNRATED countries below every rated one and unbuyable ones last.
            //
            // This replaced a five-tier scheme built on our own measured record
            // plus a country-level roll-up. That mattered when essentially no
            // route had a rate; now every sellable route carries one and the
            // user can SEE it on the row, so a hidden ordering that disagrees
            // with the visible number is worse than no cleverness at all.
            //
            // Unrated scores -1 so it sorts strictly below a genuine 0% — the
            // two are different claims: "nobody has ordered enough here" is not
            // "this fails". Price breaks ties.
            func key(_ c: Country) -> (Int, Int, Int) {
                let price = state.cost(for: currentService, country: c) ?? .max
                let avail = state.cost(for: currentService, country: c) != nil ? 0 : 1
                let rate = state.poolRate(for: currentService, country: c) ?? -1
                return (avail, -rate, price)
            }
            list.sort { key($0) < key($1) }
        }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Choose a country")
            sortRow
            ScrollView {
                rateHint
                Card {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(sorted.enumerated()), id: \.element.id) { idx, c in
                            CountryRow(country: c,
                                       price: state.cost(for: currentService, country: c),
                                       record: state.deliveryRecord(for: currentService, country: c),
                                       poolRate: state.poolRate(for: currentService, country: c),
                                       balance: state.balance,
                                       isLast: idx == sorted.count - 1) {
                                onPick(c)
                                dismiss()
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 24)
            }
        }
        .background(theme.bg)
    }
    /// One line of guidance instead of a separate "top rates" card.
    ///
    /// The card was removed once EVERY row started carrying its own
    /// colour-coded percentage: it restated a subset of the list directly above
    /// the list, and the two could drift apart. A sentence that tells the user
    /// what the colour means is worth more than a second ranking of the same
    /// data.
    ///
    /// The wording keeps the two properties the old caption had to hold at
    /// once: it says what the number IS (a network-wide delivery rate over 30
    /// days, matching 5sim's rate720) and what it is NOT (our own record), and
    /// it names no supplier.
    private var rateHint: some View {
        Text("Pick a country with a high percentage — that's how often codes arrive there network-wide over the last 30 days. It isn't our own delivery record.")
            .font(RFont.text(11))
            .foregroundStyle(theme.text2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 10)
    }

    private var sortRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(CountrySort.allCases, id: \.self) { option in
                    ChipButton(label: option.label,
                               icon: option.icon,
                               active: sort == option) {
                        sort = option
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 12)
    }
}

private struct CountryRow: View {
    @Environment(\.theme) private var theme
    let country: Country
    let price: Int?
    let record: DeliveryRecord
    /// Provider's published rate for this route's pool. nil = unrated; render nothing.
    let poolRate: Int?
    let balance: Int
    let isLast: Bool
    let onTap: () -> Void

    /// Colour bands for the pool's published rate: >60 green, 30-60 amber,
    /// <30 red (owner decision, 2026-08-03; first set at 75/40, lowered the
    /// same day because 84% of rated routes fell in the red band).
    ///
    /// These are the SAME semantic colours SuccessBadge uses for OUR measured
    /// record, and at nearly the same thresholds (>=70 / >=40). So on a row
    /// carrying both, colour no longer distinguishes them — only position (this
    /// one sits in the left column, beside the dial code) and wording ("74%"
    /// versus "Worked 3 of 7 times") do. Noted because the standing rule was
    /// that a third party's number must never wear `theme.live`; this is a
    /// deliberate exception, not an oversight.
    private func poolRateColor(_ pct: Int) -> Color {
        if pct > 60 { return theme.live }
        if pct >= 30 { return theme.warn }
        return theme.fail
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    FlagCircle(country: country, size: 36)
                        .opacity(price == nil ? 0.45 : 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(country.name)
                            .font(RFont.display(16, weight: .semibold))
                            .tracking(-0.3)
                            .foregroundStyle(price == nil ? theme.text2 : theme.text)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            MonoText(country.dialCode, size: 12, color: theme.text2)
                            // The pool's published delivery rate. Left column,
                            // deliberately: the right column is SuccessBadge,
                            // which is OUR measured record, and a vendor
                            // percentage sitting next to "Worked 2 of 7" is
                            // exactly the conflation that had to be undone
                            // once already. Never theme.live/warn/fail —
                            // those colours are a claim about our own data.
                            // nil renders NOTHING, never "0%".
                            if let poolRate {
                                Text("\(poolRate)%")
                                    .font(RFont.text(12, weight: .semibold))
                                    .foregroundStyle(poolRateColor(poolRate))
                            }
                            // countries.avg_seconds is seed data too — drop
                            // the claim rather than dress it up. The measured
                            // band lives on Service, not Country.

                        }
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 4) {
                        if let price {
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text("\(price)")
                                    .font(RFont.display(15, weight: .semibold))
                                    .foregroundStyle(price <= balance ? theme.text : theme.text2)
                                Text("cr")
                                    .font(RFont.text(12, weight: .medium))
                                    .foregroundStyle(theme.text2)
                            }
                        } else {
                            Text("Unavailable")
                                .font(RFont.text(12, weight: .medium))
                                .foregroundStyle(theme.text3)
                        }
                        // Always rendered — see DeliveryRecord. A missing
                        // badge used to read as "fine" on every untested route.
                        SuccessBadge(record: record, compact: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(.rect)
                if !isLast {
                    Rectangle().fill(theme.sep).frame(height: 0.5)
                        .padding(.leading, 62)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
