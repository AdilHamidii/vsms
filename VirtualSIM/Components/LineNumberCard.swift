import SwiftUI

/// The subscriber's number (spec §4.3, §4.5): row 1 is the number in the
/// number voice with the compact "Switch" capsule on its right; row 2 is the
/// live dot, flag and country, with Copy and Share. The line switcher sits
/// beside the number for a multi-line subscriber. Flat, 20pt, no shadow.
///
/// `my_line` carries no locality, so row 2 says country and area code, not a
/// city — a city would need a backend change.
struct LineNumberCard: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(\.dynamicTypeSize) private var typeSize

    let line: Line
    /// The confirmation under the card after a swap, from either entry point.
    @Binding var swappedTo: String?

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: RSpace.md) {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .trailing, spacing: RSpace.sm) {
                    numberLine.frame(maxWidth: .infinity, alignment: .leading)
                    switchControl
                }
            } else {
                HStack(spacing: RSpace.md) {
                    // The number takes every point the capsule leaves (no
                    // Spacer competing for them), so it scales before it
                    // truncates.
                    numberLine
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                    switchControl
                }
            }
            HStack(spacing: RSpace.sm) {
                Circle().fill(statusTint).frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                CodeFlag(code: line.countryCode, size: 20)
                Text(verbatim: placeLabel)
                    .font(RFont.text(14))
                    .foregroundStyle(theme.text2)
                    .lineLimit(1)
                Spacer(minLength: RSpace.sm)
                copyButton
                shareButton
            }
            if let to = swappedTo {
                Text("Your new number is \(PhoneFormat.national(to)). Share it wherever you used the old one.")
                    .font(RFont.text(13))
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(RSpace.lg)
        .background(theme.elev, in: .rect(cornerRadius: RRadius.card, style: .continuous))
    }

    // MARK: Row 1

    private var numberLine: some View {
        HStack(spacing: RSpace.sm) {
            Text(verbatim: PhoneFormat.national(line.e164))
                .numberStyle(size: 28, color: theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                // The number shrinks before anything else gives way.
                .layoutPriority(1)
            // Only when there is a choice to make. Rigid, so the Menu does not
            // take width the number needs (it truncated "…555-01…" beside the
            // Switch capsule in the two-line frame).
            if state.hasMultipleLines { lineSwitcher.fixedSize() }
        }
    }

    private var switchControl: some View {
        LineSwitchNumberButton(line: line, style: .compact, from: "home") { swappedTo = $0 }
    }

    /// Moved verbatim from the old `LiveLineView.lineSwitcher` (the Menu of
    /// live lines with per-line unread, and the elsewhere-unread badge).
    private var lineSwitcher: some View {
        Menu {
            ForEach(state.lines.filter { $0.status.isLive }) { l in
                Button {
                    RHaptic.select()
                    withAnimation(RMotion.select) { state.selectedLineId = l.id }
                } label: {
                    let unread = state.lineThreads
                        .filter { $0.lineId == l.id }
                        .reduce(0) { $0 + $1.unreadCount }
                    Label(
                        unread > 0
                            ? "\(PhoneFormat.national(l.e164))  (\(unread))"
                            : PhoneFormat.national(l.e164),
                        systemImage: l.id == line.id ? RIcon.check : "")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.text3)
                let elsewhere = state.lineThreads
                    .filter { $0.lineId != line.id }
                    .reduce(0) { $0 + $1.unreadCount }
                if elsewhere > 0 {
                    Text(verbatim: "\(elsewhere)")
                        .font(RFont.text(10, weight: .heavy))
                        .foregroundStyle(theme.bg)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(theme.text, in: .capsule)
                }
            }
            .frame(minWidth: 28, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: Row 2

    private var placeLabel: String {
        let country = Locale.current.localizedString(forRegionCode: line.countryCode) ?? line.countryCode
        let digits = line.e164.filter(\.isNumber)
        guard line.e164.hasPrefix("+1"), digits.count == 11 else { return country }
        return "\(country) · \(digits.dropFirst().prefix(3))"
    }

    /// Matches `LineStatusBanner`, which explains a fault in a sentence.
    private var statusTint: Color {
        switch line.status {
        case .active:             theme.live
        case .grace, .pastDue:    theme.warn
        case .suspended, .failed: theme.fail
        default:                  theme.text3
        }
    }

    private var copyButton: some View {
        Button(action: copy) {
            HStack(spacing: 5) {
                Image(systemName: copied ? RIcon.check : RIcon.copy)
                    .font(.system(size: 12, weight: .semibold))
                Text(copied ? "Copied" : "Copy")
                    .font(RFont.text(14, weight: .semibold))
            }
            .foregroundStyle(copied ? theme.live : theme.text)
            .padding(.horizontal, RSpace.md)
            .frame(height: 36)
            .background(theme.chipBg, in: .capsule)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(PressScaleStyle(scale: 0.95))
        .accessibilityLabel(copied ? Text("Copied") : Text("Copy number"))
    }

    private var shareButton: some View {
        ShareLink(item: PhoneFormat.national(line.e164)) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.text)
                .frame(width: 36, height: 36)
                .background(theme.chipBg, in: .circle)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .simultaneousGesture(TapGesture().onEnded { RHaptic.select() })
        .accessibilityLabel(Text("Share number"))
    }

    private func copy() {
        UIPasteboard.general.string = line.e164
        RHaptic.select()
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            copied = false
        }
    }
}
