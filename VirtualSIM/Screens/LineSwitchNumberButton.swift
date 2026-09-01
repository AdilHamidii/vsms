import SwiftUI

/// "Switch number · N credits" — the one affordance the second-number product
/// is built around since 2026-09-01 (owner decision): a number that receives
/// verification codes, and a fresh one for a few credits when a platform
/// refuses the current one.
///
/// It lived only behind the gear (in `LineSettingsScreen`) as "Change this
/// number", beneath the plan card and next to "Manage subscription". It now
/// renders on the live line itself, directly under the number, and the
/// settings sheet reuses the same view so the confirmation, the price and the
/// swap call have exactly one definition.
///
/// Price rules, unchanged from the settings-sheet original:
/// - `app_config.line_swap_credits` is read live (`state.appStatus`). NO client
///   default — a stale price in a confirmation dialog is the "+3 credits" card
///   that outlived its grant. Nil hides the button entirely.
/// - Only an ACTIVE line can be swapped; `begin_line_swap` refuses anything
///   else, and a button the server will refuse teaches the user the feature
///   is broken.
struct LineSwitchNumberButton: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api

    let line: Line
    /// `.primary` is the filled capsule for the live-line screen; `.ghost` is
    /// the quieter shape the settings sheet has always used.
    var style: Style = .primary

    enum Style { case primary, ghost }

    @State private var confirming = false
    @State private var swapping = false
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
                    PrimaryButton(label: swapping
                                  ? String(localized: "Getting a new number…")
                                  : String(localized: "Switch number · \(cost) credits"),
                                  icon: "arrow.triangle.2.circlepath",
                                  disabled: swapping) {
                        RHaptic.select()
                        confirming = true
                    }
                case .ghost:
                    GhostButton(label: swapping
                                ? String(localized: "Getting a new number…")
                                : String(localized: "Switch number · \(cost) credits"),
                                icon: "arrow.triangle.2.circlepath") {
                        RHaptic.select()
                        confirming = true
                    }
                    .disabled(swapping)
                }

                if let to = swappedTo {
                    Text("Your new number is \(PhoneFormat.national(to)). Share it wherever you used the old one.")
                        .font(RFont.text(12))
                        .foregroundStyle(theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // The one fact that has to survive being skim-read: the current
            // number is gone for good. A released number goes into a
            // hold-then-aging path nobody can pull it back from. Anyone still
            // receiving codes on it must be told BEFORE they tap, not after.
            .alert(String(localized: "Switch to a new number?"), isPresented: $confirming) {
                Button(String(localized: "Cancel"), role: .cancel) { }
                Button(String(localized: "Switch number"), role: .destructive) {
                    Task { await performSwap() }
                }
            } message: {
                Text("You'll get a new number in the same area code for \(cost) credits. \(PhoneFormat.national(line.e164)) is given up for good — you can't get it back, and anything still sending codes to it won't reach you.")
            }
        }
    }

    /// Buy a replacement number for this line.
    ///
    /// `swapping` is the re-entrancy guard as well as the button's busy state.
    /// Reloading the line afterwards is not cosmetic: every other surface —
    /// the header, the share sheet, the thread list — reads `state.lines`, so
    /// skipping it leaves the whole tab showing a number we just gave away.
    @MainActor
    private func performSwap() async {
        guard !swapping else { return }
        swapping = true
        swappedTo = nil
        defer { swapping = false }

        do {
            let result = try await LineAPI(client: api).swapNumber(lineId: line.id)
            await state.loadLine(using: LineAPI(client: api))
            // The wallet moved, and the credits pill reads AppState.
            await state.refreshWallet(using: WalletAPI(client: api))
            swappedTo = result.phoneNumber
            RHaptic.success()
        } catch let error as APIError {
            // Every failure path server-side refunds before returning, so the
            // banner is the whole story — there is no "and you were charged"
            // case to explain.
            state.showError(error)
        } catch {
            state.lastError = APIError.badResponse.userMessage
        }
    }
}
