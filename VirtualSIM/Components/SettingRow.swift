import SwiftUI

/// One line in a grouped settings card.
///
/// ── Two things this used to get wrong ────────────────────────────────────
///
/// **It was ALWAYS a `Button`, even for rows that navigate nowhere.** Half the
/// Preferences rows carry their own interactive trailing content — the accent
/// swatches, the appearance segments, a `Toggle`, two `Menu`s — and wrapping
/// interactive content in an outer Button is the exact nested-control conflict
/// `ReceiptRow` already documents (there it also dragged `.disabled` down the
/// subtree and made the premium tier unselectable in shipped builds). A row is
/// now a Button only when it has an `onTap`.
///
/// **It responded to touch not at all.** `.buttonStyle(.plain)` on a row that
/// pushes a sheet, next to a `PrimaryButton` that scales, reads as parts of the
/// interface being broken. Tappable rows now carry `.pressable()` and a
/// selection haptic.
///
/// `label` is a `LocalizedStringKey` rather than a `String` on purpose: Xcode's
/// string extractor can see a literal passed to a `LocalizedStringKey`
/// parameter, and cannot see one passed to a `String`. Every settings label was
/// therefore invisible to the catalog and shipped English to all six locales.
struct SettingRow<Trailing: View>: View {
    @Environment(\.theme) private var theme
    let label: LocalizedStringKey
    var icon: String? = nil
    /// A second line under the label — a status, a result, an explanation.
    /// Replaces the pattern of parking a result string in the trailing edge,
    /// where it had no room, no colour and (for "Restore purchases") no way to
    /// ever clear.
    var detail: LocalizedStringKey? = nil
    /// Semantic tint for `detail`. Defaults to secondary ink; pass `theme.live`
    /// for a success and `theme.fail` for a failure, so the two can never read
    /// identically.
    var detailTint: Color? = nil
    var isLast: Bool = false
    var isDanger: Bool = false
    var onTap: (() -> Void)? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        if let onTap {
            Button {
                RHaptic.select()
                onTap()
            } label: {
                content
            }
            .pressable(0.985)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isDanger ? theme.fail : theme.text2)
                        .frame(width: 28, height: 28)
                        .background(isDanger ? theme.failSoft : theme.chipBg,
                                    in: .rect(cornerRadius: RRadius.xs))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(RFont.text(15))
                        .tracking(-0.2)
                        .foregroundStyle(isDanger ? theme.fail : theme.text)
                        .multilineTextAlignment(.leading)
                    if let detail {
                        Text(detail)
                            .font(RFont.text(12, weight: .medium))
                            .foregroundStyle(detailTint ?? theme.text2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
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
}

extension SettingRow where Trailing == TrailingText {
    init(label: LocalizedStringKey,
         icon: String? = nil,
         trailingText: LocalizedStringKey? = nil,
         detail: LocalizedStringKey? = nil,
         detailTint: Color? = nil,
         isLast: Bool = false,
         isDanger: Bool = false,
         onTap: (() -> Void)? = nil) {
        self.label = label
        self.icon = icon
        self.detail = detail
        self.detailTint = detailTint
        self.isLast = isLast
        self.isDanger = isDanger
        self.onTap = onTap
        self.trailing = TrailingText(text: trailingText)
    }
}

struct TrailingText: View {
    @Environment(\.theme) private var theme
    let text: LocalizedStringKey?

    var body: some View {
        if let text {
            Text(text)
                .font(RFont.text(14))
                .foregroundStyle(theme.text2)
        }
    }
}

/// A `Menu` label that looks like a control.
///
/// The Preferences menus rendered as bare secondary text with no affordance —
/// indistinguishable from the row's own trailing value, so nothing said they
/// could be tapped.
struct MenuValueLabel: View {
    @Environment(\.theme) private var theme
    var text: LocalizedStringKey
    var leading: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let leading {
                Text(verbatim: leading).font(.system(size: 14))
            }
            Text(text)
                .font(RFont.text(14))
                .foregroundStyle(theme.text2)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.text3)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.chipBg, in: .capsule)
        .contentShape(.capsule)
    }
}
