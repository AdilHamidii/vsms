import StoreKit
import SwiftUI

/// The e-mail subscription paywall — raised after the free address is used.
///
/// ── Why it exists ──────────────────────────────────────────────────────
///
/// `begin_email_order` allows one free address per account for life; a
/// second attempt on outlook.com/hotmail.com refuses with
/// `subscription_required`. Before this screen that refusal rendered as an
/// ordinary error banner — a dead end with no way to actually get what the
/// error named. `AppState.confirmGetEmail` now raises `showMailPaywall`
/// instead for exactly that one code (never for `daily_cap_reached`, which
/// means the user is ALREADY subscribed and hit their own daily limit).
///
/// ── The moment it appears ─────────────────────────────────────────────
///
/// Always on the SECOND free-address attempt, never over a delivered code —
/// the user has already seen the product work once for free before being
/// asked to pay. Getting this backwards (asking before the first address, or
/// interrupting a code in flight) is the one mistake this screen must not
/// make.
///
/// ── Honesty rules, each one a bug this repo has already shipped ────────
///
/// - Names the two free domains, states gmail's price plainly, and states the
///   DAILY LIMIT. Never a bare "unlimited e-mails"/"unlimited addresses":
///   gmail is not included, `app_config.email_sub_daily_cap` refuses a
///   subscriber at `MailProduct.dailyAddressCap` a day with
///   `daily_cap_reached` (a message `APIError` already ships, so the app
///   contradicted itself), and free-domain stock genuinely runs dry
///   independently (hotmail.com has shown as few as 2 in stock for a busy
///   service). Promising more than the server delivers is App Store 2.3.1,
///   and this copy becomes the App Store Connect description.
/// - Never names the supplier (owner decision, 2026-07-31 — see CLAUDE.md).
/// - The yearly saving is computed from the LIVE `Product.price` values,
///   never hardcoded — the credit-pack ladder drifted to $4.99-vs-€5.99 on
///   its top product exactly because a price was assumed instead of read.
/// - The trial is on the YEARLY plan only. Saying "3 days free" on monthly
///   would be false, and Apple grants one intro offer per subscription GROUP
///   per Apple ID — an ineligible user must see no trial claim at all.
/// - App Store review 3.1.2(c): the EULA and Privacy links must be
///   link-tinted with their real names, one per line. The 2.0 rejection was
///   exactly a muted "Terms"/"Privacy" pair.
/// - An empty `store.products` almost always means the product is still
///   `MISSING_METADATA` in App Store Connect, not a client bug — say the
///   store is unavailable rather than rendering a live-looking disabled row.
struct MailPaywallScreen: View {
    @Environment(AppState.self) private var state
    @Environment(MailSubscriptionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var appeared = false
    @State private var isRestoring = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "E-mail subscription")

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    intro.riseIn(appeared, index: 0)

                    if !store.hasProducts {
                        unavailable.padding(.top, 24).riseIn(appeared, index: 1)
                    } else {
                        planPicker.padding(.top, 20).riseIn(appeared, index: 1)
                        priceBlock.padding(.top, 12).riseIn(appeared, index: 2)
                    }

                    if let msg = store.lastError {
                        Text(msg)
                            .font(RFont.text(12))
                            .foregroundStyle(theme.fail)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 12)
                    }

                    restore.padding(.top, 14).riseIn(appeared, index: 3)
                    legal.padding(.top, 18).riseIn(appeared, index: 4)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)

            if store.hasProducts {
                BottomBar { cta }
            }
        }
        .background(theme.bg)
        .task {
            withAnimation(RMotion.content) { appeared = true }
            await store.load()
        }
    }

    // MARK: - What this buys

    /// Names the two free domains, states the daily limit, and states gmail's
    /// price. Never a bare "unlimited e-mails" — see the file header.
    ///
    /// This is the ONE place the cap figure is quoted, so a server-side change
    /// to `email_sub_daily_cap` falsifies one sentence rather than five.
    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            MicroLabel("Temporary e-mail")
            Text("Up to \(MailProduct.dailyAddressCap) addresses a day.")
                .displayType(26)
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text("On outlook.com and hotmail.com, subject to availability. Your allowance resets at midnight UTC. Gmail stays a 1-credit purchase either way — it isn't part of the subscription.")
                .font(RFont.text(15))
                .foregroundStyle(theme.text2)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A load failure, or the product is not yet ready for sale in App Store
    /// Connect. Neither is a reason to render a disabled-but-live-looking row.
    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The exact copy `SubscriptionStore`'s paywall already ships, so
            // this reuses its catalog key and all six translations rather
            // than adding a near-duplicate.
            Text("The App Store isn't offering this subscription right now. Please try again in a moment.")
                .font(RFont.text(14, weight: .medium))
                .foregroundStyle(theme.text2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(theme.elev, in: .rect(cornerRadius: RRadius.md))
    }

    // MARK: - Plan choice

    private var planPicker: some View {
        VStack(spacing: 8) {
            ForEach(MailPlan.allCases) { plan in
                planRow(plan)
            }
        }
    }

    /// Reads its price through `store.displayPrice(for:)` rather than off a
    /// `Product`, so the DEBUG screenshot shim can render the row when
    /// `simctl` has loaded no products — see `MailSubscriptionStore
    /// .ScreenshotPricing`.
    @ViewBuilder
    private func planRow(_ plan: MailPlan) -> some View {
        if let price = store.displayPrice(for: plan) {
            let active = store.selectedPlan == plan
            Button {
                RHaptic.select()
                withAnimation(RMotion.select) { store.selectedPlan = plan }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: active ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(active ? theme.ink : theme.text3)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(plan == .monthly ? "Monthly" : "Yearly")
                                .font(RFont.text(15, weight: .semibold))
                                .foregroundStyle(theme.text)
                            if plan == .yearly, let pct = store.yearlySavingsPercent {
                                Text(verbatim: String(localized: "SAVE \(pct)%"))
                                    .font(RFont.text(10, weight: .heavy))
                                    .tracking(0.3)
                                    .foregroundStyle(theme.accent2)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(theme.inkSoft, in: .capsule)
                            }
                        }
                        // The trial is on YEARLY only — see the file header.
                        if plan == .yearly, let trial = store.yearlyTrialLabel {
                            Text("\(trial) free, then billed yearly")
                                .font(RFont.text(12))
                                .foregroundStyle(theme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(verbatim: price)
                        .font(RFont.text(15, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .monospacedDigit()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: RRadius.md, style: .continuous)
                        .fill(active ? theme.inkSoft.opacity(0.5) : theme.elev)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RRadius.md, style: .continuous)
                        .stroke(active ? theme.ink.opacity(0.5) : theme.sep,
                                lineWidth: active ? 1.5 : 1)
                )
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        }
    }

    // MARK: - Price + renewal terms (App Store 3.1.2(a))

    private var priceBlock: some View {
        Card(radius: RRadius.md, elevation: .flat,
             fill: theme.inkSoft.opacity(0.5), border: theme.ink.opacity(0.28)) {
            VStack(alignment: .leading, spacing: 4) {
                if let price = store.displayPrice(for: store.selectedPlan) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(price)
                            .displayType(28)
                            .foregroundStyle(theme.text)
                        Text(store.selectedPlan == .yearly ? "per year" : "per month")
                            .font(RFont.text(15))
                            .foregroundStyle(theme.text2)
                        Spacer(minLength: 0)
                    }
                    // 3.1.2(a): the actual billing period and renewal terms,
                    // and — when a trial applies — what happens when it ends.
                    // The trial sentence matches `LineCheckoutScreen`'s exact
                    // interpolation shape (trial, then price, THEN the renewal
                    // sentence) so it reuses that key's catalog entry and all
                    // six translations rather than adding a near-duplicate.
                    Group {
                        if store.selectedPlan == .yearly, let trial = store.yearlyTrialLabel {
                            Text("\(trial) free, then \(price).  Renews every year until you cancel. Cancel any time in your Apple ID settings.")
                        } else if store.selectedPlan == .yearly {
                            Text("Renews every year until you cancel. Cancel any time in your Apple ID settings.")
                        } else {
                            Text("Renews every month until you cancel. Cancel any time in your Apple ID settings.")
                        }
                    }
                    .font(RFont.text(12))
                    .foregroundStyle(theme.text2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // The yearly saving and the trial label both live on
    // `MailSubscriptionStore` rather than here. They used to be private to
    // this view, which meant the DEBUG screenshot shim could not reach them
    // and a captured frame would have shown a price with no SAVE badge and no
    // trial line — the two things the yearly product's review screenshot has
    // to prove. One definition, one place it can be wrong.

    // MARK: - Action

    private var cta: some View {
        PrimaryButton(label: ctaLabel, disabled: store.isPurchasing, action: buy)
    }

    private var ctaLabel: String {
        if store.isPurchasing { return String(localized: "Confirming…") }
        guard let price = store.displayPrice(for: store.selectedPlan) else {
            return String(localized: "Subscribe")
        }
        // Single-argument interpolations only, deliberately — `priceBlock`
        // just above already states the exact price, period and renewal
        // terms (the 3.1.2(a) disclosure), so the button does not need to
        // repeat them, and a two-argument interpolated sentence risks a
        // hand-seeded catalog key that does not match what Xcode's own
        // extractor would generate (this file's multi-argument keys are
        // NOT consistently positional — verified against the catalog rather
        // than assumed).
        if store.selectedPlan == .yearly, let trial = store.yearlyTrialLabel {
            return String(localized: "Start \(trial) free")
        }
        return String(localized: "Subscribe — \(price)")
    }

    private func buy() {
        Task {
            if await store.purchase() {
                RHaptic.success()
                dismiss()
            }
        }
    }

    // MARK: - Restore + legal

    private var restore: some View {
        Button {
            Task {
                isRestoring = true
                store.lastError = nil
                let ok = await store.restore()
                isRestoring = false
                if ok {
                    RHaptic.success()
                    dismiss()
                } else if store.lastError == nil {
                    store.lastError = String(localized: "Nothing left to restore.")
                }
            }
        } label: {
            Text(isRestoring ? "Restoring…" : "Restore purchases")
                .font(RFont.text(14, weight: .medium))
                .foregroundStyle(theme.text2)
        }
        .pressable(0.94)
        .disabled(isRestoring)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Guideline 3.1.2(c). Full names, link-tinted, one per line — the 2.0
    /// rejection was a bare "Terms"/"Privacy" pair tinted like muted text.
    private var legal: some View {
        VStack(spacing: 6) {
            Link("Terms of Use (EULA)", destination: LegalLinks.eula)
            Link("Privacy Policy", destination: LegalLinks.privacy)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .font(RFont.text(13))
        .tint(theme.ink)
    }
}
