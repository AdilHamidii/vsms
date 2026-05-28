import SwiftUI

struct ErrorBanner: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state

    var body: some View {
        if let message = state.lastError {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.fail)
                Text(message)
                    .font(RFont.text(13, weight: .medium))
                    .foregroundStyle(theme.text)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Button {
                    state.lastError = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.text2)
                        .padding(6)
                        .background(theme.chipBg, in: .circle)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(theme.elev, in: .rect(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(theme.fail.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.10), radius: 14, x: 0, y: 4)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: message) {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if state.lastError == message {
                    withAnimation(.easeOut(duration: 0.25)) {
                        state.lastError = nil
                    }
                }
            }
        }
    }
}
