import SwiftUI

struct ReceiptRow<Leading: View, Trailing: View>: View {
    @Environment(\.theme) private var theme
    let label: String
    var last: Bool = false
    var onTap: (() -> Void)? = nil
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    /// A row is only a Button when it actually navigates somewhere.
    ///
    /// It used to ALWAYS be a Button with `.disabled(onTap == nil)`, which broke
    /// the checkout tier picker outright: `.disabled(true)` propagates down the
    /// whole subtree, so the "Number type" row (no onTap, but with Standard /
    /// Real SIM buttons in its trailing) rendered greyed out AND swallowed every
    /// tap — the premium tier was unselectable in shipped builds. Wrapping
    /// interactive content in a disabled Button is also a nested-Button
    /// conflict even without the dimming, so the fix is to not wrap at all
    /// rather than to drop the `.disabled`. Same lesson `SettingRow` already
    /// carries; don't reintroduce it here.
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
                leading
                Text(label)
                    .font(RFont.text(13))
                    .tracking(-0.1)
                    .foregroundStyle(theme.text2)
                Spacer(minLength: 0)
                trailing
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            if !last {
                Rectangle().fill(theme.sep).frame(height: 0.5)
            }
        }
    }
}

struct ReceiptIconBox: View {
    @Environment(\.theme) private var theme
    let symbol: String
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(theme.text2)
            .frame(width: 32, height: 32)
            .background(theme.chipBg, in: .rect(cornerRadius: 9))
    }
}

struct ReceiptValue: View {
    @Environment(\.theme) private var theme
    let primary: String
    var secondaryText: String? = nil
    var secondaryContent: AnyView? = nil
    var chev: Bool = false

    init(primary: String, secondaryText: String? = nil, chev: Bool = false) {
        self.primary = primary
        self.secondaryText = secondaryText
        self.secondaryContent = nil
        self.chev = chev
    }

    init<V: View>(primary: String, @ViewBuilder secondary: () -> V, chev: Bool = false) {
        self.primary = primary
        self.secondaryText = nil
        self.secondaryContent = AnyView(secondary())
        self.chev = chev
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(primary)
                    .font(RFont.display(15, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(theme.text)
                if let secondaryText {
                    Text(secondaryText)
                        .font(RFont.text(12))
                        .foregroundStyle(theme.text2)
                } else if let secondaryContent {
                    secondaryContent
                }
            }
            if chev {
                Image(systemName: RIcon.chev)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.text3)
            }
        }
    }
}
