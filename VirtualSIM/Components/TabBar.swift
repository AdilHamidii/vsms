import SwiftUI

struct TabBar: View {
    @Environment(\.theme) private var theme
    @Binding var tab: AppTab

    /// Unread messages on the rented line. Shown as a dot on the inactive tab —
    /// the only cross-app signal this product needs. It deliberately gets no
    /// `ResumeBar`: that exists for orders on a clock, and a text has no
    /// deadline to miss.
    var lineUnread: Int = 0

    private struct Item: Identifiable {
        let id: AppTab
        let label: String
        let icon: String
    }
    /// Order encodes the business, and since 2026-09-09 the OWNER encodes it:
    /// `AppTab.currentOrder` is the single definition, flipped from Telegram
    /// with `/tabs number|temp`. See `AppState.tab` for what this ordering has
    /// cost before, and `PrefKey.launchTab` for why it is read from UserDefaults
    /// rather than from the live `appStatus`.
    ///
    /// `.home` keeps its enum name while its label reads "Temp": it hosts BOTH
    /// temp SMS and temp e-mail (`AppState.emailMode` switches between them),
    /// so neither product's name fits the tab on its own.
    ///
    /// The eSIM tab was removed 2026-09-08: the line has been paused since
    /// 2026-07-31 with no active plans, so it was a permanently empty store
    /// occupying a quarter of the bar.
    ///
    /// ⚠️ Resolved ONCE, into a stored property, not computed per body
    /// evaluation: `AppState` is `@Observable` and this view redraws on every
    /// tab change, so a computed order would hit UserDefaults on each redraw —
    /// and, worse, could change mid-session if anything ever wrote the key
    /// while the app was open.
    private let items: [Item] = AppTab.currentOrder.compactMap { tab in
        switch tab {
        case .line:    Item(id: .line,    label: "Number",  icon: RIcon.phone)
        case .home:    Item(id: .home,    label: "Temp",    icon: RIcon.home)
        case .account: Item(id: .account, label: "Account", icon: RIcon.user)
        // Orders has not been a tab since 2026-08-06; `currentOrder` never
        // yields it, and dropping it here means adding a case is the only way
        // to put it back.
        case .orders:  nil
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                let active = tab == item.id
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        tab = item.id
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.icon)
                            .font(.system(size: 18, weight: .semibold))
                            .overlay(alignment: .topTrailing) {
                                if item.id == .line, lineUnread > 0, !active {
                                    Circle()
                                        .fill(theme.ink)
                                        .frame(width: 7, height: 7)
                                        .offset(x: 4, y: -2)
                                }
                            }
                        if active {
                            // ⚠️ `LocalizedStringKey(...)`, NOT `Text(item.label)`.
                            // `label` is a `String`, so the bare form resolves to
                            // Text's VERBATIM initializer and never consults the
                            // string catalog — only `Text("literal")` does. All six
                            // locales had translations for Home / Orders / Account /
                            // Number sitting in Localizable.xcstrings, unreachable,
                            // while the most persistent chrome in the app rendered
                            // English. Same workaround `PrimaryButton` already uses.
                            Text(LocalizedStringKey(item.label))
                                .font(RFont.display(14, weight: .semibold))
                                .tracking(-0.2)
                        }
                    }
                    .foregroundStyle(active ? theme.onInk : theme.text2)
                    .padding(.vertical, 10)
                    // 12 rather than 14 on the inactive items. Five tabs need
                    // ~312pt of the 323pt available on the narrowest supported
                    // device (iPhone SE 2nd gen, 375pt) with "Account" active;
                    // this buys 16pt of headroom before a longer localized
                    // label runs it out.
                    .padding(.horizontal, active ? 16 : 12)
                    .background(active ? theme.ink : Color.clear, in: .capsule)
                }
                .buttonStyle(.plain)
                // 🔴 AN INACTIVE TAB IS AN ICON AND NOTHING ELSE, so without
                // this SwiftUI derives the label from the SF SYMBOL: VoiceOver
                // read the tabs as "Home", "person" — the symbol names, not the
                // destinations. Harmless-looking until 2026-09-09, when the
                // house icon moved onto the tab labelled "Temp" and the app
                // started announcing a tab by the name of a DIFFERENT one.
                .accessibilityLabel(LocalizedStringKey(item.label))
                .accessibilityAddTraits(active ? [.isSelected] : [])
            }
        }
        .padding(6)
        // Liquid Glass on iOS 26, the previous frosted treatment below it —
        // see `GlassPanel`, which owns the availability guard.
        .glassPanel(Capsule())
        .shadow(color: .black.opacity(0.10), radius: 15, x: 0, y: 8)
        .shadow(color: .black.opacity(0.06), radius: 3, x: 0, y: 2)
    }
}
