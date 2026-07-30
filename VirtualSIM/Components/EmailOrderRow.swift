import SwiftUI

/// One temporary-email activation in history.
///
/// Sibling of `OrderRow`. Kept separate rather than generalising OrderRow
/// because almost nothing lines up: there is no country, no phone number, and
/// the "did it work?" test is different (see `hasCode`).
struct EmailOrderRow: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    let order: ServerEmailOrder
    var isLast: Bool = false
    var onTap: (() -> Void)? = nil

    /// Resolve the service so the row can carry its logo and name. Falls back
    /// to the raw site, which is always present.
    private var service: Service? {
        guard let id = order.serviceId else { return nil }
        return state.services.first { $0.id == id }
    }

    var body: some View {
        Group {
            if let onTap {
                Button(action: onTap) { content }.buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let service {
                    ServiceLogo(service: service, size: 36, radius: 10)
                } else {
                    Image(systemName: "envelope.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.ink)
                        .frame(width: 36, height: 36)
                        .background(theme.inkSoft, in: .rect(cornerRadius: 10))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(service?.name ?? order.site)
                        .font(RFont.display(15, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    // The address is the artefact the user cares about, so it
                    // is the subtitle — verbatim, it is not translatable text.
                    Text(verbatim: order.email ?? order.domain)
                        .font(RFont.mono(11))
                        .foregroundStyle(theme.text2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 4) {
                    statusPill
                    // Refunds must be visible durably, not just in the moment —
                    // "Expired" with no money line reads as "I paid and got
                    // nothing". Free activations show nothing, because claiming
                    // a refund of 0 would be noise.
                    if order.wasRefunded {
                        Text("+\(order.costCredits) cr refunded")
                            .font(RFont.text(10, weight: .medium))
                            .foregroundStyle(theme.live)
                    } else if order.costCredits == 0 {
                        Text("Free")
                            .font(RFont.text(10, weight: .medium))
                            .foregroundStyle(theme.text3)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(.rect)

            if !isLast {
                Rectangle().fill(theme.sep).frame(height: 0.5)
                    .padding(.leading, 62)
            }
        }
    }

    /// `hasCode` decides, never `status == .received` — a code can land on a
    /// row the provider already closed, exactly as on the SMS side.
    private var statusPill: some View {
        let (text, fg, bg): (String, Color, Color) = {
            if order.hasCode {
                return (String(localized: "Code received"), theme.live, theme.liveSoft)
            }
            switch order.status {
            case .waiting:  return (String(localized: "Waiting"), theme.warn, theme.warnSoft)
            case .expired:  return (String(localized: "Expired"), theme.text2, theme.chipBg)
            case .canceled: return (String(localized: "Canceled"), theme.text2, theme.chipBg)
            case .failed:   return (String(localized: "Failed"), theme.fail, theme.failSoft)
            case .received: return (String(localized: "Code received"), theme.live, theme.liveSoft)
            }
        }()
        return Text(text)
            .font(RFont.text(11, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(bg, in: .capsule)
    }
}
