import SwiftUI

/// The My number tab's third segment (spec §4.3): usage, "Switch number…",
/// "Rent another number", and the 911 disclosure. It replaces the gear's
/// "Number settings" sheet (deleted 2026-09-24).
///
/// 🔴 NO RENEWAL OR SUBSCRIPTION ROWS (owner, 2026-09-01, re-confirmed
/// 2026-09-24). Apple's manage-subscriptions sheet lives in Account only.
struct LineNumberSegment: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state

    let line: Line
    var onSwapped: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: RSpace.xl) {
            VStack(alignment: .leading, spacing: RSpace.sm) {
                SectionHeader(label: "Usage")
                group {
                    // Outbound texts: the allowance `begin_outbound_message`
                    // meters. Inbound is never metered and must never get a
                    // counter of its own.
                    usageRow(Text("Texts you can send"),
                             left: line.smsRemaining, of: line.smsAllowance)
                    rule
                    usageRow(Text("Minutes left"),
                             left: line.voiceMinutesRemaining,
                             of: line.voiceAllowanceSeconds / 60)
                }
            }
            group {
                if LineSwitchNumberButton.isOffered(for: line, state: state) {
                    LineSwitchNumberButton(line: line, style: .row,
                                           from: "number_segment", onSwapped: onSwapped)
                    rule
                }
                rentAnother
            }
            VStack(alignment: .leading, spacing: RSpace.sm) {
                SectionHeader(label: "Important")
                emergency
            }
        }
    }

    private func group<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .background(theme.elev, in: .rect(cornerRadius: RRadius.group, style: .continuous))
    }

    private var rule: some View { RowRule(inset: RSpace.lg) }

    private func usageRow(_ label: Text, left: Int, of total: Int) -> some View {
        HStack {
            label.font(RFont.text(16)).foregroundStyle(theme.text)
            Spacer(minLength: RSpace.sm)
            Text("\(left) of \(total)")
                .numberStyle(size: 16, weight: .medium, color: theme.text2)
        }
        .padding(.horizontal, RSpace.lg)
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
    }

    /// The ONLY route to a second number: the tab shows the store only when
    /// there is no line at all. A cover, opened directly — there is no sheet
    /// to dismiss first any more.
    private var rentAnother: some View {
        Button {
            RHaptic.select()
            state.flow = .lineStoreMore
        } label: {
            HStack(spacing: RSpace.md) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.text2)
                    .frame(width: 28)
                Text("Rent another number")
                    .font(RFont.text(16))
                    .foregroundStyle(theme.text)
                Spacer(minLength: RSpace.sm)
                Image(systemName: RIcon.chev)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.text3)
            }
            .padding(.horizontal, RSpace.lg)
            .frame(minHeight: 52)
            .contentShape(.rect)
        }
        .buttonStyle(PressScaleStyle(scale: 0.98, dim: true))
    }

    /// Unmissable, never behind a link — the same amber surface as the
    /// paywall's, so the one disclosure looks the same in both places.
    private var emergency: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.warn)
                .padding(.top, 1)
            Text("This number can't call 911 or any other emergency service. Always use your phone's own number for emergencies.")
                .font(RFont.text(13, weight: .medium))
                .foregroundStyle(theme.text)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(theme.warnSoft, in: .rect(cornerRadius: RRadius.group, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: RRadius.group, style: .continuous)
                .strokeBorder(theme.warn.opacity(0.28), lineWidth: 1)
        }
    }
}
