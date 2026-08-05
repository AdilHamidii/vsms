import StoreKit   // \.requestReview lives here — see OtpScreen
import SwiftUI

/// The code arrived at a temporary address.
///
/// Mirrors `OtpScreen`'s job for the email line, including the review prompt —
/// which stays on Apple's native API, fires only from the 2nd successful code
/// onward, and is never tied to a reward (App Store 5.6.4).
///
/// Its old failure state was `Text(code.isEmpty ? "—" : code)` in 34pt bold
/// with the card `.disabled` and nothing anywhere saying why. An em dash where
/// the code should be, on a screen titled "Code received", is a contradiction
/// the user has to resolve themselves — and the two ways to get here (the code
/// has not decoded yet, or this row genuinely carries none) call for opposite
/// responses.
struct EmailCodeScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(\.requestReview) private var requestReview

    @State private var copied = false
    @State private var appeared = false

    private var order: ServerEmailOrder? { state.activeEmailOrder }
    /// `hasCode` is the authority, never `status == .received` — a code can
    /// land on a row the provider already closed.
    private var code: String { order?.code ?? "" }
    private var hasCode: Bool { !code.isEmpty }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                badge
                codeCard
                    .padding(.top, 22)
                if let email = order?.email, !email.isEmpty {
                    Text(verbatim: email)
                        .font(RFont.mono(13))
                        .foregroundStyle(theme.text3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.top, 14)
                }
                Spacer()
                if hasCode {
                    Text("Paste it into \(order?.site ?? "") to finish verifying.")
                        .font(RFont.text(13))
                        .foregroundStyle(theme.text2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 12)
                }
                PrimaryButton(label: String(localized: "Done"), icon: RIcon.check) {
                    state.flow = nil
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .task(id: code) { await arrive() }
    }

    /// Auto-copy + haptic, on the same reasoning as `OtpScreen`: a verification
    /// code has one use and one destination, so making the user tap to move it
    /// is ceremony. Keyed on `code` rather than fired once on appear, because
    /// this screen can be opened *before* the code decodes and the digits then
    /// arrive underneath it.
    private func arrive() async {
        guard hasCode else { return }
        if !appeared {
            appeared = true
            UIPasteboard.general.string = code
            copied = true
            RHaptic.success()
            Task {
                try? await Task.sleep(nanoseconds: 2_400_000_000)
                withAnimation(RMotion.content) { copied = false }
            }
        }
        guard let id = order?.id, state.shouldRequestReview(forOrderId: id) else { return }
        // A beat, so the prompt lands after the user has seen the code
        // rather than on top of it.
        try? await Task.sleep(nanoseconds: 900_000_000)
        requestReview()
    }

    private var badge: some View {
        HStack(spacing: 7) {
            Image(systemName: hasCode ? RIcon.check : RIcon.clock)
                .font(.system(size: 12, weight: .bold))
            Text(hasCode ? "Code received" : "No code on this one")
                .font(RFont.text(13, weight: .semibold))
        }
        .foregroundStyle(hasCode ? theme.live : theme.text2)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(hasCode ? theme.liveSoft : theme.chipBg, in: .capsule)
    }

    @ViewBuilder
    private var codeCard: some View {
        if hasCode {
            Button {
                UIPasteboard.general.string = code
                RHaptic.copied()
                withAnimation(RMotion.content) { copied = true }
            } label: {
                VStack(spacing: 12) {
                    Text(verbatim: code)
                        .font(RFont.mono(34, weight: .bold))
                        .tracking(2)
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        Image(systemName: copied ? RIcon.check : RIcon.copy)
                            .font(.system(size: 12, weight: .semibold))
                        Text(copied ? "Copied" : "Tap to copy")
                            .font(RFont.text(13, weight: .medium))
                    }
                    .foregroundStyle(copied ? theme.live : theme.text2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
                .background(theme.elev, in: .rect(cornerRadius: RRadius.lg))
                .contentShape(.rect)
            }
            .pressable()
        } else {
            // Says which of the two situations this is, instead of rendering an
            // em dash and disabling itself. `wasRefunded` is only true for a
            // PAID activation that ended codeless, so the free tier is never
            // told about a refund it did not receive.
            Card {
                VStack(spacing: 8) {
                    Text(isSettled ? "This address never got a code" : "Fetching the code…")
                        .font(RFont.display(17, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(theme.text)
                        .multilineTextAlignment(.center)
                    Text(explanation)
                        .font(RFont.text(13))
                        .foregroundStyle(theme.text2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 30)
            }
        }
    }

    /// The order has reached a terminal state, so no code is coming.
    private var isSettled: Bool { order?.status.isTerminal ?? false }

    private var explanation: String {
        guard isSettled else {
            return String(localized: "One moment — pulling it from the mailbox.")
        }
        return order?.wasRefunded == true
            ? String(localized: "The window closed before anything arrived, so your \(order?.costCredits ?? 0) credits went back to your balance.")
            : String(localized: "The window closed before anything arrived. Nothing was charged.")
    }
}
