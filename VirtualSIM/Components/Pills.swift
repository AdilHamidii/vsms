import SwiftUI

struct StockPill: View {
    @Environment(\.theme) private var theme
    let level: StockLevel

    private var color: Color {
        switch level { case .high: theme.live; case .medium: theme.warn; case .low: theme.fail }
    }
    private var soft: Color {
        switch level { case .high: theme.liveSoft; case .medium: theme.warnSoft; case .low: theme.failSoft }
    }
    private var label: String {
        switch level { case .high: "High stock"; case .medium: "Med. stock"; case .low: "Low stock" }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label)
                .font(RFont.text(12, weight: .medium))
                .tracking(-0.1)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(soft, in: .capsule)
    }
}

enum OrderStatus: String, Hashable, Codable {
    case waiting, received, expired, refunded, canceled
}

struct StatusBadge: View {
    @Environment(\.theme) private var theme
    let status: OrderStatus
    @State private var pulse = false

    private var color: Color {
        switch status {
        case .waiting:  theme.warn
        case .received: theme.live
        case .expired, .refunded, .canceled: theme.text2
        }
    }
    private var soft: Color {
        switch status {
        case .waiting:  theme.warnSoft
        case .received: theme.liveSoft
        case .expired, .refunded, .canceled: theme.chipBg
        }
    }
    private var label: String {
        switch status {
        case .waiting: "Waiting"
        case .received: "Received"
        case .expired: "Expired"
        case .refunded: "Refunded"
        case .canceled: "Canceled"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if status == .waiting {
                Circle()
                    .fill(color)
                    .frame(width: 5, height: 5)
                    .opacity(pulse ? 1.0 : 0.55)
                    .scaleEffect(pulse ? 1.05 : 0.92)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
            }
            Text(label)
                .font(RFont.text(12, weight: .medium))
                .tracking(-0.1)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(soft, in: .capsule)
    }
}

struct CreditPill: View {
    @Environment(\.theme) private var theme
    let value: Int
    var action: (() -> Void)? = nil

    var body: some View {
        Button(action: { action?() }) {
            HStack(spacing: 6) {
                CoinIcon(size: 16, color: theme.text)
                Text("\(value)")
                    .font(RFont.display(14, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(theme.text)
                Text("credits")
                    .font(RFont.text(13))
                    .foregroundStyle(theme.text2)
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .background(theme.chipBg, in: .capsule)
        }
        .buttonStyle(.plain)
    }
}
