import SwiftUI

// Two-page onboarding. Page 1: the product itself doing its one job — a
// temporary number sitting on a card, a verification SMS typing in, and the
// code landing highlighted in brand green — the same surfaces the user meets
// on the Waiting/OTP screens. Page 2: the welcome credit — every new account
// starts with 1 free credit, and users convert better when they're told
// before the sign-in ask. No abstract icon badges anywhere.
struct OnboardingScreen: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onDone: () -> Void

    @State private var page = 0

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Spacer(minLength: 16)
                Group {
                    if page == 0 {
                        VStack(spacing: 30) {
                            InboxDemo(reduceMotion: reduceMotion)
                                .padding(.horizontal, 22)
                            copyBlock
                        }
                        .transition(pageTransition)
                    } else {
                        VStack(spacing: 30) {
                            GiftCard()
                                .padding(.horizontal, 22)
                            giftCopyBlock
                        }
                        .transition(pageTransition)
                    }
                }
                Spacer(minLength: 16)
                footer
            }
        }
    }

    private var pageTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                          removal: .move(edge: .leading).combined(with: .opacity))
    }

    private var header: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.ink)
                .frame(width: 22, height: 22)
                .overlay(
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.onInk)
                )
            Text("vSMS")
                .font(RFont.display(17, weight: .bold))
                .tracking(-0.3)
                .foregroundStyle(theme.text)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .frame(height: 44)
    }

    private var copyBlock: some View {
        VStack(spacing: 14) {
            Text("Get the code,\nkeep your number.")
                .font(RFont.display(30, weight: .bold))
                .tracking(-0.8)
                .lineSpacing(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.text)
            Text("Rent a throwaway phone number, catch the verification SMS right here, and keep your real one off every signup form.")
                .font(RFont.text(15))
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
        }
        .padding(.horizontal, 24)
    }

    private var giftCopyBlock: some View {
        VStack(spacing: 14) {
            Text("Your first try is on us.")
                .font(RFont.display(30, weight: .bold))
                .tracking(-0.8)
                .lineSpacing(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.text)
            Text("Sign in and you'll find 1 free credit waiting — enough to get a number and see the code arrive before you spend anything.")
                .font(RFont.text(15))
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
        }
        .padding(.horizontal, 24)
    }

    private var footer: some View {
        VStack(spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.live)
                Text("No ads or tracking. No code, no charge — refunded instantly.")
                    .font(RFont.text(12.5))
                    .foregroundStyle(theme.text3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            pageDots
            if page == 0 {
                PrimaryButton(label: "Continue", action: {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.85)) {
                        page = 1
                    }
                })
            } else {
                PrimaryButton(label: "Get started", action: onDone)
                Text("Sign in with Apple next — that's the only detail we ask for.")
                    .font(RFont.text(11.5))
                    .foregroundStyle(theme.text3)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .padding(.top, 2)
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<2, id: \.self) { i in
                Capsule()
                    .fill(page == i ? theme.text : theme.sep)
                    .frame(width: page == i ? 16 : 6, height: 6)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: page)
        .accessibilityHidden(true)
    }
}

// MARK: - Welcome credit card

private struct GiftCard: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("WELCOME GIFT")
                        .font(RFont.text(11, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(theme.text3)
                    Spacer()
                    Image(systemName: "gift.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.live)
                }
                HStack(spacing: 10) {
                    CoinIcon(size: 22, color: theme.text)
                    Text("+1 credit")
                        .font(RFont.display(28, weight: .bold))
                        .tracking(-0.6)
                        .foregroundStyle(theme.text)
                    Spacer(minLength: 0)
                }
                .padding(.top, 14)
                Rectangle().fill(theme.sep).frame(height: 0.5)
                    .padding(.vertical, 16)
                VStack(alignment: .leading, spacing: 10) {
                    giftRow(symbol: "bolt.fill", text: "Covers your first number")
                    giftRow(symbol: "arrow.uturn.left", text: "No code? Refunded instantly.")
                }
            }
            .padding(20)
        }
    }

    private func giftRow(symbol: String, text: LocalizedStringKey) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.live)
                .frame(width: 16)
            Text(text)
                .font(RFont.text(14))
                .foregroundStyle(theme.text2)
        }
    }
}

// MARK: - Live "code arrives" demo

private struct InboxDemo: View {
    @Environment(\.theme) private var theme
    let reduceMotion: Bool

    // 0 = number only, 1 = sender typing, 2 = code delivered.
    @State private var phase = 0
    @State private var livePulse = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                cardHeader
                numberRow
                Rectangle().fill(theme.sep).frame(height: 0.5)
                    .padding(.vertical, 18)
                thread
            }
            .padding(20)
        }
        .task { await run() }
    }

    private var cardHeader: some View {
        HStack {
            Text("YOUR TEMPORARY NUMBER")
                .font(RFont.text(11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(theme.text3)
            Spacer()
            HStack(spacing: 5) {
                Circle()
                    .fill(theme.live)
                    .frame(width: 6, height: 6)
                    .opacity(livePulse ? 1 : 0.3)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: livePulse)
                Text("Live")
                    .font(RFont.text(11, weight: .semibold))
                    .foregroundStyle(theme.live)
            }
        }
    }

    private var numberRow: some View {
        HStack(spacing: 10) {
            Text("🇫🇷").font(.system(size: 26))
            MonoText("+33 6 12 34 56 78", size: 21, weight: .medium, color: theme.text)
            Spacer(minLength: 0)
        }
        .padding(.top, 14)
    }

    private var thread: some View {
        Group {
            if phase >= 2 {
                smsBubble
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if phase == 1 {
                TypingDots()
                    .transition(.opacity)
            } else {
                // Hold the vertical space so the card doesn't jump on delivery.
                Color.clear.frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
    }

    private var smsBubble: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Instagram")
                .font(RFont.text(12, weight: .semibold))
                .foregroundStyle(theme.text2)
            (
                Text("Your code is ").font(RFont.text(15)).foregroundStyle(theme.text)
                + Text("4827").font(RFont.mono(16, weight: .bold)).foregroundStyle(theme.live)
                + Text(" — don't share it.").font(RFont.text(15)).foregroundStyle(theme.text)
            )
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.elev2, in: .rect(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.sep, lineWidth: 0.5)
        )
    }

    private func run() async {
        livePulse = true
        if reduceMotion { phase = 2; return }
        try? await Task.sleep(nanoseconds: 650_000_000)
        withAnimation(.easeInOut(duration: 0.25)) { phase = 1 }
        try? await Task.sleep(nanoseconds: 1_300_000_000)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { phase = 2 }
    }
}

private struct TypingDots: View {
    @Environment(\.theme) private var theme
    @State private var active = 0

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(theme.text3)
                    .frame(width: 7, height: 7)
                    .opacity(active == i ? 1 : 0.35)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(theme.elev2, in: .rect(cornerRadius: 16))
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                withAnimation(.easeInOut(duration: 0.2)) { active = (active + 1) % 3 }
            }
        }
    }
}
