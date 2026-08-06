import SwiftUI

/// How the country list is ordered.
///
/// ⚠️ `.networkRate` was labelled **"Best success"**, and that label was a
/// claim the app cannot back. It sorts on `routes.pool_rate_pct` — a rate
/// published across the whole network, for every customer's orders, not ours —
/// while the same screen has to say in as many words that this is *not* our own
/// delivery record. A sort name is read as a promise about what comes out of
/// it, so it now names the thing it actually sorts on and claims no ownership
/// of the outcome. What we measured ourselves is a FILTER ("Tested by us"), not
/// a sort, because with route-level evidence on a handful of routes a sort by it
/// is a sort by nothing.
enum CountrySort: String, Hashable, CaseIterable {
    case networkRate, cheapest, `default`

    /// `String(localized:)`, not a bare literal: a plain `String` returned from
    /// a property never enters the string catalog, so these shipped English to
    /// all six locales. (`ChipButton` re-wraps in `LocalizedStringKey`, which is
    /// a harmless no-op once the value is already resolved.)
    var label: String {
        switch self {
        case .networkRate: String(localized: "Network rate")
        case .cheapest:    String(localized: "Cheapest")
        case .default:     String(localized: "A–Z")
        }
    }

    var icon: String {
        switch self {
        case .networkRate: "chart.bar.fill"
        case .cheapest:    RIcon.coin
        case .default:     RIcon.filter
        }
    }
}

/// Pick the country a number is bought in, for the service already chosen.
///
/// ── What the 2026-08 audit found here ────────────────────────────────────
///
/// **There was no search.** 69 countries, 468 services' worth of prices behind
/// them, and the only navigation was three sort chips. `ServiceSheet` had a
/// search field; this did not. It now shares one — see `SheetSearchField` — and
/// matches on the **dial code** as well as the name, because "+40" is how
/// people who care about the number itself look for a country.
///
/// **A 33-word legend sat above the first row.** It explained a colour
/// convention before any colour had been seen, in 11pt, and pushed the first
/// country below the fold on a small phone. Nobody reads a key to a map they
/// have not looked at yet. The definition now lives behind the ⓘ on the sort
/// chip, and the figure itself carries the word `network` inline so it needs no
/// key at all.
///
/// **Two colour-coded percentages, meaning different things, sat on every
/// row** — the network rate on the left and our own record on the right. The
/// old file's own comment admitted colour no longer told them apart. They are
/// now told apart by SHAPE: an aggregate reads as a **bar**, our record reads as
/// a **bordered chip that says "Ours"**. Colour is left to do the one job it is
/// good at, magnitude, from the single shared `DeliveryBand` scale.
struct CountrySheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state
    var onPick: (Country) -> Void

    @State private var sort: CountrySort = .networkRate
    @State private var query: String = ""
    /// Only countries we have actually ordered in, for this service.
    @State private var testedOnly = false
    @State private var showRateInfo = false
    @State private var appeared = false

    /// The service the user is currently configuring. Must go through
    /// `configuringService` — reading `checkoutService ?? lastService` here is
    /// what priced this whole sheet for the last checked-out service while
    /// Home showed a different one.
    private var currentService: Service { state.configuringService }

    private func price(_ c: Country) -> Int? {
        state.cost(for: currentService, country: c)
    }
    private func rate(_ c: Country) -> Int? {
        state.poolRate(for: currentService, country: c)
    }
    private func record(_ c: Country) -> DeliveryRecord {
        state.deliveryRecord(for: currentService, country: c)
    }

    // MARK: - Filtering

    /// Name **or** dial code, digits-normalised.
    ///
    /// Typing "+40" and typing "40" have to find the same row: the leading `+`
    /// is punctuation the user may or may not bother with, and matching the raw
    /// string would have made one work and the other fail. Dial codes match on
    /// PREFIX rather than `contains`, so "44" finds the UK instead of every
    /// country whose code happens to contain those digits.
    private func matches(_ c: Country, query q: String) -> Bool {
        guard !q.isEmpty else { return true }
        if c.name.lowercased().contains(q) { return true }
        let digits = q.filter(\.isNumber)
        guard !digits.isEmpty else { return false }
        return c.dialCode.filter(\.isNumber).hasPrefix(digits)
    }

    private var visible: [Country] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var list = state.availableCountries.filter { c in
            guard matches(c, query: q) else { return false }
            // `.ratio` is non-nil only for a MEASURED record with a real
            // sample, which is exactly what "tested" means here.
            guard !testedOnly || record(c).ratio != nil else { return false }
            return true
        }

        switch sort {
        case .default:
            break
        case .cheapest:
            // Unavailable routes (nil price) sink to the bottom of the list.
            let costFor: (Country) -> Int = { price($0) ?? .max }
            list.sort { costFor($0) < costFor($1) }
        case .networkRate:
            // Buyable first, then by the published rate, then price.
            //
            // Unrated scores -1 so it sorts strictly below a genuine 0% — the
            // two are different claims: "nobody has ordered enough here" is not
            // "this fails". Price breaks ties.
            func key(_ c: Country) -> (Int, Int, Int) {
                let p = price(c)
                return (p == nil ? 1 : 0, -(rate(c) ?? -1), p ?? .max)
            }
            list.sort { key($0) < key($1) }
        }
        return list
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Choose a country")
            SheetSearchField(placeholder: "Search country or dial code", text: $query)
            filterRow
            ScrollView {
                if visible.isEmpty {
                    emptyState
                        .padding(.top, 12)
                } else {
                    listCard
                }
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
        }
        .background(theme.bg)
        .onAppear { appeared = true }
    }

    private var listCard: some View {
        // `.flat` on purpose: this card is as tall as the catalog, and a real
        // drop shadow on a 4,000pt surface is paid for on every frame of every
        // scroll. Depth here comes from `theme.elev` against `theme.bg`.
        Card(elevation: .flat) {
            LazyVStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { idx, c in
                    CountryRow(country: c,
                               price: price(c),
                               record: record(c),
                               poolRate: rate(c),
                               balance: state.balance,
                               selected: c.id == state.configuringCountry.id,
                               isLast: idx == visible.count - 1) {
                        RHaptic.select()
                        onPick(c)
                        dismiss()
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 24)
        .riseIn(appeared)
    }

    // MARK: - Filters

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(CountrySort.allCases, id: \.self) { option in
                    ChipButton(label: option.label,
                               icon: option.icon,
                               active: sort == option) {
                        guard sort != option else { return }
                        RHaptic.select()
                        withAnimation(RMotion.content) { sort = option }
                    }
                    // The definition of the number this sort ranks on, one tap
                    // away from the control that ranks on it — instead of a
                    // paragraph everyone scrolls past to reach the list.
                    if option == .networkRate { rateInfoButton }
                }

                Rectangle()
                    .fill(theme.sep)
                    .frame(width: 0.5, height: 20)
                    .padding(.horizontal, 2)

                ChipButton(label: String(localized: "Tested by us"),
                           icon: RIcon.shield,
                           active: testedOnly,
                           soft: true) {
                    RHaptic.select()
                    withAnimation(RMotion.content) { testedOnly.toggle() }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 10)
    }

    private var rateInfoButton: some View {
        Button {
            showRateInfo = true
        } label: {
            Image(systemName: RIcon.info)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(showRateInfo ? theme.accent2 : theme.text3)
                .frame(width: 26, height: 26)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("What the network rate means"))
        .popover(isPresented: $showRateInfo) {
            rateInfoCard
                .presentationCompactAdaptation(.popover)
        }
    }

    /// What the number is, and — just as importantly — what it is not.
    ///
    /// It names no supplier: "network-wide" is how the distinction between a
    /// third party's aggregate and our own orders gets drawn without
    /// advertising that we resell someone else's inventory.
    ///
    /// ⚠️ It deliberately quotes **no time window**. The stored figure is the
    /// pool's 7-day rate where the pool saw traffic that week and its 30-day
    /// rate otherwise, and which one a given row carries is not something the
    /// client can see. The old legend said "the last 30 days" for every row,
    /// which stopped being true for most of them.
    private var rateInfoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What the rate means")
                .font(RFont.display(15, weight: .semibold))
                .foregroundStyle(theme.text)

            Text("How often codes have been arriving on this route network-wide — across everyone's orders, not just ours.")
                .font(RFont.text(13))
                .foregroundStyle(theme.text2)
                .fixedSize(horizontal: false, vertical: true)

            Text("It is not our own delivery record. Where we have ordered here ourselves, the row says so separately.")
                .font(RFont.text(13))
                .foregroundStyle(theme.text2)
                .fixedSize(horizontal: false, vertical: true)

            RowRule(inset: 0)
                .padding(.vertical, 2)

            // These MUST match `NetworkRateBar.color`. A legend that disagrees
            // with the thing it explains is worse than no legend — it teaches
            // the user a rule the screen then breaks.
            VStack(alignment: .leading, spacing: 6) {
                bandLegend(theme.live, label: "Above 60%")
                bandLegend(theme.warn, label: "30–60%")
                bandLegend(theme.fail, label: "Under 30%")
            }
        }
        .padding(16)
        .frame(width: 286)
        .background(theme.elev)
    }

    private func bandLegend(_ tint: Color, label: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(tint)
                .frame(width: 18, height: 4)
            Text(label)
                .font(RFont.text(12, weight: .medium))
                .foregroundStyle(theme.text2)
        }
    }

    // MARK: - Empty

    /// The sheet used to render its paragraph above an EMPTY card when the list
    /// came back with nothing — a legend explaining the colours of rows that
    /// were not there.
    @ViewBuilder
    private var emptyState: some View {
        if state.availableCountries.isEmpty {
            // Not the same situation as "your filters matched nothing", and the
            // old code could not tell them apart because it rendered neither.
            EmptyState(icon: RIcon.globe,
                       title: "Countries aren't loaded yet",
                       message: "Close this and pull the app to refresh, or try again in a moment.")
        } else {
            EmptyState(icon: RIcon.search,
                       title: "No countries match",
                       message: emptyMessage,
                       primary: (label: String(localized: "Clear filters"),
                                 action: {
                                     RHaptic.select()
                                     withAnimation(RMotion.content) {
                                         query = ""
                                         testedOnly = false
                                     }
                                 }))
        }
    }

    /// Names the filter that is actually responsible, rather than shrugging.
    private var emptyMessage: LocalizedStringKey {
        if testedOnly {
            return "We haven't ordered \(currentService.name) anywhere that matches yet. Untested countries are still buyable."
        }
        return "Nothing here matches that name or dial code."
    }
}

// MARK: - Row

private struct CountryRow: View {
    @Environment(\.theme) private var theme
    let country: Country
    let price: Int?
    let record: DeliveryRecord
    /// The network's published rate for this route's pool. nil = unrated;
    /// render nothing. Never "0%" — a missing figure and a measured zero are
    /// different claims.
    let poolRate: Int?
    let balance: Int
    let selected: Bool
    let isLast: Bool
    let onTap: () -> Void

    private var unavailable: Bool { price == nil }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    FlagCircle(country: country, size: 36)
                        .opacity(unavailable ? 0.45 : 1)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(country.name)
                                .font(RFont.display(16, weight: .semibold))
                                .tracking(-0.3)
                                .foregroundStyle(unavailable ? theme.text2 : theme.text)
                                .lineLimit(1)
                            if selected {
                                Image(systemName: RIcon.check)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(theme.accent2)
                                    .accessibilityLabel(Text("Currently selected"))
                            }
                        }

                        HStack(spacing: 8) {
                            MonoText(country.dialCode, size: 12, color: theme.text3)
                            if let poolRate {
                                NetworkRateMeter(pct: poolRate)
                            }
                        }
                    }

                    Spacer(minLength: 0)

                    VStack(alignment: .trailing, spacing: 5) {
                        if let price {
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text("\(price)")
                                    .font(RFont.display(15, weight: .semibold))
                                    .foregroundStyle(price <= balance ? theme.text : theme.text2)
                                    .monospacedDigit()
                                Text("cr")
                                    .font(RFont.text(12, weight: .medium))
                                    .foregroundStyle(theme.text2)
                            }
                        } else {
                            Text("Unavailable")
                                .font(RFont.text(12, weight: .medium))
                                .foregroundStyle(theme.text3)
                        }

                        // OUR record, and only when there is one.
                        //
                        // It used to be a `SuccessBadge` rendered on every row,
                        // including "Not tested" — a filled capsule the same
                        // shape and the same palette as the vendor figure two
                        // inches to its left. The rule that badge enforces
                        // (never let an absent badge read as reassurance) is
                        // carried here by the meter, which is on every rated row
                        // and says `network` in words: nothing on this row can
                        // be mistaken for a claim about our own orders.
                        if case let .measured(codes, attempts) = record, attempts > 0 {
                            OurRecordChip(codes: codes, attempts: attempts)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(selected ? theme.inkSoft.opacity(0.5) : .clear)
                .contentShape(.rect)

                if !isLast { RowRule(inset: 62) }
            }
        }
        .pressable()
    }
}

/// The network's published rate, drawn as a **bar**.
///
/// The shape is the point. A bar reads as a proportion of a population —
/// an aggregate somebody else measured — where a bare tinted percentage sitting
/// beside our own tinted percentage read as two of the same kind of thing. The
/// word `network` rides along with it so the row is self-describing and the
/// screen needs no legend above the list.
///
/// Colour comes from `DeliveryBand`, the app's single delivery-tint definition,
/// rather than from a fourth private set of thresholds declared in this file.
private struct NetworkRateMeter: View {
    @Environment(\.theme) private var theme
    let pct: Int

    private static let barWidth: CGFloat = 38

    private var clamped: Int { min(100, max(0, pct)) }

    /// 🔴 **The network figure keeps its OWN thresholds — >60 green, 30–60
    /// amber, <30 red — and must not be folded into `DeliveryBand`.**
    ///
    /// Two reasons, and the second is the substantive one:
    ///
    /// 1. They are an explicit owner decision (2026-08-03), recorded in
    ///    CLAUDE.md against this exact view.
    /// 2. **The two numbers on this row are not on the same scale.** This is a
    ///    third party's network-wide rate across all its customers; the chip
    ///    beside it is what happened when *we* ordered. Measured over every
    ///    non-cancelled order, a published 80+ realised ~40% and 60–79 realised
    ///    ~25% — the published figure runs roughly double. Colouring both with
    ///    one threshold set would call a 55% network rate "good" on the same
    ///    scale that calls a 55% record of ours "good", when the first predicts
    ///    something closer to 25%.
    ///
    /// Sharing a tint FUNCTION across two different measurements is exactly the
    /// conflation the two shapes on this row exist to prevent.
    private var color: Color {
        if clamped > 60 { return theme.live }
        if clamped >= 30 { return theme.warn }
        return theme.fail
    }

    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.track)
                    .frame(width: Self.barWidth, height: 4)
                Capsule()
                    .fill(color)
                    // A floor of 3pt so a 1% route still draws something: a bar
                    // of literally zero width is indistinguishable from an
                    // unrated route, which renders no bar at all.
                    .frame(width: max(3, Self.barWidth * CGFloat(clamped) / 100), height: 4)
            }

            Text("\(clamped)%")
                .font(RFont.text(12, weight: .bold))
                .foregroundStyle(color)
                .monospacedDigit()

            Text("network")
                .font(RFont.text(11))
                .foregroundStyle(theme.text3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Network-wide delivery rate \(clamped) percent"))
    }
}

/// What happened when **we** ordered here, drawn as a bordered chip.
///
/// An outline rather than the filled capsule `SuccessBadge` uses, so the two
/// numbers on a row differ in shape before they differ in colour — and the word
/// "Ours" so it is not merely *positionally* distinct from the network figure.
/// The raw pair, never a percentage: "3 of 7" carries its own uncertainty where
/// "43%" wears the confidence of a 700-order sample.
private struct OurRecordChip: View {
    @Environment(\.theme) private var theme
    let codes: Int
    let attempts: Int

    private var tint: Color {
        guard let band = DeliveryBand.of(codes: codes, attempts: attempts) else {
            return theme.text2
        }
        return theme.deliveryColor(band)
    }

    var body: some View {
        Text("Ours: \(codes) of \(attempts)")
            .font(RFont.text(11, weight: .semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 1))
    }
}
