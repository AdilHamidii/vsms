import SwiftUI

/// The Verify tab (spec §6.1): one question, the apps people verify most, a
/// search, and category chips. Nothing is pre-selected: a tap is the user's
/// own pick through `commitServicePick`, which clears `needsServiceChoice`
/// and leaves `needsCountryChoice` set.
struct VerifyScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state

    var openCredits: () -> Void
    /// Raises the full service picker — the same sheet the code store uses.
    var openServices: () -> Void

    @State private var query = ""
    @State private var category: String? = nil
    @State private var copied = false

    /// Ordered by order volume (the old Home grid's seven + Snapchat as the
    /// eighth, reviewed 2026-09-24). A missing id is skipped, never a hole.
    static let featuredIds = [
        "whatsapp", "telegram", "instagram", "google",
        "tiktok", "discord", "tinder", "snapchat",
    ]

    /// Fills the grid back to eight when Recent already shows some featured
    /// apps: next by live 60-day order volume (2026-09-24); deliveroo
    /// deliberately excluded — its volume came from the retired app-default
    /// pick.
    static let backfillIds = ["apple-id", "uber", "signal"]

    static let gridSize = 8

    /// Chips map 1:1 to real `Service.category` values (spec §6.1). Never
    /// Gambling.
    static let chipCategories = ["Messaging", "Social", "Dating", "Commerce", "Finance", "Delivery"]

    /// The chip's catalog key. Identity, except `Delivery`: that key already
    /// exists and means SMS delivery ("Réception", "受信" — `TempScreen`,
    /// `CheckoutScreen`), so the category needs a key of its own.
    static func chipLabel(_ category: String) -> LocalizedStringKey {
        category == "Delivery" ? "Delivery apps" : LocalizedStringKey(category)
    }

    /// Gated on `linesLoaded` so a subscriber never sees a strip-less frame
    /// flip into the strip — before the fetch lands, an empty `lines` is
    /// indistinguishable from "not a subscriber".
    private var hasLiveLine: Bool {
        state.linesLoaded && (state.line?.status.isLive ?? false)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let announcement = state.visibleAnnouncement {
                    AnnouncementBanner(announcement: announcement) {
                        state.dismissAnnouncement()
                    }
                    .padding(.top, RSpace.lg)
                }
                searchField.padding(.top, RSpace.xl)
                if isSearching {
                    // The chips stay on screen while a category (or query) is
                    // active, so the selected one reads as selected and the
                    // user can switch straight to another.
                    chips.padding(.top, RSpace.md)
                    results.padding(.top, RSpace.md)
                } else {
                    if !recentServices.isEmpty {
                        recentRow.padding(.top, RSpace.xl)
                    }
                    grid.padding(.top, RSpace.xl)
                    chips.padding(.top, RSpace.lg)
                    if hasLiveLine, let line = state.line {
                        lineStrip(line).padding(.top, RSpace.xl)
                    } else if state.linesLoaded {
                        // Only once lines are known: a subscriber must never
                        // see this row flash before their strip replaces it.
                        ownNumberRow.padding(.top, RSpace.xl)
                    }
                }
            }
            .padding(.horizontal, RSpace.gutter)
            .padding(.bottom, RSpace.xxl)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(theme.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        // Once per VISIT, deliberately ungated: `TabView` keeps this view
        // alive, so a `@State` guard would make it once per session, while
        // the `home_view` it replaces fired once per visit. `has_line` is
        // only trustworthy where `lines_loaded` is true.
        .onAppear {
            Analytics.shared.track("verify_view", [
                "guest": .bool(false),   // Plan 2 wires the real guest flag
                "has_line": .bool(hasLiveLine),
                "lines_loaded": .bool(state.linesLoaded),
            ])
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: RSpace.sm) {
                Text("What do you want to verify?")
                    .displayType(30)
                    .foregroundStyle(theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("Get a code for an app. No code? Your credits come back.")
                    .font(RFont.text(15))
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: RSpace.md)
            // Hidden at 0: a zero balance is not news, and the first order's
            // paywall is where buying happens. Same pill (and keys) main's
            // Home used — a number and "credits" as two texts, so no plural
            // noun is ever interpolated.
            if state.balance > 0 {
                CreditPill(value: state.balance, action: openCredits)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Credits: \(state.balance)"))
                    .accessibilityAddTraits(.isButton)
            }
        }
        .padding(.top, RSpace.lg)
    }

    // MARK: Search

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    private var isSearching: Bool {
        !trimmedQuery.isEmpty || category != nil
    }

    /// The count is only worth quoting for a real catalog: before one loads
    /// (or after a cold load failed) `services` is the seed stub, and
    /// "Search 30 apps" would understate the product by an order of magnitude.
    private var searchPlaceholder: String {
        state.services.count < 2 || !state.hasLiveCatalog
            ? String(localized: "Search apps")
            : String(localized: "Search \(state.services.count) apps")
    }

    private var searchField: some View {
        HStack(spacing: RSpace.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.text3)
                .accessibilityHidden(true)
            TextField(searchPlaceholder, text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel(Text("Search"))
            if isSearching {
                Button {
                    query = ""
                    category = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(theme.text3)
                }
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, RSpace.md)
        .frame(height: 44)
        .background(theme.elev, in: .rect(cornerRadius: RRadius.group, style: .continuous))
    }

    private func matching(ignoringCategory: Bool) -> [Service] {
        let q = trimmedQuery
        return state.services.filter { s in
            (ignoringCategory || category == nil || s.category == category)
                && (q.isEmpty || s.name.localizedStandardContains(q))
        }
    }

    private var matches: [Service] { matching(ignoringCategory: false) }

    /// A query that finds nothing inside the active chip but DOES match
    /// elsewhere ("whatsapp" under Dating) — the same fallback
    /// `ServiceSheet.otherCategoryMatches` uses. Empty unless the chip is what
    /// hid them, so a true no-match still reaches the empty state.
    private var otherCategoryMatches: [Service] {
        guard !trimmedQuery.isEmpty, category != nil, matches.isEmpty else { return [] }
        return matching(ignoringCategory: true)
    }

    @ViewBuilder
    private var results: some View {
        let list = matches
        let elsewhere = otherCategoryMatches
        if !list.isEmpty {
            resultList(list)
        } else if !elsewhere.isEmpty {
            VStack(alignment: .leading, spacing: RSpace.sm) {
                MicroLabel("Matches in other categories")
                    .accessibilityAddTraits(.isHeader)
                resultList(elsewhere)
            }
        } else {
            noMatch
        }
    }

    private func resultList(_ list: [Service]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(list) { service in
                Button { pick(service, source: "verify_search") } label: {
                    HStack(spacing: RSpace.md) {
                        ServiceLogo(service: service, size: 32, radius: 8)
                        Text(verbatim: service.name)
                            .font(RFont.text(16))
                            .foregroundStyle(theme.text)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.text3)
                    }
                    .padding(.vertical, RSpace.md)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                Divider().overlay(theme.sep)
            }
        }
    }

    private var noMatch: some View {
        VStack(spacing: RSpace.md) {
            Text("No apps match")
                .font(RFont.text(15))
                .foregroundStyle(theme.text3)
            Button {
                RHaptic.select()
                // The picker only COMMITS a service; opening the store first
                // is what makes that pick land somewhere (main's More tile
                // did the same).
                state.openCodeStore()
                openServices()
            } label: {
                Text("See all apps")
                    .font(RFont.text(15, weight: .semibold))
                    .foregroundStyle(theme.text2)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, RSpace.xxl)
        // The one event that can say "they came for something we don't
        // carry" — mirrors `ServiceSheet`. Keyed on the query so SwiftUI
        // restarts it per keystroke; 700ms after typing stops is the first
        // moment the string is worth recording.
        .task(id: "\(trimmedQuery)|\(category ?? "")") {
            guard !trimmedQuery.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            Analytics.shared.track("service_search_empty", [
                // Truncated: free text a human typed; caps a stray paste.
                "query": .string(String(trimmedQuery.lowercased().prefix(32))),
                "category": .string(category ?? "All"),
                "affordable_only": .bool(false),
                // A Verify pick always opens the SMS store.
                "email_mode": .bool(false),
                "source": .string("verify"),
            ])
        }
    }

    // MARK: Recent, grid, chips

    /// Newest first, deduped, resolved back through `state.services` (an
    /// order carries the service as it was at purchase) and skipped when the
    /// catalog no longer has it — so no fallback "Service" chip ever renders.
    /// Same rule as `ServiceSheet.recentServices`.
    private var recentServices: [Service] {
        var seen = Set<String>()
        var out: [Service] = []
        for order in state.orders.sorted(by: { $0.createdAt > $1.createdAt }) {
            guard seen.insert(order.service.id).inserted else { continue }
            guard let live = state.services.first(where: { $0.id == order.service.id })
            else { continue }
            out.append(live)
            if out.count == 3 { break }
        }
        return out
    }

    private var recentRow: some View {
        VStack(alignment: .leading, spacing: RSpace.sm) {
            Text("Recent")
                .font(RFont.text(13, weight: .semibold))
                .foregroundStyle(theme.text3)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: RSpace.sm) {
                    ForEach(recentServices) { service in
                        Button { pick(service, source: "verify_recent") } label: {
                            HStack(spacing: RSpace.sm) {
                                ServiceLogo(service: service, size: 22, radius: 6)
                                Text(verbatim: Self.tileLabel(service))
                                    .font(RFont.text(14, weight: .semibold))
                                    .foregroundStyle(theme.text)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, RSpace.md)
                            .padding(.vertical, RSpace.sm)
                            .background(theme.elev, in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Featured apps not already in Recent, then the backfill, capped at
    /// eight distinct tiles. One pass over the catalog rather than a scan per
    /// id; a missing id is skipped, never a hole.
    private var gridServices: [Service] {
        let recentIds = Set(recentServices.map(\.id))
        let ids = (Self.featuredIds + Self.backfillIds).filter { !recentIds.contains($0) }
        let wanted = Set(ids)
        var found: [String: Service] = [:]
        for s in state.services where wanted.contains(s.id) { found[s.id] = s }
        return Array(ids.compactMap { found[$0] }.prefix(Self.gridSize))
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: RSpace.sm), count: 4),
                  spacing: RSpace.sm) {
            ForEach(gridServices) { service in
                VerifyTile(label: Text(verbatim: Self.tileLabel(service))) {
                    pick(service, source: "verify")
                } icon: {
                    ServiceLogo(service: service, size: 38, radius: VerifyTileStyle.plateRadius)
                }
            }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: RSpace.sm) {
                ForEach(Self.chipCategories, id: \.self) { c in
                    Button {
                        RHaptic.select()
                        category = (category == c) ? nil : c
                    } label: {
                        Text(Self.chipLabel(c))
                            .font(RFont.text(14, weight: .semibold))
                            .foregroundStyle(category == c ? theme.onInk : theme.text)
                            .padding(.horizontal, RSpace.md)
                            .padding(.vertical, RSpace.sm)
                            .background(category == c ? theme.ink : theme.chipBg, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(category == c ? .isSelected : [])
                }
            }
        }
    }

    // MARK: Your own number

    /// A subscriber's number, below the pickers: Verify is for codes, and the
    /// number is a reference, not a call to action here.
    private func lineStrip(_ line: Line) -> some View {
        HStack(spacing: RSpace.md) {
            Image(systemName: "phone.fill")
                .foregroundStyle(theme.live)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your own number").font(RFont.text(12, weight: .semibold)).foregroundStyle(theme.text3)
                Text(verbatim: PhoneFormat.national(line.e164)).numberStyle(size: 17, color: theme.text)
            }
            Spacer()
            Button(action: { copyNumber(line) }) {
                // Neutral, not accent: the accent is reserved for the one
                // primary action, and copying is not it.
                Group {
                    if copied { Text("Copied") } else { Text("Copy") }
                }
                .font(RFont.text(14, weight: .semibold))
                .foregroundStyle(theme.text)
                .padding(.horizontal, RSpace.md)
                .padding(.vertical, RSpace.sm)
                .background(theme.chipBg, in: .capsule)
            }
            .buttonStyle(.plain)
        }
        .padding(RSpace.lg)
        .background(theme.elev, in: .rect(cornerRadius: RRadius.card, style: .continuous))
    }

    /// Same feedback as `LineScreen.copyNumber`: the raw E.164 goes to the
    /// pasteboard, the label reads "Copied" for 1.6s.
    private func copyNumber(_ line: Line) {
        UIPasteboard.general.string = line.e164
        RHaptic.select()
        withAnimation(RMotion.select) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(RMotion.select) { copied = false }
        }
    }

    /// For a user without a live line: one quiet row, no price, no accent.
    private var ownNumberRow: some View {
        Button {
            RHaptic.select()
            Analytics.shared.track("verify_line_row_tapped")
            state.tab = .line
        } label: {
            HStack(spacing: RSpace.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your own number")
                        .font(RFont.text(16, weight: .semibold))
                        .foregroundStyle(theme.text)
                    Text("Keep a US or Canadian number for calls and texts.")
                        .font(RFont.text(13))
                        .foregroundStyle(theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: RSpace.sm)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.text3)
                    .accessibilityHidden(true)
            }
            .padding(RSpace.lg)
            .background(theme.elev, in: .rect(cornerRadius: RRadius.card, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: Actions

    private func pick(_ service: Service, source: String) {
        RHaptic.select()
        Analytics.shared.track("service_selected", [
            "service": .string(service.id),
            "source": .string(source),
        ])
        state.commitServicePick(service)
        state.openCodeStore()
    }

    /// One product word per tile ("Google / YouTube / Gmail" → "Google"). A
    /// display choice only: the tap still commits the whole `Service`, and it
    /// is `verbatim` because these are brand names.
    static func tileLabel(_ service: Service) -> String {
        let head = service.name.split(separator: "/", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return head.isEmpty ? service.name : head
    }
}
