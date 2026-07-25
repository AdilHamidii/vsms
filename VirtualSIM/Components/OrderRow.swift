import SwiftUI

struct OrderRow: View {
    @Environment(\.theme) private var theme
    let order: Order
    var isLast: Bool = false
    var onTap: (() -> Void)? = nil

    /// Same rule as ReceiptRow: only a Button when it navigates. `.disabled`
    /// on a non-tappable row just greys perfectly readable history.
    var body: some View {
        if let onTap {
            Button(action: onTap) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    private var content: some View {
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
                            // Every terminal-without-a-code status is refunded
                            // server-side (poll-active-orders expiry and
                            // cancel-order both wallet_credit the full cost
                            // before writing the status). History showed only
                            // "Expired", which reads as "I paid and got
                            // nothing" — the refund has to still be visible
                            // later, not just in the moment it happened.
                            if order.isRefunded {
                                Text("·").foregroundStyle(theme.text3)
                                Text("+\(order.costCredits) cr refunded")
                                    .font(RFont.text(12, weight: .medium))
                                    .foregroundStyle(theme.live)
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
}
