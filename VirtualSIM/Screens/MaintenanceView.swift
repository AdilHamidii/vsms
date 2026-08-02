import SwiftUI
import Combine

/// Full-screen block shown while the weekly price sync runs. Counts down to the
/// estimated finish and re-checks the server flag so it lifts automatically the
/// moment the sync completes.
struct MaintenanceView: View {
    @Environment(\.theme) private var theme
    let until: Date?
    let message: String?
    var onRefresh: () -> Void = {}

    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(theme.chipBg).frame(width: 96, height: 96)
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(theme.text2)
                }
                VStack(spacing: 6) {
                    // The ?? made the whole thing a String, so the FALLBACK
                    // never localized. A server-provided message still renders
                    // verbatim (the key lookup misses), which is correct.
                    Text(message.map { LocalizedStringKey($0) } ?? "Refreshing prices")
                        .font(RFont.display(22, weight: .bold))
                        .tracking(-0.5)
                        .foregroundStyle(theme.text)
                    Text("We're updating live prices. Ordering is paused for a few minutes.")
                        .font(RFont.text(14))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(theme.text2)
                        .padding(.horizontal, 32)
                }
                if let countdown {
                    VStack(spacing: 2) {
                        MonoText(countdown, size: 30, weight: .semibold, color: theme.text)
                        Text("estimated")
                            .font(RFont.text(12))
                            .foregroundStyle(theme.text3)
                    }
                    .padding(.top, 4)
                }
                GhostButton(label: "Check again", icon: RIcon.refresh, fillsWidth: false, action: onRefresh)
                    .padding(.top, 6)
            }
            .padding(24)
        }
        .onReceive(tick) { now = $0 }
        .task {
            // Poll the server flag so we lift automatically when the sync ends.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                onRefresh()
            }
        }
    }

    private var secondsLeft: Int {
        guard let until else { return 0 }
        return max(0, Int(until.timeIntervalSince(now)))
    }

    private var countdown: String? {
        guard until != nil, secondsLeft > 0 else { return nil }
        return String(format: "%d:%02d", secondsLeft / 60, secondsLeft % 60)
    }
}
