import SwiftUI

/// "You have something in flight — tap to go back to it."
///
/// Exists so that leaving a waiting screen is SAFE. Closing used to be the only
/// way out of a wait, and on the SMS side that meant cancelling a paid order:
/// the ✕ read as "back" but destroyed the thing the user paid for. Making close
/// non-destructive is only honest if there is a way back — otherwise a live
/// order silently disappears from view and the user assumes it died.
///
/// Shown above the tab bar on every tab, and only when no flow is already open.
struct ResumeBar: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state

    /// The SMS order still waiting, if any. Read from the LIST, not from
    /// `activeOrder` — that is cleared when the flow closes, which is exactly
    /// the moment this bar needs to appear.
    private var waitingSms: Order? {
        // Test the SERVER field, not `Order.number` — that is a non-optional
        // computed property returning "Pending…" when there is no number, so
        // `number != nil` was always true. The bar therefore also appeared for
        // the pre-reservation row `begin_order` writes as ordinary `waiting`
        // with a null id, offering to resume an order holding nothing.
        state.orders.first { $0.status == .waiting && $0.server.smspvaNumber != nil }
    }
    private var waitingEmail: ServerEmailOrder? {
        state.emailOrders.first { $0.status == .waiting && !$0.hasCode }
    }

    var body: some View {
        if state.flow == nil, waitingSms != nil || waitingEmail != nil {
            Button(action: resume) {
                HStack(spacing: 10) {
                    // Breathing dot rather than a spinner: this sits above the
                    // tab bar permanently and a spinner there reads as the app
                    // being stuck.
                    Circle()
                        .fill(theme.live)
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Waiting for a code")
                            .font(RFont.text(13, weight: .semibold))
                            .foregroundStyle(theme.text)
                        Text(subtitle)
                            .font(RFont.text(11))
                            .foregroundStyle(theme.text2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    Text("Resume")
                        .font(RFont.text(12, weight: .semibold))
                        .foregroundStyle(theme.onInk)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(theme.ink, in: .capsule)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(theme.elev, in: .rect(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(theme.sep, lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var subtitle: String {
        if let mail = waitingEmail, waitingSms == nil {
            return mail.email ?? mail.domain
        }
        if let sms = waitingSms { return sms.number }
        return ""
    }

    /// SMS wins when both are live: it is the one on a hard 8-minute clock,
    /// where the email activation runs ~20 minutes.
    private func resume() {
        if let sms = waitingSms {
            state.activeOrder = sms
            state.intent = .sms
            state.flow = .waiting
        } else if let mail = waitingEmail {
            state.activeEmailOrder = mail
            state.intent = .email
            state.flow = .emailWaiting
        }
    }
}
