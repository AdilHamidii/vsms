import SwiftUI

struct OtpScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state

    let order: Order
    @State private var copied = false

    private var otpValue: String { order.otp ?? "" }
    private var otpDigits: [String] { otpValue.map { String($0) } }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    topBar
                    serviceStrip
                    codeCard
                    messageBubble
                }
                .padding(.top, 6)
                .padding(.bottom, 60)
            }
            .scrollIndicators(.hidden)
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
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
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
            StatusBadge(status: .received)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var codeCard: some View {
        Card {
            ZStack(alignment: .top) {
                Ellipse()
                    .fill(theme.glow)
                    .frame(width: 240, height: 160)
                    .blur(radius: 40)
                    .offset(y: -40)
                    .opacity(0.7)
                    .allowsHitTesting(false)

                VStack(spacing: 0) {
                    Text("VERIFICATION CODE")
                        .font(RFont.text(12, weight: .medium))
                        .tracking(0.3)
                        .foregroundStyle(theme.text2)
                    HStack(spacing: 10) {
                        ForEach(Array(otpDigits.enumerated()), id: \.offset) { idx, d in
                            OtpDigit(digit: d, idx: idx, style: state.otpAnimation)
                        }
                    }
                    .padding(.top, 18)
                    VStack(spacing: 8) {
                        PrimaryButton(
                            label: copied ? "Copied" : "Copy code",
                            icon: copied ? RIcon.check : RIcon.copy,
                            action: copy
                        )
                        Button {
                            state.flow = nil
                            state.startCheckout(service: order.service, country: order.country)
                        } label: {
                            Text("Get another \(order.service.name) number")
                                .font(RFont.text(14, weight: .medium))
                                .tracking(-0.2)
                                .foregroundStyle(theme.text2)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 24)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 28)
            }
        }
        .clipShape(.rect(cornerRadius: 22))
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var messageBubble: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: RIcon.inbox)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.text2)
                    Text("RAW MESSAGE")
                        .font(RFont.text(12, weight: .medium))
                        .tracking(0.2)
                        .foregroundStyle(theme.text2)
                    Spacer()
                    Text("just now")
                        .font(RFont.text(11))
                        .foregroundStyle(theme.text3)
                }
                Text(rawMessageAttributed)
                    .lineSpacing(2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var rawMessageAttributed: AttributedString {
        var prefix = AttributedString("[\(order.service.name)] ")
        prefix.font = RFont.mono(13)
        prefix.foregroundColor = theme.text2

        var middle = AttributedString("Your verification code is ")
        middle.font = RFont.text(14)
        middle.foregroundColor = theme.text

        var code = AttributedString(otpValue)
        code.font = RFont.mono(14, weight: .semibold)
        code.foregroundColor = theme.text

        var suffix = AttributedString(". Do not share it.")
        suffix.font = RFont.text(14)
        suffix.foregroundColor = theme.text

        return prefix + middle + code + suffix
    }

    private func copy() {
        UIPasteboard.general.string = otpValue
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            copied = false
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
            .background(theme.chipBg, in: .rect(cornerRadius: 12))
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
