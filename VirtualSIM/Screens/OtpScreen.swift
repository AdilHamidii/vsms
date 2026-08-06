import SwiftUI
import StoreKit

/// The code arrived. The whole job of this screen is to get those digits into
/// the other app and then get out of the way.
///
/// It used to have no way out at all except the ✕ in the corner — while
/// `EmailCodeScreen`, the same moment one product line over, has a Done
/// primary. And the second thing under the code, above anything telling the
/// user what to do with it, was **"Get another \(service) number"**: an upsell
/// offered at the instant of success, before the success has been used. The
/// order is now Copy → what to do with it → Done, and the two "what next"
/// affordances sit BELOW Done where they belong.
struct OtpScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(\.requestReview) private var requestReview

    let order: Order
    @State private var copied = false
    @State private var appeared = false

    private var otpValue: String { order.otp ?? "" }
    private var otpDigits: [String] { otpValue.map { String($0) } }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    topBar
                    serviceStrip
                    codeCard
                    messageBubble
                    whatNext
                }
                .padding(.top, 6)
                .padding(.bottom, 60)
            }
            .scrollIndicators(.hidden)
        }
        .onAppear(perform: arrive)
    }

    /// Everything that should happen the moment the digits are on screen.
    ///
    /// **The code is copied for the user.** It is a verification code with one
    /// use and one destination; making someone tap a button to move six digits
    /// they are about to paste is ceremony, not consent. The Copy button stays
    /// (the clipboard can be overwritten between here and the other app, and
    /// the button is the only way back) — it simply opens already confirmed.
    private func arrive() {
        guard !appeared else { return }
        appeared = true
        guard !otpValue.isEmpty else { return }

        UIPasteboard.general.string = otpValue
        copied = true
        // The screen the product exists for. A silent success on iOS reads as a
        // screen that did not respond.
        RHaptic.success()

        Task {
            // Return the button to its resting label so it stays usable rather
            // than sitting on a stale "Copied" for the life of the screen.
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            withAnimation(RMotion.content) { copied = false }
        }
        maybeAskForReview()
    }

    /// The user's happiest moment. If the gate allows, let the digit-reveal
    /// animation finish, then show Apple's native review sheet. Never tied to
    /// any reward (App Store 5.6.4).
    private func maybeAskForReview() {
        guard state.shouldRequestReview(forOrderId: order.id) else { return }
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            requestReview()
        }
    }

    private var topBar: some View {
        HStack {
            Color.clear.frame(width: 36, height: 36)
            Spacer()
            Text("Code received")
                .font(RFont.display(16, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(theme.text)
            Spacer()
            Button {
                state.finishOtp()
            } label: {
                Image(systemName: RIcon.close)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text2)
                    .frame(width: 36, height: 36)
                    .background(theme.chipBg, in: .circle)
            }
            .pressable()
        }
        .padding(.horizontal, 16)
    }

    private var serviceStrip: some View {
        HStack(spacing: 10) {
            ServiceLogo(service: order.service, size: 32, radius: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(order.service.name)
                    .font(RFont.display(15, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(theme.text)
                HStack(spacing: 6) {
                    Text(order.country.flag).font(.system(size: 12))
                    MonoText(order.number, size: 12, color: theme.text2)
                }
            }
            Spacer()
            // Real status, not a hardcoded .received. A rescued code lands on
            // a CANCELED order (refund stands, code given away) — asserting
            // "received" there would contradict the history row and the refund.
            StatusBadge(status: order.status)
        }
        .padding(.horizontal, 20)
    }

    private var codeCard: some View {
        HeroCard {
            VStack(spacing: 0) {
                MicroLabel("Verification code")

                HStack(spacing: 10) {
                    ForEach(Array(otpDigits.enumerated()), id: \.offset) { idx, d in
                        OtpDigit(digit: d, idx: idx, style: state.otpAnimation)
                    }
                }
                .padding(.top, 16)

                PrimaryButton(
                    label: copied ? String(localized: "Copied") : String(localized: "Copy code"),
                    icon: copied ? RIcon.check : RIcon.copy,
                    action: copy
                )
                .padding(.top, 22)

                // The instruction, not an upsell. This is the slot the "get
                // another number" button used to occupy.
                Text("Paste it into \(order.service.name) to finish verifying.")
                    .font(RFont.text(13))
                    .foregroundStyle(theme.text2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)

                GhostButton(label: String(localized: "Done"), icon: RIcon.check) {
                    state.finishOtp()
                }
                .padding(.top, 14)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 26)
        }
        .padding(.horizontal, 16)
    }

    private var messageBubble: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: RIcon.inbox)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.text3)
                    // Only claim "RAW MESSAGE" when it really is one.
                    MicroLabel(hasRawMessage ? "Raw message" : "Code received")
                    Spacer(minLength: 0)
                    Text(arrivedAgo)
                        .font(RFont.text(11))
                        .foregroundStyle(theme.text3)
                }
                Text(rawMessageAttributed)
                    .lineSpacing(2)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .padding(.horizontal, 16)
    }

    /// Everything that is about the NEXT thing rather than this one, kept
    /// below Done and rendered as quiet chrome.
    ///
    /// The invite lived only in a card in the 4th tab and produced exactly ZERO
    /// referrals across 146 users — a placement failure, not a demand failure,
    /// so it stays on this screen. It just no longer competes with the code.
    private var whatNext: some View {
        VStack(spacing: 4) {
            Button {
                state.flow = nil
                state.startCheckout(service: order.service, country: order.country)
            } label: {
                Text("Get another \(order.service.name) number")
                    .font(RFont.text(13, weight: .medium))
                    .foregroundStyle(theme.text2)
                    .padding(.vertical, 10)
            }
            .pressable()

            if let invite = state.inviteMessage {
                ShareLink(item: invite) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Invite a friend and they start with \(AppState.inviteJoinerCredits) credits")
                            .font(RFont.text(13, weight: .medium))
                    }
                    .foregroundStyle(theme.text3)
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var hasRawMessage: Bool {
        !(order.server.rawMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }

    /// When the code actually landed, not a hardcoded "just now" — this card
    /// is also reached from order history, where "just now" was simply false.
    private var arrivedAgo: String {
        guard let at = order.server.arrivedAt else { return "" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: at, relativeTo: Date())
    }

    /// The REAL SMS body when we have it.
    ///
    /// This used to compose "[Service] Your verification code is NNNN. Do not
    /// share it." from the code alone and label it RAW MESSAGE — inventing the
    /// text and presenting it as the message we received. `orders.raw_message`
    /// holds the genuine body (written by check-order) and was decoded into
    /// ServerOrder but read by nothing, so anyone whose SMS carried a link,
    /// extra instructions, or a differently-formatted code never saw it.
    /// Falls back to showing just the code, clearly labelled, rather than
    /// fabricating a sentence around it.
    private var rawMessageAttributed: AttributedString {
        if let raw = order.server.rawMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            var body = AttributedString(raw)
            body.font = RFont.text(14)
            body.foregroundColor = theme.text
            // Highlight the code inside the real message so it stays scannable.
            if let r = body.range(of: otpValue) {
                body[r].font = RFont.mono(14, weight: .semibold)
            }
            return body
        }
        var code = AttributedString(otpValue)
        code.font = RFont.mono(14, weight: .semibold)
        code.foregroundColor = theme.text
        return code
    }

    private func copy() {
        UIPasteboard.general.string = otpValue
        RHaptic.copied()
        withAnimation(RMotion.content) { copied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation(RMotion.content) { copied = false }
        }
    }
}

private struct OtpDigit: View {
    @Environment(\.theme) private var theme
    let digit: String
    let idx: Int
    let style: OtpAnimation

    @State private var revealed = false

    var body: some View {
        Text(digit)
            .font(RFont.mono(30, weight: .medium))
            .foregroundStyle(theme.text)
            .frame(width: 44, height: 56)
            .background(theme.chipBg, in: .rect(cornerRadius: RRadius.sm))
            .offset(y: revealed ? 0 : offset)
            .blur(radius: revealed ? 0 : blur)
            .opacity(revealed ? 1 : 0)
            .rotation3DEffect(.degrees(revealed ? 0 : flipAngle),
                              axis: (x: 1, y: 0, z: 0),
                              perspective: 0.6)
            .onAppear {
                let d = delay
                withAnimation(.easeOut(duration: 0.5).delay(d)) {
                    revealed = true
                }
            }
    }

    private var delay: Double {
        switch style {
        case .cascade: Double(idx) * 0.12
        case .reveal:  0
        case .flip:    Double(idx) * 0.06
        }
    }
    private var offset: CGFloat {
        switch style {
        case .cascade: 8
        case .reveal:  28
        case .flip:    0
        }
    }
    private var blur: CGFloat {
        switch style {
        case .cascade: 4
        case .reveal:  0
        case .flip:    0
        }
    }
    private var flipAngle: Double {
        style == .flip ? 90 : 0
    }
}
