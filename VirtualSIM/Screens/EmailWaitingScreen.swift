import SwiftUI

/// Waiting for a code to arrive at a temporary address.
///
/// The address is the product here, so it is shown large and copyable the whole
/// time — unlike the SMS waiting screen, the user has to go and TYPE this
/// somewhere before anything can happen.
///
/// Which is exactly why its loading state used to be indefensible: the address
/// rendered as `order?.email ?? "…"`, a single 19pt monospaced ellipsis
/// standing in for the thing the user had just paid for, under a live "Copy
/// address" button that would have copied an empty string. An ellipsis is not
/// a loading state; it is a shrug. It is also indistinguishable from the
/// provider having failed to issue an address at all, which is a different
/// situation with a different answer.
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
    private var address: String { order?.email ?? "" }

    /// Three genuinely different situations, told apart rather than collapsed.
    private enum AddressState {
        /// The order exists, the mailbox has not come back yet.
        case provisioning
        /// We have an address. This is the normal case and the whole product.
        case ready(String)
        /// The order reached a terminal state without ever issuing one.
        case unavailable
    }

    private var addressState: AddressState {
        if !address.isEmpty { return .ready(address) }
        // `status.isTerminal` is the authority for "this will never arrive".
        // `hasCode` is deliberately not consulted: a code cannot exist without
        // a mailbox, so there is no rescued-code case to protect here.
        if let order, order.status.isTerminal { return .unavailable }
        return .provisioning
    }

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
            .pressable()
            Spacer()
        }
    }

    private var addressCard: some View {
        HeroCard {
            VStack(spacing: 14) {
                MicroLabel(addressLabel)

                switch addressState {
                case .provisioning:
                    // A placeholder shaped like the thing that is coming, with
                    // the travelling highlight that says "placeholder".
                    Capsule()
                        .fill(theme.track)
                        .frame(height: 22)
                        .frame(maxWidth: 240)
                        .shimmer()
                        .padding(.horizontal, 16)
                        .accessibilityLabel(Text("Getting your address"))

                case .ready(let value):
                    Text(verbatim: value)
                        .font(RFont.mono(19, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 16)

                case .unavailable:
                    Text("No address was issued")
                        .font(RFont.display(17, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(theme.text)
                }

                copyButton
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .padding(.horizontal, 20)
        }
        .animation(RMotion.content, value: address)
    }

    private var addressLabel: LocalizedStringKey {
        switch addressState {
        case .provisioning: "Getting your address"
        case .ready:        "Use this address"
        case .unavailable:  "This one didn't work out"
        }
    }

    @ViewBuilder
    private var copyButton: some View {
        switch addressState {
        case .ready(let value):
            Button {
                UIPasteboard.general.string = value
                RHaptic.copied()
                withAnimation(RMotion.content) { copied = true }
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
            .pressable()

        case .provisioning:
            // Present but plainly not ready, rather than live over an empty
            // clipboard. The button used to be enabled the whole time and
            // "Copy address" happily copied "".
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).tint(theme.text3)
                Text("Copy address")
                    .font(RFont.text(14, weight: .semibold))
            }
            .foregroundStyle(theme.text3)
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background(theme.chipBg, in: .capsule)

        case .unavailable:
            GhostButton(label: String(localized: "Back"), fillsWidth: false) {
                state.flow = nil
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch addressState {
        case .unavailable:
            VStack(spacing: 8) {
                Text("We couldn't get you an address this time.")
                    .font(RFont.text(14, weight: .medium))
                    .foregroundStyle(theme.text)
                    .multilineTextAlignment(.center)
                // Only ever claimed when the order actually carries a refund —
                // free activations have nothing to give back, and asserting a
                // refund of 0 is the kind of small lie that costs the whole
                // screen its credibility.
                Text(order?.wasRefunded == true
                     ? String(localized: "Your credits have been put back. Try another domain from the picker.")
                     : String(localized: "Nothing was charged. Try another domain from the picker."))
                    .font(RFont.text(12))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)

        case .provisioning:
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(theme.text2)
                    Text("Reserving a mailbox")
                        .font(RFont.text(14, weight: .medium))
                        .foregroundStyle(theme.text)
                }
                Text("This takes a couple of seconds. The address appears above the moment it's yours.")
                    .font(RFont.text(12))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)

        case .ready:
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(theme.text2)
                    Text("Waiting for the code")
                        .font(RFont.text(14, weight: .medium))
                        .foregroundStyle(theme.text)
                }
                // No promised arrival time. We have measured nothing for email,
                // and quoting a number we have not measured is the
                // seed-etaSeconds mistake the SMS side already paid for.
                Text("Enter the address on the site, then come back — the code appears here.")
                    .font(RFont.text(12))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)
        }
    }
}
