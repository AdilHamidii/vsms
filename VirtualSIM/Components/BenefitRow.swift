import SwiftUI

/// One thing the user gets, stated as a FIGURE plus a label.
///
/// This replaces `Bullet` on every screen that sells something. `Bullet` is a
/// 4pt grey dot plus 13pt `text2` — the identical device the app uses for legal
/// fine print, so "what you are paying for" and "caveats you should skim" were
/// rendered the same way. And it buried the quantities: in "200 texts every
/// month", the 200 carried exactly the same weight as the word "every".
///
/// A paywall's whole job is to make the numbers land, so the figure gets its
/// own type step and the primary ink, while the label stays secondary.
struct BenefitRow: View {
    @Environment(\.theme) private var theme

    var icon: String
    /// The number, when the benefit is a quantity ("200", "100"). Omitted for
    /// qualitative benefits, which then read as a single confident line.
    var figure: String? = nil
    var label: LocalizedStringKey
    /// A right-aligned qualifier — "Free: 2", "included", "Canada + US". Reads
    /// as a ledger rather than a marketing checklist.
    var hint: LocalizedStringKey? = nil
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: RRadius.xs, style: .continuous)
                .fill((tint ?? theme.ink).opacity(0.13))
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tint ?? theme.accent2)
                )

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let figure {
                    Text(figure)
                        .font(RFont.display(19, weight: .bold))
                        .tracking(-0.4)
                        .foregroundStyle(theme.text)
                        .monospacedDigit()
                }
                Text(label)
                    .font(RFont.text(14, weight: figure == nil ? .medium : .regular))
                    .foregroundStyle(figure == nil ? theme.text : theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let hint {
                Text(hint)
                    .font(RFont.text(11))
                    .foregroundStyle(theme.text3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// The 1px rule between rows inside a grouped card.
///
/// Inset past the icon tile so the rule starts at the text, which is what makes
/// a stack of rows read as one object instead of several stacked cards.
struct RowRule: View {
    @Environment(\.theme) private var theme
    var inset: CGFloat = 60

    var body: some View {
        Rectangle()
            .fill(theme.sep)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}
