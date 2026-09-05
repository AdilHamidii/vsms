import SwiftUI

/// "Change number" — the one affordance the second-number product is built
/// around since 2026-09-01 (owner decision): a number that receives
/// verification codes, and a fresh one for a few credits when a platform
/// refuses the current one.
///
/// It renders on the live line itself, directly under the number, and the
/// settings sheet reuses the same view so the entry point has exactly one
/// definition. What it opens is `LineSwapSheet`.
///
/// ── No price on the button (owner decision 2026-09-05) ────────────────────
///
/// It used to read "Switch number · 8 credits" and, on confirm, bought the
/// first free number in the same area code without checking the wallet. The
/// first real complaint ("changing my number doesn't work") was a user with 6
/// credits tapping an 8-credit button and getting a 402. Now the button names
/// the action only; the price, the balance and the top-up path live on the
/// LAST page of the sheet, after the user has chosen a country, a city and a
/// number — so nothing is ever offered that the server would refuse for money.
///
/// Price rules, unchanged:
/// - `app_config.line_swap_credits` is read live (`state.appStatus`). NO client
///   default — a stale price in a confirmation is the "+3 credits" card that
///   outlived its grant. Nil hides the button entirely, because a sheet that
///   cannot quote a price cannot ask for money honestly.
/// - Only an ACTIVE line can be swapped; `begin_line_swap` refuses anything
///   else, and a button the server will refuse teaches the user the feature
///   is broken.
struct LineSwitchNumberButton: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    @Environment(IAPStore.self) private var iap

    let line: Line
    /// `.primary` is the filled capsule for the live-line screen; `.ghost` is
    /// the quieter shape the settings sheet has always used.
    var style: Style = .primary

    enum Style { case primary, ghost }

    @State private var choosing = false
    /// The number we moved to, held only long enough to confirm it on screen.
    /// Without this the row simply changes underneath the user and nothing
    /// says the thing they paid for actually happened.
    @State private var swappedTo: String?

    private var swapCredits: Int? { state.appStatus.lineSwapCredits }
    private var canSwap: Bool { swapCredits != nil && line.status == .active }

    var body: some View {
        if canSwap, let cost = swapCredits {
            VStack(alignment: .leading, spacing: 8) {
                switch style {
                case .primary:
                    PrimaryButton(label: String(localized: "Change number"),
                                  icon: "arrow.triangle.2.circlepath") {
                        RHaptic.select()
                        choosing = true
                    }
                case .ghost:
                    GhostButton(label: String(localized: "Change number"),
                                icon: "arrow.triangle.2.circlepath") {
                        RHaptic.select()
                        choosing = true
                    }
                }

                if let to = swappedTo {
                    Text("Your new number is \(PhoneFormat.national(to)). Share it wherever you used the old one.")
                        .font(RFont.text(12))
                        .foregroundStyle(theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // The picker borrows the Number tab's search state; on the way out
            // it is cleared so the store never inherits a swap's country, city
            // or offers. `clearLineDraft` is the same reset the tab runs on
            // leaving — the dialer cannot be open under this sheet, so the
            // call-price fields it also clears are already idle.
            .sheet(isPresented: $choosing, onDismiss: { state.clearLineDraft() }) {
                LineSwapSheet(line: line, cost: cost) { swappedTo = $0 }
                    // 🔴 Sheet content does NOT inherit `@Observable`
                    // environment objects from its presenter. `IAPStore` is
                    // what the top-up path inside needs, and it is a crash on
                    // presentation rather than a blank screen.
                    .environment(\.theme, theme)
                    .environment(state)
                    .environment(api)
                    .environment(iap)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(theme.bg)
            }
        }
    }
}
