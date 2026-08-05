import SwiftUI

/// The wait between "Apple took the money" and "the number works".
///
/// Telnyx number orders are **asynchronous** — `pending` → `success`, measured
/// under five seconds — so this is a real state rather than a spinner standing
/// in for one. It polls the server rather than trusting the purchase response,
/// for the same reason `WaitingScreen` reconciles against the order row: the
/// authority on whether a thing exists is the database, not the call that
/// asked for it.
///
/// ⚠️ Leaving is SAFE and deliberately allowed. The subscription is already
/// paid and the line is already a row; provisioning continues server-side and
/// the Number tab shows whatever state it reaches. Trapping someone on a
/// progress screen is the pattern that made the waiting-screen ✕ destructive
/// for two releases.
struct LineProvisioningScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    @Environment(SubscriptionStore.self) private var subs

    @State private var elapsed = 0

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Spacer(minLength: 12)
                content
                Spacer(minLength: 12)
                footer
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .task {
            // The server is what provisions; this only reflects it. Same
            // cadence as the eSIM detail screen.
            while !Task.isCancelled, state.flow == .lineProvisioning {
                await state.loadLine(using: LineAPI(client: api))
                if let line = state.line {
                    if line.status == .active {
                        subs.clearProvisioned()
                        state.flow = nil        // the Number tab takes over
                        return
                    }
                    if line.status == .failed { return }   // footer explains it
                }
                try? await Task.sleep(for: .seconds(2))
                elapsed += 2
            }
        }
    }

    private var header: some View {
        HStack {
            Spacer()
            Button { state.flow = nil } label: {
                Image(systemName: RIcon.close)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.text2)
                    .frame(width: 34, height: 34)
                    .background(theme.chipBg, in: .circle)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private var content: some View {
        if state.line?.status == .failed {
            failed
        } else {
            working
        }
    }

    private var working: some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.2)
            VStack(spacing: 8) {
                Text("Setting up your number")
                    .font(RFont.display(22, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(theme.text)
                if let e164 = provisionedNumber {
                    Text(PhoneFormat.national(e164))
                        .font(RFont.mono(19, weight: .medium))
                        .foregroundStyle(theme.text2)
                }
            }
            // Only after the wait stops feeling instant. A healthy provision
            // finishes in a few seconds and should show nothing extra.
            if elapsed >= 8 {
                Text("Taking a little longer than usual — this keeps working if you close the app.")
                    .font(RFont.text(13))
                    .foregroundStyle(theme.text3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .animation(RMotion.content, value: elapsed >= 8)
    }

    /// The honest version of "we took your money and something broke".
    ///
    /// It says plainly that the subscription is live and the number is not,
    /// and points at support — because this is the one path where Apple holds
    /// the money and we cannot refund it ourselves. `fail_line_claim` has
    /// already paged the owner by the time anyone reads this.
    private var failed: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(theme.warn)
            Text("We couldn't finish setting up your number")
                .font(RFont.display(20, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(theme.text)
                .multilineTextAlignment(.center)
            Text("Your subscription is active but no number was assigned. We've been alerted and will sort this out — please don't subscribe again.")
                .font(RFont.text(14))
                .foregroundStyle(theme.text2)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var provisionedNumber: String? {
        subs.provisionedE164 ?? state.line?.e164 ?? state.lineOffer?.phoneNumber
    }

    @ViewBuilder
    private var footer: some View {
        if state.line?.status == .failed {
            PrimaryButton(label: "Close") { state.flow = nil }
        } else {
            Text("You can close this — we'll have it ready when you come back.")
                .font(RFont.text(12))
                .foregroundStyle(theme.text3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
