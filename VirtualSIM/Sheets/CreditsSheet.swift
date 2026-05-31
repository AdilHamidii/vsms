import SwiftUI

struct CreditsSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(IAPStore.self) private var iap
    var balance: Int
    var onPurchased: () -> Void

    @State private var selected: String = "md"
    @State private var purchasing = false

    private var pack: CreditPack {
        CreditPack.all.first { $0.id == selected } ?? CreditPack.all[1]
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Buy credits")
            ScrollView {
                VStack(spacing: 0) {
                    balanceRow
                    packsList
                    footnote
                    if let err = iap.lastError {
                        Text(err)
                            .font(RFont.text(12))
                            .foregroundStyle(theme.fail)
                            .multilineTextAlignment(.center)
                            .padding(.top, 10)
                    }
                    PrimaryButton(
                        label: purchasing ? "Processing…" : "Buy \(pack.credits) credits",
                        sub: iap.displayPrice(pack),
                        disabled: purchasing,
                        action: { Task { await buy() } }
                    )
                    .padding(.top, 16)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
        }
        .background(theme.bg)
        .task { await iap.loadProducts() }
    }

    private var balanceRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Current balance")
                    .font(RFont.text(12))
                    .tracking(-0.1)
                    .foregroundStyle(theme.text2)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    MonoText("\(balance)", size: 22, weight: .semibold, color: theme.text)
                    Text("credits")
                        .font(RFont.text(13))
                        .foregroundStyle(theme.text2)
                }
            }
            Spacer()
            Text("Pay-per-use")
                .font(RFont.text(12))
                .foregroundStyle(theme.text2)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(theme.elev, in: .capsule)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(theme.chipBg, in: .rect(cornerRadius: 14))
        .padding(.bottom, 14)
    }

    private var packsList: some View {
        VStack(spacing: 8) {
            ForEach(CreditPack.all) { p in
                PackRow(pack: p, active: selected == p.id, displayPrice: iap.displayPrice(p)) {
                    withAnimation(.easeOut(duration: 0.15)) { selected = p.id }
                }
            }
        }
    }

    private var footnote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: RIcon.shield)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.text2)
                .padding(.top, 1)
            Text("Credits never expire. Failed SMS auto-refund within 2 minutes.")
                .font(RFont.text(12))
                .foregroundStyle(theme.text2)
                .lineSpacing(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.chipBg, in: .rect(cornerRadius: 12))
        .padding(.top, 14)
    }

    private func buy() async {
        purchasing = true
        defer { purchasing = false }
        let success = await iap.purchase(pack)
        if success {
            onPurchased()
            dismiss()
        }
    }
}

private struct PackRow: View {
    @Environment(\.theme) private var theme
    let pack: CreditPack
    let active: Bool
    let displayPrice: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .strokeBorder(active ? theme.ink : theme.sepStrong, lineWidth: 1.5)
                        .frame(width: 22, height: 22)
                    if active {
                        Circle().fill(theme.ink).frame(width: 10, height: 10)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        MonoText("\(pack.credits)", size: 20, weight: .semibold, color: theme.text)
                        Text("credits")
                            .font(RFont.text(14))
                            .foregroundStyle(theme.text2)
                        if pack.bestValue {
                            Text("BEST VALUE")
                                .font(RFont.text(11, weight: .semibold))
                                .tracking(0.1)
                                .foregroundStyle(theme.live)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(theme.liveSoft, in: .capsule)
                        }
                    }
                    Text(pack.perCredit)
                        .font(RFont.text(12))
                        .foregroundStyle(theme.text2)
                }
                Spacer(minLength: 0)
                Text(displayPrice)
                    .font(RFont.display(18, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(theme.text)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(theme.elev, in: .rect(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(active ? theme.ink : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}
