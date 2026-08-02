import SwiftUI

struct SheetHeader: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let title: String

    var body: some View {
        HStack {
            // LocalizedStringKey, not the raw String — Text(String) never
            // consults the catalog, so every sheet title shipped English to
            // all six locales while its translation sat unused.
            Text(LocalizedStringKey(title))
                .font(RFont.display(20, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(theme.text)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: RIcon.close)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text2)
                    .frame(width: 32, height: 32)
                    .background(theme.chipBg, in: .circle)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}
