import SwiftUI

struct OnboardingScreen: View {
    @Environment(\.theme) private var theme
    var onDone: () -> Void

    @State private var page: Int = 0

    private let pages: [OnboardingPage] = [
        .init(
            icon: "bolt.fill",
            tint: Color(hex: 0x1B2330),
            title: "A calmer way to verify",
            body: "vSMS gives you a fresh temporary number for the verification codes you need — without giving up your real number."
        ),
        .init(
            icon: "paperplane.fill",
            tint: Color(hex: 0x1FA463),
            title: "Three taps to a number",
            body: "Pick a service, pick a country, tap Get number. The code lands in the app in seconds. If it doesn't, you're auto-refunded."
        ),
        .init(
            icon: "hand.raised.fill",
            tint: Color(hex: 0x4A2A8E),
            title: "Private by default",
            body: "No ads. No tracking. No marketing emails. Your real number stays yours."
        ),
    ]

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { idx, p in
                        OnboardingPageView(page: p)
                            .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: page)

                dots

                bottomCTA
            }
        }
    }

    private var topBar: some View {
        HStack {
            Spacer()
            if page < pages.count - 1 {
                Button("Skip") {
                    onDone()
                }
                .font(RFont.text(15, weight: .medium))
                .foregroundStyle(theme.text2)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(0..<pages.count, id: \.self) { i in
                Capsule()
                    .fill(i == page ? theme.ink : theme.sepStrong)
                    .frame(width: i == page ? 22 : 6, height: 6)
                    .animation(.easeInOut(duration: 0.25), value: page)
            }
        }
        .padding(.bottom, 14)
    }

    private var bottomCTA: some View {
        VStack(spacing: 12) {
            PrimaryButton(
                label: page < pages.count - 1 ? "Continue" : "Get started",
                action: advance
            )
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
    }

    private func advance() {
        if page < pages.count - 1 {
            withAnimation { page += 1 }
        } else {
            onDone()
        }
    }
}

struct OnboardingPage {
    let icon: String
    let tint: Color
    let title: String
    let body: String
}

private struct OnboardingPageView: View {
    @Environment(\.theme) private var theme
    let page: OnboardingPage

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            iconBadge
            VStack(spacing: 12) {
                Text(page.title)
                    .font(RFont.display(28, weight: .bold))
                    .tracking(-0.7)
                    .foregroundStyle(theme.text)
                    .multilineTextAlignment(.center)
                Text(page.body)
                    .font(RFont.text(16))
                    .foregroundStyle(theme.text2)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)
            Spacer()
            Spacer()
        }
    }

    private var iconBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(page.tint)
                .frame(width: 120, height: 120)
                .shadow(color: page.tint.opacity(0.4), radius: 26, x: 0, y: 8)
            Image(systemName: page.icon)
                .font(.system(size: 50, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}
