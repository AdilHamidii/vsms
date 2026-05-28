import SwiftUI

struct SectionHeader: View {
    @Environment(\.theme) private var theme
    let label: String
    var action: String? = nil
    var onAction: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label.uppercased())
                .font(RFont.display(13, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(theme.text2)
            Spacer()
            if let action {
                Button(action: { onAction?() }) {
                    Text(action)
                        .font(RFont.text(14, weight: .medium))
                        .foregroundStyle(theme.text2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 10)
        .padding(.top, 4)
    }
}
