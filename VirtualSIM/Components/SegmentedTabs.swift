import SwiftUI

struct SegmentedTabs<Tag: Hashable>: View {
    @Environment(\.theme) private var theme
    @Binding var selection: Tag
    let items: [(tag: Tag, label: String, count: Int?)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.tag) { item in
                let active = selection == item.tag
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        selection = item.tag
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(item.label)
                            .font(RFont.display(13, weight: .semibold))
                            .tracking(-0.2)
                            .foregroundStyle(active ? theme.text : theme.text2)
                        if let n = item.count {
                            Text("\(n)")
                                .font(RFont.text(11, weight: .medium))
                                .foregroundStyle(theme.text3)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(active ? theme.elev : Color.clear, in: .rect(cornerRadius: 10))
                    .shadow(color: active ? .black.opacity(0.08) : .clear, radius: 1.5, x: 0, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(theme.chipBg, in: .rect(cornerRadius: 12))
    }
}
