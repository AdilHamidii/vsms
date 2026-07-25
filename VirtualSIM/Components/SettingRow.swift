import SwiftUI

struct SettingRow<Trailing: View>: View {
    @Environment(\.theme) private var theme
    let label: String
    var icon: String? = nil
    var isLast: Bool = false
    var isDanger: Bool = false
    var onTap: (() -> Void)? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        Button {
            onTap?()
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(theme.text2)
                            .frame(width: 28, height: 28)
                            .background(theme.chipBg, in: .rect(cornerRadius: 8))
                    }
                    Text(LocalizedStringKey(label))
                        .font(RFont.text(15))
                        .tracking(-0.2)
                        .foregroundStyle(isDanger ? theme.fail : theme.text)
                    Spacer(minLength: 0)
                    trailing
                    if !isDanger && onTap != nil {
                        Image(systemName: RIcon.chev)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.text3)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(.rect)
                if !isLast {
                    Rectangle().fill(theme.sep).frame(height: 0.5)
                        .padding(.leading, icon != nil ? 56 : 16)
                }
            }
        }
        .buttonStyle(.plain)
        // Don't auto-disable visually inert rows — they should still look
        // active in light/dark mode. We just no-op the tap.
    }
}

extension SettingRow where Trailing == TrailingText {
    init(label: String, icon: String? = nil, trailingText: String? = nil,
         isLast: Bool = false, isDanger: Bool = false,
         onTap: (() -> Void)? = nil) {
        self.label = label
        self.icon = icon
        self.isLast = isLast
        self.isDanger = isDanger
        self.onTap = onTap
        self.trailing = TrailingText(text: trailingText)
    }
}

struct TrailingText: View {
    @Environment(\.theme) private var theme
    let text: String?

    var body: some View {
        if let text {
            Text(LocalizedStringKey(text))
                .font(RFont.text(14))
                .foregroundStyle(theme.text2)
        }
    }
}
