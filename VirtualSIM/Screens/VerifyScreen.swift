import SwiftUI

/// The Verify tab (spec §6.1): one question, the apps people verify most, a
/// search, and category chips. Nothing is pre-selected: a tap is the user's
/// own pick through `commitServicePick`, which clears `needsServiceChoice`
/// and leaves `needsCountryChoice` set.
struct VerifyScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state

    var openCredits: () -> Void
    /// Raises the full service picker. Unused by this first cut; kept because
    /// `ContentView` hands over the same closure the code store gets.
    var openServices: () -> Void

    @State private var query = ""
    @State private var category: String? = nil

    /// Ordered by order volume (the old Home grid's seven + Snapchat as the
    /// eighth, reviewed 2026-09-24). A missing id is skipped, never a hole.
    static let featuredIds = [
        "whatsapp", "telegram", "instagram", "google",
        "tiktok", "discord", "tinder", "snapchat",
    ]

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
                if hasLiveLine, let line = state.line {
                    lineStrip(line).padding(.top, RSpace.lg)
                }
                searchField.padding(.top, RSpace.xl)
                if isSearching {
                    results.padding(.top, RSpace.md)
                } else {
                    if !recentServices.isEmpty {
                        recentRow.padding(.top, RSpace.xl)
                    }
                    grid.padding(.top, RSpace.xl)
                    chips.padding(.top, RSpace.lg)
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
                Text("Get a code for an app. No code? Your credits come back.")
                    .font(RFont.text(15))
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: RSpace.md)
            Button(action: openCredits) {
                HStack(spacing: 6) {
                    CoinIcon(size: 14, color: theme.text)
                    Text("\(state.balance)").numberStyle(size: 15, color: theme.text)
                }
                .padding(.horizontal, RSpace.md)
                .padding(.vertical, RSpace.sm)
                .background(theme.chipBg, in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Credits: \(state.balance)"))
        }
        .padding(.top, RSpace.lg)
    }

    private func lineStrip(_ line: Line) -> some View {
        HStack(spacing: RSpace.md) {
            Image(systemName: "phone.fill").foregroundStyle(theme.live)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your number").font(RFont.text(12, weight: .semibold)).foregroundStyle(theme.text3)
                Text(verbatim: line.e164).numberStyle(size: 17, color: theme.text)
            }
            Spacer()
            Button {
                UIPasteboard.general.string = line.e164
                RHaptic.select()
            } label: {
                Text("Copy").font(RFont.text(14, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .tint(theme.ink)
        }
        .padding(RSpace.lg)
        .background(theme.elev, in: .rect(cornerRadius: RRadius.card, style: .continuous))
    }

    // MARK: Search

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty || category != nil
    }

    private var searchField: some View {
        HStack(spacing: RSpace.sm) {
            Image(systemName: "magnifyingglass").foregroundStyle(theme.text3)
            TextField(String(localized: "Search \(state.services.count) apps"), text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
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

    private var matches: [Service] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return state.services.filter { s in
            (category == nil || s.category == category)
                && (q.isEmpty || s.name.lowercased().contains(q))
        }
    }

    @ViewBuilder
    private var results: some View {
        let list = matches
        if list.isEmpty {
            Text("No apps match")
                .font(RFont.text(15))
                .foregroundStyle(theme.text3)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, RSpace.xxl)
        } else {
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
    }

    // MARK: Recent, grid, chips

    private var recentServices: [Service] {
        var seen = Set<String>()
        var out: [Service] = []
        for order in state.orders where !seen.contains(order.service.id) {
            seen.insert(order.service.id)
            out.append(order.service)
            if out.count == 3 { break }
        }
        return out
    }

    private var recentRow: some View {
        VStack(alignment: .leading, spacing: RSpace.sm) {
            Text("Recent").font(RFont.text(13, weight: .semibold)).foregroundStyle(theme.text3)
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

    /// One pass over the catalog rather than a scan per id, and in demand
    /// order rather than the catalog's.
    private var featured: [Service] {
        let wanted = Set(Self.featuredIds)
        var found: [String: Service] = [:]
        for s in state.services where wanted.contains(s.id) { found[s.id] = s }
        return Self.featuredIds.compactMap { found[$0] }
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: RSpace.sm), count: 4),
                  spacing: RSpace.sm) {
            ForEach(featured) { service in
                VerifyTile(label: Text(verbatim: Self.tileLabel(service))) {
                    pick(service, source: "verify")
                } icon: {
                    ServiceLogo(service: service, size: 38, radius: 11)
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
                }
            }
        }
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
