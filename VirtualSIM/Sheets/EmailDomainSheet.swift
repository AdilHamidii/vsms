import SwiftUI

/// Pick the mail domain for a temporary address.
///
/// The email analogue of `CountrySheet`: the service is fixed, the domain
/// varies. Stock is live and per (service, domain) — measured 2026-07-30,
/// hotmail.com had 1,028 available for google.com and TWO for discord.com — so
/// an out-of-stock option is rendered as unbuyable rather than hidden. Hiding it
/// would make the free tier look like it does not exist, when in fact it is
/// simply empty right now.
///
/// ── What the 2026-08 audit found here ────────────────────────────────────
///
/// **"Couldn't check availability. Please try again." had no retry control.**
/// The only instruction on the screen could not be followed: nothing on this
/// sheet re-fetches, and closing it does not either — `loadEmailDomains` is
/// driven from `ContentView`'s service/mode change. So the user's options were
/// to close the sheet and change service and change back. It now offers the
/// retry it names.
///
/// **Loading was a bare `ProgressView`.** A spinner says "something is
/// happening"; skeleton rows say "a list of domains is coming, roughly this
/// shape". The list is 2–4 rows, so the skeleton is nearly free and removes
/// the layout jump when it lands.
///
/// **The detent is `.large` for a list of 2–4 rows** — about 80% empty space
/// over a decision that takes one tap. This view now requests `.medium` first.
/// ⚠️ `ContentView` applies `.presentationDetents([.large])` to every sheet it
/// presents, OUTSIDE this view, and the outer application wins — so this
/// request has no effect until that line stops hard-coding `.large` for the
/// e-mail sheet.
struct EmailDomainSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state
    @Environment(APIClient.self) private var api
    @Environment(MailSubscriptionStore.self) private var mailStore
    var onPick: (EmailDomainOption) -> Void

    @State private var appeared = false
    /// Presented from this sheet rather than through `state.showMailPaywall`:
    /// the root sheet is unreachable while a cover is up, and this keeps the
    /// paywall's presenter next to the control that opens it — the same shape
    /// `EmailCodeScreen` uses.
    @State private var showPaywall = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Choose an email domain")

            if state.isLoadingEmailDomains && state.emailDomains.isEmpty {
                skeleton
            } else if state.emailDomains.isEmpty {
                unavailable
            } else {
                list
            }
        }
        .background(theme.bg)
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $showPaywall) {
            MailPaywallScreen()
                .environment(\.theme, theme)
                .environment(state)
                .environment(mailStore)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(theme.bg)
        }
        .task {
            withAnimation(RMotion.content) { appeared = true }
            // A UI hint, not an authority — `mailStore.isEntitled` only
            // decides which LABEL a free row wears here. `begin_email_order`
            // is still the one place that decides whether the tap succeeds.
            await mailStore.refreshEntitlement()
        }
    }

    // MARK: - States

    /// Three placeholder rows in the shape of the real ones. `.shimmer()` is
    /// what makes a placeholder read as a placeholder rather than as a broken
    /// list — static dimming does not.
    private var skeleton: some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { i in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().fill(theme.chipBg)
                            .frame(width: i == 0 ? 116 : 96, height: 13)
                        Capsule().fill(theme.chipBg)
                            .frame(width: 74, height: 10)
                    }
                    Spacer(minLength: 0)
                    Capsule().fill(theme.chipBg).frame(width: 46, height: 22)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 15)
                if i < 2 { RowRule(inset: 16) }
            }
        }
        .shimmer()
        .background(theme.elev, in: .rect(cornerRadius: RRadius.lg))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .accessibilityLabel(Text("Checking availability"))
    }

    /// Deliberately does NOT assert a cause. `loadEmailDomains` clears the list
    /// both when the fetch fails and when the service genuinely has no mail
    /// domains, and the sheet cannot tell those apart — so it states what it
    /// knows and offers the one action that helps either way.
    private var unavailable: some View {
        EmptyState(
            icon: "envelope.badge.shield.half.filled",
            title: "Couldn't check availability",
            message: "We ask the mail provider for live stock every time, so this needs a connection. Nothing has been charged.",
            tint: theme.fail,
            primary: (label: String(localized: "Try again"), action: reload)
        )
        .frame(maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // What actually differs between these rows, said once. Without
                // it the only visible difference is the price, and a user has
                // no way to know the address behaves identically either way.
                Text("Any domain works the same. The free ones run out most often, so stock is checked live.")
                    .font(RFont.text(12))
                    .foregroundStyle(theme.text2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 12)
                    .riseIn(appeared, index: 0)

                Card(elevation: .raised) {
                    LazyVStack(spacing: 0) {
                        ForEach(state.emailDomains) { option in
                            row(option)
                            if option.id != state.emailDomains.last?.id {
                                RowRule(inset: 16)
                            }
                        }
                    }
                }
                .riseIn(appeared, index: 1)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    /// ⚠️ Two shapes, and the split is structural rather than cosmetic. A free
    /// domain for someone whose lifetime free address is spent carries a
    /// tappable **Subscribe** chip, and a Button cannot live inside another
    /// Button's label in SwiftUI — the inner one simply never receives the
    /// tap. So that case renders the identity and the chip as SIBLINGS: the
    /// left half still picks the domain, the chip opens the paywall.
    @ViewBuilder
    private func row(_ option: EmailDomainOption) -> some View {
        if option.isFree, freeAccess == .subscription {
            HStack(spacing: 12) {
                Button {
                    RHaptic.select()
                    onPick(option)
                    dismiss()
                } label: {
                    HStack(spacing: 0) {
                        rowIdentity(option)
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .pressable(0.985)
                .disabled(!option.inStock)

                priceTag(option)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        } else {
            Button {
                RHaptic.select()
                onPick(option)
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    rowIdentity(option)
                    Spacer(minLength: 0)
                    priceTag(option)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .contentShape(.rect)
            }
            .pressable(0.985)
            .disabled(!option.inStock)
        }
    }

    private func rowIdentity(_ option: EmailDomainOption) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // verbatim: a mail domain is a brand, not a translatable
            // string, and "gmail.com" must never become "Google Mail".
            Text(verbatim: option.displayName)
                .font(RFont.display(16, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(option.inStock ? theme.text : theme.text2)
            if option.inStock {
                StatusPill(text: "Available now")
            } else {
                StatusPill(text: "Out of stock right now",
                           tint: theme.text3, soft: theme.chipBg, dot: false)
            }
        }
    }

    /// A bare "Free" implied a daily allowance that no longer exists — one
    /// free address per account for LIFE, then a subscription. This says which
    /// of the three states actually applies: already subscribed, the one free
    /// address still unused, or spent and now behind the paywall. Gmail is
    /// untouched — it was never part of either the old allowance or the new
    /// subscription.
    /// Takes no argument on purpose: it is only ever rendered for a FREE
    /// domain (`priceTag` calls it inside `if option.isFree`), and what it
    /// says depends solely on the account — whether the user is subscribed
    /// and whether they have spent their one free address. It used to accept
    /// an `EmailDomainOption` and ignore it, which read as a per-domain label.
    private var entitlementLabel: LocalizedStringKey { freeAccess.label }

    private var freeAccess: FreeEmailAccess {
        FreeEmailAccess.resolve(isEntitled: mailStore.isEntitled,
                                hasUsedFree: state.hasUsedFreeEmail)
    }

    @ViewBuilder
    private func priceTag(_ option: EmailDomainOption) -> some View {
        if option.isFree, freeAccess == .subscription {
            // 🔴 A CHIP, NOT A NOUN, AND IT IS THE ONLY REASON THIS ROW IS
            // SPLIT IN TWO. "Subscription" named a state and offered no way
            // out of it: tapping the row bought nothing and came back
            // `subscription_required`. It cannot live inside the row's own
            // Button — SwiftUI does not deliver taps to a control nested in
            // another Button's label — which is why `row(_:)` renders this
            // case as two sibling buttons instead.
            ChipButton(label: String(localized: "Subscribe"),
                       active: true, soft: true) {
                state.intent = .mailSubscription
                showPaywall = true
            }
        } else if option.isFree {
            Text(entitlementLabel)
                .font(RFont.display(15, weight: .semibold))
                .foregroundStyle(option.inStock ? theme.text : theme.text3)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(option.credits)")
                    .font(RFont.display(15, weight: .semibold))
                    .foregroundStyle(option.inStock ? theme.text : theme.text3)
                    .monospacedDigit()
                Text("cr")
                    .font(RFont.text(12, weight: .medium))
                    .foregroundStyle(theme.text2)
            }
        }
    }

    private func reload() {
        RHaptic.select()
        Task { await state.loadEmailDomains(using: EmailAPI(client: api)) }
    }
}
