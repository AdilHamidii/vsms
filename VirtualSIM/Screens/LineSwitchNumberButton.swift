import SwiftUI

/// "Switch" — the swap's two entry points (spec §4.5, owner 2026-09-24):
/// a compact capsule on the number card, right of the number, and a
/// "Switch number…" row in the Number segment. Both open `LineSwapSheet`.
///
/// ── No price on the control (owner decision 2026-09-05) ───────────────────
/// The price, the balance, the top-up path and "given up for good" live on
/// the sheet's LAST page, after a number is chosen, so nothing is offered
/// that `begin_line_swap` would refuse for money. The confirm page is the
/// safety net against an accidental tap.
///
/// Price rules, unchanged: `app_config.line_swap_credits` is read live and
/// has NO client default — nil HIDES the control (a sheet that cannot quote a
/// price cannot ask for money). Only an ACTIVE line swaps. Hidden, never
/// disabled.
struct LineSwitchNumberButton: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    @Environment(IAPStore.self) private var iap
    @Environment(CallController.self) private var calls

    let line: Line
    var style: Style = .compact
    /// `line_swap_open.from`: "home" (the card) or "number_segment" (the row).
    let from: String
    /// The new number, reported once the sheet has gone.
    var onSwapped: (String) -> Void = { _ in }

    enum Style { case compact, row }

    @State private var choosing = false
    /// A swap that landed while the sheet was still up, reported (and
    /// cleared) on dismiss. Cleared on every dismiss and every open, so it
    /// can never be read by a later, unrelated sheet.
    @State private var completedSwap: String?

    /// The one definition of "the swap is offered", for callers that lay out
    /// around the control (the Number segment's divider).
    static func isOffered(for line: Line, state: AppState) -> Bool {
        state.appStatus.lineSwapCredits != nil && line.status == .active
    }

    var body: some View {
        if let cost = state.appStatus.lineSwapCredits, line.status == .active {
            trigger
                // The picker borrows the tab's search state; clearing it on the
                // way out keeps the store from inheriting a swap's place.
                //
                // A swap is reported ONCE, and the line reloaded, in one of two
                // places depending on when the cutover lands:
                // - sheet still up (the normal case): parked in `completedSwap`
                //   and reported HERE, after the sheet has gone, so the card's
                //   number visibly rolls to the new one (spec §3a) — the
                //   sheet's own last page shows the new number meanwhile;
                // - sheet already gone (a swipe-dismiss mid-request, or a live
                //   call closing it): reported straight from the callback in
                //   `swapLanded`, because no `onDismiss` is left to read it.
                .sheet(isPresented: $choosing, onDismiss: {
                    state.clearLineDraft()
                    let number = completedSwap
                    completedSwap = nil          // never outlives this sheet
                    if let number { report(number) }
                }) {
                    LineSwapSheet(line: line, cost: cost, from: from, onSwapped: swapLanded)
                        // 🔴 Sheet content does NOT inherit `@Observable`
                        // environment objects. `IAPStore` is what the top-up
                        // path needs, and it is a crash, not a blank screen.
                        .environment(\.theme, theme)
                        .environment(state)
                        .environment(api)
                        .environment(iap)
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(theme.bg)
                }
                // A picker is not work worth preserving over a live call, and
                // a sheet would sit above the call screen (telephony trap 5).
                .onChange(of: calls.isLive) { _, live in if live { choosing = false } }
                .onAppear {
                    // Screenshot harness: the HOME instance raises the sheet.
                    if ScreenshotMode.screen == .lineSwapConfirm, from == "home" { choosing = true }
                }
        }
    }

    @ViewBuilder
    private var trigger: some View {
        switch style {
        case .compact:
            // Visible without competing (spec §4.5): neutral fill, a 1pt accent
            // border, never accent-filled — the one-green rule holds.
            Button(action: open) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Switch")
                        .font(RFont.text(15, weight: .semibold))
                }
                .foregroundStyle(theme.text)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(theme.chipBg, in: .capsule)
                .overlay(Capsule().strokeBorder(theme.ink, lineWidth: 1))
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(PressScaleStyle(scale: 0.95))
            .fixedSize()
            .accessibilityLabel(Text("Switch number"))
        case .row:
            Button(action: open) {
                HStack(spacing: RSpace.md) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.text2)
                        .frame(width: 28)
                    Text("Switch number…")
                        .font(RFont.text(16))
                        .foregroundStyle(theme.text)
                    Spacer(minLength: RSpace.sm)
                    Image(systemName: RIcon.chev)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.text3)
                }
                .padding(.horizontal, RSpace.lg)
                .frame(minHeight: 52)
                .contentShape(.rect)
            }
            .buttonStyle(PressScaleStyle(scale: 0.98, dim: true))
        }
    }

    private func open() {
        RHaptic.select()
        completedSwap = nil
        choosing = true
    }

    /// The sheet's success callback. `perform` runs in an unstructured task,
    /// so the sheet can already be closed when the cutover lands; parking the
    /// number then would leave the card on the given-up number and fire a
    /// stray confirmation on the next unrelated dismiss.
    private func swapLanded(_ number: String) {
        if choosing {
            completedSwap = number
        } else {
            report(number)
        }
    }

    private func report(_ number: String) {
        onSwapped(number)
        Task { await state.loadLine(using: LineAPI(client: api)) }
    }
}
