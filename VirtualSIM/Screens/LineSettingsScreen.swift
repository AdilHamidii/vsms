import SwiftUI

/// What is left behind the gear once the Number tab became a codes-first
/// product (owner decision 2026-09-01): switching the number, renting another,
/// and the emergency-calling disclosure App Review looks for.
///
/// 🔴 NO SUBSCRIPTION MANAGEMENT HERE, DELIBERATELY. The plan card (price,
/// renewal date) and the "Manage subscription" button were removed from every
/// Number-tab page on 2026-09-01. The product is "a number that receives your
/// codes; switch it when a platform refuses it" — a screen that leads with
/// what the plan costs and where to cancel it undercuts that on the exact
/// surface a subscriber visits. Apple's manage-subscriptions sheet is still
/// reachable, from the Account screen only (`AccountScreen.support`).
///
/// It was the Number tab's third SEGMENT until 2026-08-27, sitting beside
/// Messages and Calls; it moved behind the gear because a phone app has two
/// surfaces you live in and a settings screen you visit twice a year.
///
/// 🔴 PRESENTED AS A `.sheet`, SO IT MUST BE WRAPPED IN `EnvBundle` AT THE
/// PRESENTATION SITE. Sheet content does not inherit `@Observable` environment
/// objects from its presenter.
struct LineSettingsScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    let line: Line

    /// Called after this sheet has asked to be dismissed. Setting
    /// `state.flow` from inside a sheet presents a `fullScreenCover` on a view
    /// that is on its way out — the presenter must do it once the sheet is
    /// actually gone, which is why this is a callback and not a direct
    /// assignment. See `LiveLineView.pendingRentAnother`.
    var onRentAnother: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: String(localized: "Number settings"))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    numberCard
                    swapSection
                    rentAnotherSection
                    emergencySection
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
        }
        .background(theme.bg)
    }

    // MARK: - Number

    private var numberCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(label: String(localized: "Your number"))
            Card {
                VStack(spacing: 0) {
                    row(label: "Number", value: PhoneFormat.national(line.e164))
                    divider
                    // 🔴 A "Texts left · N of 200" row lived here and is GONE. It
                    // metered an allowance that can no longer be spent (outbound
                    // SMS dropped 2026-08-18), and it must NOT be turned into an
                    // inbound counter: inbound is never metered, so a
                    // received-texts figure would invent a cap this product does
                    // not have.
                    row(label: "Minutes left",
                        value: "\(line.voiceSecondsRemaining / 60) of \(line.voiceAllowanceSeconds / 60)")
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Swap

    /// The same button the live-line screen shows under the number — one
    /// definition of the price, the confirmation and the call.
    private var swapSection: some View {
        LineSwitchNumberButton(line: line, style: .ghost)
            .padding(.top, 16)
    }

    // MARK: - Second number

    private var rentAnotherSection: some View {
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
        .padding(.top, 12)
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
}
