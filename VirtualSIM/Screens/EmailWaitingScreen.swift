import SwiftUI

/// Waiting for a code to arrive at a temporary address.
///
/// The address is the product here, so it is shown large and copyable the whole
/// time — unlike the SMS waiting screen, the user has to go and TYPE this
/// somewhere before anything can happen.
struct EmailWaitingScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api

    /// Provider window is ~20–21 min (measured). We show elapsed rather than a
    /// countdown: a countdown to a number we do not control invites the same
    /// "cancel at 00:00" behaviour that cost the SMS product its codes.
    @State private var elapsed = 0
    @State private var copied = false

    private var order: ServerEmailOrder? { state.activeEmailOrder }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Spacer(minLength: 12)
                addressCard
                Spacer(minLength: 12)
                statusLine
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .task {
            // Poll on the same cadence as the eSIM detail screen. The server is
            // what reconciles and refunds; this only reflects it.
            while !Task.isCancelled, state.flow == .emailWaiting {
                await state.refreshEmailOrder(using: EmailAPI(client: api))
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                elapsed += 5
            }
        }
    }

    private var header: some View {
        HStack {
            Button {
                // Leaving does NOT cancel: the activation stays live and
                // ContentView's app-level email poll keeps fetching it (there
                // is NO server cron for email codes — check-email-order is the
                // only reader, so before that task existed this comment was
                // false and backing out silently abandoned the code). A user
                // who backs out still gets their code in history. Destroying a
                // paid order on a back tap is the exact shape the SMS ✕ had to
                // be guarded against.
                state.flow = nil
            } label: {
                Image(systemName: RIcon.close)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.text2)
                    .frame(width: 34, height: 34)
                    .background(theme.chipBg, in: .circle)
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    private var addressCard: some View {
        VStack(spacing: 14) {
            Text("Use this address")
                .font(RFont.text(13, weight: .medium))
                .foregroundStyle(theme.text2)

            Text(order?.email ?? "…")
                .font(RFont.mono(19, weight: .semibold))
                .foregroundStyle(theme.text)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 16)

            Button {
                UIPasteboard.general.string = order?.email ?? ""
                withAnimation(.easeOut(duration: 0.2)) { copied = true }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: copied ? RIcon.check : RIcon.copy)
                        .font(.system(size: 13, weight: .semibold))
                    Text(copied ? "Copied" : "Copy address")
                        .font(RFont.text(14, weight: .semibold))
                }
                .foregroundStyle(theme.onInk)
                .padding(.horizontal, 18).padding(.vertical, 11)
                .background(theme.ink, in: .capsule)
            }
            .buttonStyle(.plain)
            .disabled((order?.email ?? "").isEmpty)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(theme.elev, in: .rect(cornerRadius: 22))
    }

    private var statusLine: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(theme.text2)
                Text("Waiting for the code")
                    .font(RFont.text(14, weight: .medium))
                    .foregroundStyle(theme.text)
            }
            // No promised arrival time. We have measured nothing for email, and
            // quoting a number we have not measured is the seed-etaSeconds
            // mistake the SMS side already paid for.
            Text("Enter the address on the site, then come back — the code appears here.")
                .font(RFont.text(12))
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
    }
}
