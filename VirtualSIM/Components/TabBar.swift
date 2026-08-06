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
    /// Order encodes the business: rented numbers first, then temp SMS, then
    /// eSIM (paused, ranked last), then the utility tabs. See `AppTab`.
    private let items: [Item] = [
        .init(id: .line,    label: "Number",  icon: RIcon.phone),
        .init(id: .home,    label: "Home",    icon: RIcon.home),
        .init(id: .esim,    label: "eSIM",    icon: "simcard"),
        .init(id: .account, label: "Account", icon: RIcon.user),
    ]

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
