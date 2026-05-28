import SwiftUI

struct Card<Content: View>: View {
    @Environment(\.theme) private var theme
    var radius: CGFloat = 22
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(theme.elev, in: .rect(cornerRadius: radius))
    }
}
