import SwiftUI

/// Pick the service a number (or an e-mail address) is being bought FOR, with
/// the country already chosen.
///
/// ── What the 2026-08 audit found here ────────────────────────────────────
///
/// **468 rows in raw catalog order, no ranking, no shortcuts, and nothing
/// marking the service already selected.** Search was the only navigation, so
/// the sheet only worked if you already knew the answer. It is now sectioned —
/// **Recent** (what this user has actually ordered), **Popular** (the curated
/// shortlist), then **All** — and it opens scrolled to the current selection.
///
/// **Two of the six data points on a row could not vary.** `category` restated
/// the category chip in the filter row directly above it, and `typicalWaitShort`
/// is a per-SERVICE constant that does not move with anything being chosen on
/// this screen — a number on every row that was the same number on every row.
/// Both are gone; price and delivery evidence stay, because those are what the
/// choice is between.
///
/// **The relocation warning was a caption.** When a service has no route in the
/// selected country, tapping it silently CHANGES THE USER'S COUNTRY — and the
/// only warning was a small grey country name in the row's trailing corner. A
/// country change is not a caption-sized event; it is now a full-width strip on
/// a caution wash that says, in a sentence, what the tap will do.
struct ServiceSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state
    var onPick: (Service) -> Void

    @State private var query: String = ""
    @State private var category: String = "All"
    @State private var affordableOnly = false
    @State private var appeared = false

    /// The country the user is currently configuring. Prices shown per service
    /// are the REAL synced route price for this country (mirrors CountrySheet,
    /// which fixes the service and varies the country). Goes through
    /// `configuringCountry` for the same reason CountrySheet does — the raw
    /// `checkoutCountry ?? lastCountry` priced the list for a stale draft.
    private var currentCountry: Country { state.configuringCountry }

    /// Services a first-run user plausibly recognises, used here purely as a
    /// browse shortcut past 468 alphabetical rows.
    ///
    /// ⚠️ **This is a SECOND copy of the `preferred` shortlist in
    /// `AppState.affordableStarter()`**, which is a local constant inside a
    /// private method and cannot be read from a view. Keep them in step. They
    /// answer different questions — that one is the candidate set for the ONE
    /// route a brand-new user is pointed at, this one is a table of contents —
    /// so they may legitimately diverge, but they must never drift by accident.
    /// Neither is a ranking: order here is presentation order only.
    private static let popularIds = [
        "leboncoin", "deliveroo", "glovo", "whatnot", "walmart",
        "vinted", "wallapop", "subito", "olx", "uber",
        "tiktok", "discord"
    ]

    // MARK: - Filtering

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The Affordable chip is meaningless in e-mail mode and must not render
    /// there — see `matchesAffordable`. A control that is visibly present,
    /// visibly toggles, and changes nothing is worse than no control.
    private var showsAffordableFilter: Bool { !state.emailMode }

    private var filtersActive: Bool {
        !trimmedQuery.isEmpty || category != "All" || affordableOnly
    }

    private var filtered: [Service] {
        let q = trimmedQuery
        return state.services.filter { s in
            let matchesQuery = q.isEmpty
                || s.name.lowercased().contains(q)
                || s.category.lowercased().contains(q)
            let matchesCategory = (category == "All") || (s.category == category)
            return matchesQuery && matchesCategory && matchesAffordable(s)
        }
    }

    /// When the Affordable toggle is on, keep only services the balance can
    /// actually buy — judged against the price the row SHOWS.
    ///
    /// This used to test `cost(for:country:)` alone, so every service without a
    /// route in the current country failed the `guard` and was dropped, even
    /// when it was cheaply bookable one tap away. The filter and the list have
    /// to agree on what a row costs, or "Affordable" hides affordable things.
    private func matchesAffordable(_ s: Service) -> Bool {
        guard affordableOnly else { return true }
        // The toggle filters on the SMS route price, which does not exist in
        // email mode — an email is 1 credit or free depending on the domain,
        // and every service is equally affordable. Filtering on a price that
        // does not apply would silently hide most of the catalog. The chip is
        // also hidden there, so this is belt and braces.
        guard !state.emailMode else { return true }
        guard let c = state.cost(for: s, country: currentCountry)
                ?? state.pickDestination(for: s)?.credits else { return false }
        return c <= state.balance
    }

    // MARK: - Sections

    private struct ServiceGroup: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let services: [Service]
    }

    /// Services this user has ordered before, newest first, deduped, capped.
    ///
    /// Resolved back through `state.services` rather than used straight off the
    /// order, so a row here is the same catalog object every other row is —
    /// an order carries the service as it was AT PURCHASE, which can be stale.
    private var recentServices: [Service] {
        var seen = Set<String>()
        var out: [Service] = []
        for order in state.orders.sorted(by: { $0.createdAt > $1.createdAt }) {
            guard seen.insert(order.service.id).inserted else { continue }
            guard let live = state.services.first(where: { $0.id == order.service.id })
            else { continue }
            out.append(live)
            if out.count == 4 { break }
        }
        return out
    }

    /// Sections only exist in the unfiltered browse state. Once the user has
    /// typed or picked a category they have expressed the ordering they want,
    /// and slicing their results into three buckets buries matches.
    private var sections: [ServiceGroup] {
        let all = filtered
        guard !filtersActive else {
            return [ServiceGroup(id: "results", title: "Results", services: all)]
        }

        var out: [ServiceGroup] = []
        let ids = Set(all.map(\.id))

        let recent = recentServices.filter { ids.contains($0.id) }
        if !recent.isEmpty {
            out.append(ServiceGroup(id: "recent", title: "Recent", services: recent))
        }

        let recentIds = Set(recent.map(\.id))
        let popular = Self.popularIds
            .filter { !recentIds.contains($0) }
            .compactMap { id in all.first { $0.id == id } }
        if !popular.isEmpty {
            out.append(ServiceGroup(id: "popular", title: "Popular", services: popular))
        }

        out.append(ServiceGroup(id: "all", title: "All services", services: all))
        return out
    }

    /// The scroll id of the currently-selected service, in the first section
    /// that contains it. Landing on the copy nearest the top means opening the
    /// sheet does not skip past Recent and Popular to reach the same row 200
    /// entries down.
    private var scrollTarget: String? {
        let selected = state.configuringService.id
        for section in sections where section.services.contains(where: { $0.id == selected }) {
            return "\(section.id)-\(selected)"
        }
        return nil
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: state.emailMode
                        ? String(localized: "Choose a site")
                        : String(localized: "Choose a service"))
            SheetSearchField(placeholder: "Search service", text: $query)
            categoryRow
            list
        }
        .background(theme.bg)
        .onAppear { appeared = true }
    }

    private var categoryRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if showsAffordableFilter {
                    ChipButton(label: String(localized: "Affordable"),
                               icon: RIcon.coin,
                               active: affordableOnly, soft: true) {
                        RHaptic.select()
                        withAnimation(RMotion.content) { affordableOnly.toggle() }
                    }
                    Rectangle()
                        .fill(theme.sep)
                        .frame(width: 0.5, height: 20)
                        .padding(.horizontal, 2)
                }
                ForEach(serviceCategories, id: \.self) { cat in
                    ChipButton(label: cat, active: category == cat, soft: true) {
                        guard category != cat else { return }
                        RHaptic.select()
                        withAnimation(RMotion.content) { category = cat }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 10)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if filtered.isEmpty {
                    emptyState
                        .padding(.top, 12)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            sectionView(section)
                        }
                    }
                    .padding(.bottom, 24)
                    .riseIn(appeared)
                }
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .task {
                guard let target = scrollTarget else { return }
                // One frame for the lazy stack to lay out before asking it to
                // find a row 200 entries down.
                try? await Task.sleep(nanoseconds: 120_000_000)
                proxy.scrollTo(target, anchor: .center)
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: ServiceGroup) -> some View {
        MicroLabel(section.title)
            .padding(.horizontal, 20)
            .padding(.top, section.id == "results" ? 4 : 16)
            .padding(.bottom, 8)

        // `.flat` for the long section: a real shadow on a card as tall as the
        // whole catalog is paid for on every scroll frame.
        Card(elevation: section.services.count > 24 ? .flat : .raised) {
            LazyVStack(spacing: 0) {
                ForEach(section.services) { service in
                    row(service, in: section)
                        .id("\(section.id)-\(service.id)")
                    if service.id != section.services.last?.id {
                        RowRule(inset: 66)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func row(_ service: Service, in section: ServiceGroup) -> some View {
        // In email mode the SMS route price is meaningless — an email costs
        // 1 credit or nothing depending on the DOMAIN picked next, not on the
        // service — and the SMS delivery record describes a different product.
        // Passing nil for both makes the row show neither.
        let here = state.emailMode
            ? nil : state.cost(for: service, country: currentCountry)
        // Only resolved when there is no route here, so the 69-country scan
        // never runs for the common case.
        let elsewhere = (here == nil && !state.emailMode)
            ? state.pickDestination(for: service) : nil

        ServiceRow(service: service,
                   price: here,
                   elsewhere: elsewhere,
                   emailMode: state.emailMode,
                   // The provider needs a target site, which we take from
                   // `service.domain`; some services have none and cannot
                   // offer email at all.
                   emailSupported: !(service.domain ?? "").isEmpty,
                   // The badge must describe the route the tap actually buys.
                   // Scored against the current country it would read "Not
                   // tested" for a destination route we HAVE measured.
                   record: state.deliveryRecord(
                       for: service,
                       country: elsewhere?.country ?? currentCountry),
                   balance: state.balance,
                   selected: service.id == state.configuringService.id) {
            RHaptic.select()
            onPick(service)
            dismiss()
        }
    }

    // MARK: - Empty

    /// "No services found" told the user nothing about WHY, named neither the
    /// query nor the category responsible, and offered no way back.
    private var emptyState: some View {
        EmptyState(icon: RIcon.search,
                   title: "Nothing matches",
                   message: emptyMessage,
                   primary: (label: String(localized: "Clear filters"),
                             action: {
                                 RHaptic.select()
                                 withAnimation(RMotion.content) {
                                     query = ""
                                     category = "All"
                                     affordableOnly = false
                                 }
                             }))
    }

    private var emptyMessage: LocalizedStringKey {
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty && category != "All" {
            return "No service called “\(q)” in \(category)."
        }
        if !q.isEmpty {
            return "No service called “\(q)”."
        }
        if affordableOnly {
            return "Nothing in \(category == "All" ? String(localized: "the catalog") : category) fits your \(state.balance) credits."
        }
        if category != "All" {
            return "No services in \(category) are bookable right now."
        }
        return "The catalog hasn't loaded yet."
    }
}

// MARK: - Row

private struct ServiceRow: View {
    @Environment(\.theme) private var theme
    let service: Service
    /// Real synced route price for the currently-selected country, or nil when
    /// the (service, country) pair has no confirmed price (unavailable to book).
    let price: Int?
    /// Set only when `price` is nil: where this service IS bookable, and what
    /// it costs there. Exactly where tapping the row will land the user.
    let elsewhere: (country: Country, credits: Int)?
    /// Picking a service for an EMAIL address rather than a number.
    var emailMode: Bool = false
    /// Only meaningful in email mode: does this service have a target site?
    var emailSupported: Bool = true
    let record: DeliveryRecord
    let balance: Int
    let selected: Bool
    let onTap: () -> Void

    /// Bookable nowhere — the one case that is genuinely unavailable, and so
    /// the only one that may say so or look disabled. In email mode that means
    /// "no domain to bind an address to" instead.
    private var isDeadEnd: Bool {
        emailMode ? !emailSupported : (price == nil && elsewhere == nil)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                mainRow
                // The country change gets a full-width strip, not a caption.
                if let elsewhere { relocationStrip(elsewhere.country) }
            }
            .background(selected ? theme.inkSoft.opacity(0.5) : .clear)
            .contentShape(.rect)
        }
        .pressable()
        // A dead end must not be tappable: bestCountry returns nil, so the tap
        // would set the service without moving the country and strand the user
        // on a Home screen whose only button is a disabled "Unavailable".
        .disabled(isDeadEnd)
    }

    private var mainRow: some View {
        HStack(spacing: 12) {
            ServiceLogo(service: service, size: 40)
                .opacity(isDeadEnd ? 0.45 : 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(service.name)
                        .font(RFont.display(16, weight: .semibold))
                        .tracking(-0.3)
                        .lineLimit(1)
                        .foregroundStyle(isDeadEnd ? theme.text2 : theme.text)
                    if selected {
                        Image(systemName: RIcon.check)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(theme.accent2)
                            .accessibilityLabel(Text("Currently selected"))
                    }
                }

                // The only sub-line left. `category` restated the chip row
                // directly above this list, and `typicalWaitShort` is a
                // service-level constant that does not vary with the country
                // being priced here — six data points where four were about
                // this choice. On an e-mail pick the SMS delivery record is
                // another product's evidence, so it is omitted entirely.
                if !emailMode {
                    SuccessBadge(record: record, compact: true)
                }
            }

            Spacer(minLength: 0)

            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var trailing: some View {
        if emailMode {
            // No credit figure: the price comes from the DOMAIN chosen next
            // (free or 1 cr), not from the service. Showing an SMS route price
            // here is what made an email pick quote number prices.
            Text(emailSupported
                 ? String(localized: "Available")
                 : String(localized: "No email"))
                .font(RFont.text(12, weight: .medium))
                .foregroundStyle(emailSupported ? theme.text2 : theme.text3)
        } else if let price {
            priceLabel(price)
        } else if let elsewhere {
            // The country is named in the strip below, not squeezed in here.
            priceLabel(elsewhere.credits)
        } else {
            Text("Unavailable")
                .font(RFont.text(12, weight: .medium))
                .foregroundStyle(theme.text3)
        }
    }

    private func priceLabel(_ credits: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text("\(credits)")
                .font(RFont.display(15, weight: .semibold))
                .foregroundStyle(credits <= balance ? theme.text : theme.text2)
                .monospacedDigit()
            Text("cr")
                .font(RFont.text(12, weight: .medium))
                .foregroundStyle(theme.text2)
        }
    }

    /// The most consequential thing a row can do, stated as a sentence.
    ///
    /// This was a grey 11pt "🇷🇴 Romania" tucked under the price — the entire
    /// disclosure that tapping would move the user out of the country they had
    /// chosen and reprice everything downstream of it. A country change earns a
    /// sentence and a caution wash.
    ///
    /// The flag carries "this is a country" in every language and the name is
    /// interpolated as an argument, so the strip is one translatable sentence
    /// rather than a fragment ("in %@") whose article is gendered in half the
    /// locales we ship.
    private func relocationStrip(_ country: Country) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: country.flag)
                .font(.system(size: 13))
            Text("Not available here. Tapping switches your country to \(country.name).")
                .font(RFont.text(12, weight: .medium))
                .foregroundStyle(theme.text)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.warnSoft)
    }
}
