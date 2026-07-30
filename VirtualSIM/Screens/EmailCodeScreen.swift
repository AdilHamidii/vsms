import StoreKit   // \.requestReview lives here — see OtpScreen
import SwiftUI

/// The code arrived at a temporary address.
///
/// Mirrors `OtpScreen`'s job for the email line, including the review prompt —
/// which stays on Apple's native API, fires only from the 2nd successful code
/// onward, and is never tied to a reward (App Store 5.6.4).
struct EmailCodeScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(\.requestReview) private var requestReview

    @State private var copied = false

    private var order: ServerEmailOrder? { state.activeEmailOrder }
    private var code: String { order?.code ?? "" }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                badge
                codeCard
                    .padding(.top, 22)
                addressLine
                    .padding(.top, 14)
                Spacer()
                PrimaryButton(label: "Done", icon: RIcon.check) { state.flow = nil }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .task {
            guard let id = order?.id, state.shouldRequestReview(forOrderId: id) else { return }
            // A beat, so the prompt lands after the user has seen the code
            // rather than on top of it.
            try? await Task.sleep(nanoseconds: 900_000_000)
            requestReview()
        }
    }

    private var badge: some View {
        HStack(spacing: 7) {
            Image(systemName: RIcon.check)
                .font(.system(size: 12, weight: .bold))
            Text("Code received")
                .font(RFont.text(13, weight: .semibold))
        }
        .foregroundStyle(theme.live)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(theme.liveSoft, in: .capsule)
    }

    private var codeCard: some View {
        Button {
            UIPasteboard.general.string = code
            withAnimation(.easeOut(duration: 0.2)) { copied = true }
        } label: {
            VStack(spacing: 12) {
                Text(code.isEmpty ? "—" : code)
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
                .foregroundStyle(theme.text2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
            .background(theme.elev, in: .rect(cornerRadius: 22))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(code.isEmpty)
    }

    private var addressLine: some View {
        Text(order?.email ?? "")
            .font(RFont.mono(13))
            .foregroundStyle(theme.text3)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}
