import SwiftUI

struct Bullet: View {
    @Environment(\.theme) private var theme
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(theme.text3)
                .frame(width: 4, height: 4)
                .padding(.top, 8)
            Text(text)
                .font(RFont.text(13))
                .tracking(-0.1)
                .foregroundStyle(theme.text2)
                .lineSpacing(2)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}
