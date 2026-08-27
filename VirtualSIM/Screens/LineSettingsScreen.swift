import StoreKit
import SwiftUI

/// Everything about the number that is not a message or a call: the plan, the
/// swap, Apple's subscription sheet, renting another, and the emergency-calling
/// disclosure App Review looks for.
///
/// It was the Number tab's third SEGMENT until 2026-08-27, sitting beside
/// Messages and Calls as though "what my plan costs" were a thing a phone app
/// shows you every day. It is not: a phone app has two surfaces you live in
/// (recents and conversations) and a settings screen you visit twice a year.
/// Moving it behind the gear buys the two live surfaces a third of the screen
/// back and stops the segmented control implying three equal destinations.
///
/// 🔴 PRESENTED AS A `.sheet`, SO IT MUST BE WRAPPED IN `EnvBundle` AT THE
/// PRESENTATION SITE. Sheet content does not inherit `@Observable` environment
/// objects from its presenter — `SubscriptionStore` in particular, whose
/// absence is a crash on presentation rather than a graceful blank.
struct LineSettingsScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(SubscriptionStore.self) private var subs
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss

    let line: Line

    /// Called after this sheet has asked to be dismissed. Setting
    /// `state.flow` from inside a sheet presents a `fullScreenCover` on a view
    /// that is on its way out — the presenter must do it once the sheet is
    /// actually gone, which is why this is a callback and not a direct
    /// assignment. See `LiveLineView.pendingRentAnother`.
    var onRentAnother: () -> Void

    @State private var confirmingSwap = false
    @State private var swapping = false
    /// The number we moved to, held only long enough to confirm it on screen.
    /// Without this the row simply changes underneath the user and nothing
    /// says the thing they paid for actually happened.
    @State private var swappedTo: String?

    /// What a swap costs, or nil if the server has not told us.
    ///
    /// ⚠️ NO CLIENT DEFAULT. `app_config.line_swap_credits` changes without a
    /// release, so a fallback here would put a stale price in a confirmation
    /// dialog — the same defect as the "+3 credits" onboarding card that
    /// outlived its grant. Nil hides the control entirely, which is the honest
    /// failure: better to offer nothing than to quote a price we cannot stand
    /// behind.
    private var swapCredits: Int? { state.appStatus.lineSwapCredits }

    /// Only an ACTIVE line can be swapped — `begin_line_swap` refuses anything
    /// else, and showing a button that the server will refuse is how a user
    /// learns the feature is broken.
    private var canSwap: Bool {
        swapCredits != nil && line.status == .active
    }

    /// Is the Apple subscription paying for THIS number?
    ///
    /// Apple allows one active subscription per group with no quantity, so it
    /// can only ever pay for one line — while credits can rent as many as the
    /// wallet allows. Nothing on the client can join the two: `my_line`
    /// projects no billing source, and `line_subscriptions` is server-side and
    /// FK-free by design.
    ///
    /// Two things we CAN substantiate: the number this launch's purchase
    /// provisioned, and the degenerate case where the only live line there is
    /// must be the subscribed one. Anything else is unattributable and renders
    /// no plan row at all. A missing row is honest; a wrong price on the wrong
    /// number is not.
    private var isSubscriptionBillable: Bool {
        if let e164 = subs.provisionedE164, e164 == line.e164 { return true }
        return state.lines.filter { $0.status.isLive }.count == 1
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: String(localized: "Number settings"))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    planCard
                    swapSection
                    manageSection
                    emergencySection
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
        }
        .background(theme.bg)
    }

    // MARK: - Plan

    @ViewBuilder
    private var planCard: some View {
        SectionHeader(label: String(localized: "Your plan"))
            // An existing subscriber never passes through the store or the
            // paywall, so nothing else would have loaded the product and the
            // price would read as its fallback forever.
            .task {
                await subs.loadProduct()
                // Which plan they HOLD, not which the paywall has selected.
                // Without this the price row cannot be shown at all.
                await subs.refreshOwnedPlan()
            }
        Card {
            VStack(spacing: 0) {
                row(label: "Number", value: PhoneFormat.national(line.e164))
                divider
                // ⚠️ NEVER a literal. This read "$9.99 / month" while the
                // paywall's own button read StoreKit's localized price — so a
                // euro subscriber saw "9,99 €/mo" to buy and "$9.99 / month" on
                // the plan screen for the same subscription. Exactly the drift
                // that put $4.99 against €5.99 on the credit ladder's top
                // product.
                //
                // 🔴 AND NEVER `subs.displayPrice`, which follows the PAYWALL's
                // `selectedPlan`. It defaults to monthly, so every yearly
                // subscriber — three of the first five — read "$9.99 / month"
                // for a $99.99/year plan; and after a visit to "Rent another
                // number" → Yearly it read "$99.99 / month", wrong by a factor
                // of twelve. The period now comes from the entitlement the
                // Apple ID actually holds, and when that is unknown the row is
                // OMITTED. A missing row is honest.
                //
                // 🔴 AND ONLY ON A LINE WE CAN ATTRIBUTE TO THAT SUBSCRIPTION.
                // Credits rent lines too, and `Line` carries no billing source
                // — `my_line` does not project one — so a user holding one
                // subscribed line and one credit-rented line read "$99.99 /
                // year" on the number Apple charges nothing for. See
                // `isSubscriptionBillable`.
                if isSubscriptionBillable,
                   let price = subs.ownedPlanPrice, let plan = subs.ownedPlan {
                    row(label: "Price",
                        value: plan == .yearly
                            ? String(localized: "\(price) / year")
                            : String(localized: "\(price) / month"))
                    divider
                }
                row(label: renewLabel, value: renewValue)
                divider
                // 🔴 A "Texts left · N of 200" row lived here and is GONE. It
                // metered an allowance that can no longer be spent (outbound
                // SMS dropped 2026-08-18), and it must NOT be turned into an
                // inbound counter: inbound is never metered, so a
                // received-texts figure would invent a cap this product does
                // not have. Same rule that removed the figure from the paywall.
                row(label: "Minutes left",
                    value: "\(line.voiceSecondsRemaining / 60) of \(line.voiceAllowanceSeconds / 60)")
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Swap

    /// ── Change this number ──────────────────────────────────────────────
    /// Placed ABOVE "Manage subscription" deliberately. A yearly subscriber is
    /// locked in for a year, so if their number gets spam-flagged or blocked by
    /// a service they care about, the most discoverable control on this screen
    /// must not be the one that cancels — the alternative to a swap is a $99.99
    /// refund request we cannot decline.
    @ViewBuilder
    private var swapSection: some View {
        if canSwap, let cost = swapCredits {
            GhostButton(
                label: swapping
                    ? String(localized: "Getting a new number…")
                    : String(localized: "Change this number"),
                icon: "arrow.triangle.2.circlepath"
            ) {
                RHaptic.select()
                confirmingSwap = true
            }
            .disabled(swapping)
            .padding(.top, 16)

            // The one fact that has to survive being skim-read: the current
            // number is gone for good. Telnyx puts a released number into a
            // hold-then-aging path that nobody — not the user, not us, not by
            // paying again — can pull it back from. Anyone still receiving
            // codes on it must be told BEFORE they tap, not after.
            .alert(String(localized: "Change this number?"),
                   isPresented: $confirmingSwap) {
                Button(String(localized: "Cancel"), role: .cancel) { }
                Button(String(localized: "Change number"), role: .destructive) {
                    Task { await performSwap() }
                }
            } message: {
                Text("You'll get a new number in the same area code for \(cost) credits. \(PhoneFormat.national(line.e164)) is given up for good — you can't get it back, and anything still sending codes to it won't reach you.")
            }

            if let to = swappedTo {
                Text("Your new number is \(PhoneFormat.national(to)). Share it wherever you used the old one.")
                    .font(RFont.text(12))
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
    }

    // MARK: - Subscription + second number

    private var manageSection: some View {
        VStack(spacing: 12) {
            // Apple's own sheet, never a custom cancel flow — a bespoke one
            // cannot actually cancel anything and reads as a dark pattern.
            GhostButton(label: "Manage subscription", icon: RIcon.gear) {
                Task { await openManage() }
            }

            // The ONLY route to a second number. The tab shows the store only
            // when there is no line at all, so without this the multi-number
            // product cannot be reached by a user who already has one — which
            // is everyone who would want another.
            Button {
                RHaptic.select()
                // Dismiss FIRST; the presenter opens the store once this sheet
                // is gone. See `onRentAnother`.
                dismiss()
                onRentAnother()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Rent another number")
                        .font(RFont.text(15, weight: .medium))
                }
                .foregroundStyle(theme.ink)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(theme.inkSoft.opacity(0.5), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 16)
    }

    private var emergencySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(label: String(localized: "Important")).padding(.top, 24)
            Card {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.warn)
                        .padding(.top, 1)
                    Text("This number can't call 911 or any other emergency service. Always use your phone's own number for emergencies.")
                        .font(RFont.text(13))
                        .foregroundStyle(theme.text2)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
        }
    }

    // MARK: - Rows

    /// Naming the state rather than always saying "Renews" — a subscription the
    /// user has already cancelled does not renew, and telling them it does is
    /// the kind of thing that turns into a refund request.
    private var renewLabel: String {
        switch line.status {
        case .grace, .pastDue: String(localized: "Payment due")
        case .suspended:       String(localized: "Held until")
        default:               String(localized: "Renews")
        }
    }

    private var renewValue: String {
        let date = line.status == .suspended ? line.holdUntil : line.currentPeriodEnd
        guard let date else { return String(localized: "—") }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    private func row(label: String, value: String) -> some View {
        HStack {
            Text(LocalizedStringKey(label))
                .font(RFont.text(14)).foregroundStyle(theme.text2)
            Spacer()
            Text(value)
                .font(RFont.text(14, weight: .medium))
                .foregroundStyle(theme.text)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var divider: some View {
        Rectangle().fill(theme.sep).frame(height: 0.5).padding(.leading, 16)
    }

    // MARK: - Actions

    @MainActor
    /// Buy a replacement number for this line.
    ///
    /// `swapping` is the re-entrancy guard as well as the button's busy state.
    /// Without it a double-tap sends two requests, and while the server's
    /// in-flight index refuses the second cleanly, the user would see an error
    /// for something that actually worked.
    ///
    /// Reloading the line afterwards is not cosmetic: every other surface —
    /// the header, the share sheet, the thread list — reads `state.lines`, so
    /// skipping it leaves the whole tab showing a number we just gave away.
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

    private func openManage() async {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        else { return }
        try? await AppStore.showManageSubscriptions(in: scene)
    }
}
