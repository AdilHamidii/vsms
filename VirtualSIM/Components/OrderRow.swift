import SwiftUI

struct OrderRow: View {
    @Environment(\.theme) private var theme
    let order: Order
    var isLast: Bool = false
    var onTap: (() -> Void)? = nil

    var body: some View {
        Button {
            onTap?()
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    ServiceLogo(service: order.service, size: 36, radius: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(order.service.name)
                                .font(RFont.display(15, weight: .semibold))
                                .tracking(-0.2)
                                .foregroundStyle(theme.text)
                            Text(order.country.flag)
                                .font(.system(size: 12))
                        }
                        HStack(spacing: 6) {
                            MonoText(order.number, size: 12, color: theme.text2)
                            if let otp = order.otp, order.status == .received {
                                Text("·").foregroundStyle(theme.text3)
                                MonoText(otp, size: 12, weight: .semibold, color: theme.text)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 4) {
                        StatusBadge(status: order.status)
                        Text(order.ago)
                            .font(RFont.text(11))
                            .foregroundStyle(theme.text3)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                if !isLast {
                    Rectangle()
                        .fill(theme.sep)
                        .frame(height: 0.5)
                        .padding(.leading, 62)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
    }
}
