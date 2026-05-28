import SwiftUI

struct TabBar: View {
    @Environment(\.theme) private var theme
    @Binding var tab: AppTab

    private struct Item: Identifiable {
        let id: AppTab
        let label: String
        let icon: String
    }
    private let items: [Item] = [
        .init(id: .home,    label: "Home",    icon: RIcon.home),
        .init(id: .orders,  label: "Orders",  icon: RIcon.inbox),
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
                        if active {
                            Text(item.label)
                                .font(RFont.display(14, weight: .semibold))
                                .tracking(-0.2)
                        }
                    }
                    .foregroundStyle(active ? theme.onInk : theme.text2)
                    .padding(.vertical, 10)
                    .padding(.horizontal, active ? 16 : 14)
                    .background(active ? theme.ink : Color.clear, in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background {
            Capsule()
                .fill(theme.isDark ? Color(hex: 0x1C1C1E).opacity(0.78) : Color.white.opacity(0.78))
                .background(.ultraThinMaterial, in: .capsule)
                .overlay(
                    Capsule().strokeBorder(theme.sep, lineWidth: 0.5)
                )
        }
        .shadow(color: .black.opacity(0.10), radius: 15, x: 0, y: 8)
        .shadow(color: .black.opacity(0.06), radius: 3, x: 0, y: 2)
    }
}
