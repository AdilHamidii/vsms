import SwiftUI

struct PickerCard<Icon: View>: View {
    @Environment(\.theme) private var theme
    let label: String
    let value: String
    @ViewBuilder var icon: Icon
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    icon
                    Text(label.uppercased())
                        .font(RFont.text(12, weight: .medium))
                        .tracking(0.2)
                        .foregroundStyle(theme.text2)
                }
                HStack(spacing: 6) {
                    Text(value)
                        .font(RFont.display(15, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Image(systemName: RIcon.chevDn)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.text3)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.elev, in: .rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }
}

struct FlagBox: View {
    @Environment(\.theme) private var theme
    let flag: String
    var size: CGFloat = 32
    var radius: CGFloat = 9

    var body: some View {
        Text(flag)
            .font(.system(size: size * 0.56))
            .frame(width: size, height: size)
            .background(theme.chipBg, in: .rect(cornerRadius: radius))
    }
}
