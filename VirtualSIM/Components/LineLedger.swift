import SwiftUI

/// What a rented number does (✓) and does not do (✗), stated as rows
/// (spec §4.1). One component for the store, the paywall's "What you get"
/// and the swap confirm page, so a limitation reads the same everywhere.
///
/// Neutral by the one-green rule: ✓ is `text2`, ✗ is `warn` — a limitation,
/// not a fault, so never `fail`. The glyphs are hidden from VoiceOver: every
/// ✗ sentence states its own negative.
struct LineLedger<Content: View>: View {
    @Environment(\.theme) private var theme
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows) { row in
                    if row.id != rows.first?.id {
                        Rectangle()
                            .fill(theme.sep)
                            .frame(height: 0.5)
                            .padding(.leading, RSpace.lg + 18 + RSpace.md)
                    }
                    row
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.elev, in: .rect(cornerRadius: RRadius.group, style: .continuous))
    }
}

struct LineLedgerRow: View {
    @Environment(\.theme) private var theme

    enum Kind { case yes, no }

    let kind: Kind
    /// A quantity that leads the sentence ("100"), set in the number voice.
    var figure: String? = nil
    let text: Text
    /// A qualifier under the sentence, e.g. the inbound NANP limit.
    var detail: Text? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: RSpace.md) {
            Image(systemName: kind == .yes ? "checkmark" : "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(kind == .yes ? theme.text2 : theme.warn)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let figure {
                        Text(verbatim: figure)
                            .numberStyle(size: 15, weight: .bold, color: theme.text)
                    }
                    text
                        .font(RFont.text(15))
                        .foregroundStyle(theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let detail {
                    detail
                        .font(RFont.text(13))
                        .foregroundStyle(theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RSpace.lg)
        .padding(.vertical, RSpace.md)
        .accessibilityElement(children: .combine)
    }
}
