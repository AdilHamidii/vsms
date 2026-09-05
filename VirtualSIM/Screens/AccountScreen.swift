import StoreKit
import SwiftUI

/// Settings, the wallet, the invite loop and the two destructive actions.
///
/// ── What the 2026-08 audit found here ────────────────────────────────────
///
/// **Success and failure looked identical.** `redeemMsg` rendered "Invite code
/// applied 🎉 you got 2 free credits" and "That code isn't valid." in the same
/// 12pt `theme.text3` — the faintest ink in the palette — with no icon. The one
/// place in the app where a user hands us a code and waits for a verdict
/// answered both verdicts the same way. Verdicts now carry colour and an icon.
///
/// **"Nothing to restore" never went away.** The restore result was parked in
/// the row's trailing edge, where it had no room and, more importantly, no
/// clearing path: it sat there for the rest of the session. It is a `detail`
/// line now, it distinguishes "restored" from "nothing to restore", and it
/// expires.
///
/// **A LOADING profile was rendered as content.** `memberSinceLine` returned
/// "Welcome to vSMS" whenever `profile` was nil — which is also what a slow or
/// failed fetch looks like, so a returning user on a bad connection was
/// greeted as brand new. Loading, loaded and failed are now three states.
///
/// **The referral code rendered "—" with the button disabled** and no
/// explanation of why. It now says which of the two reasons applies and offers
/// the retry.
///
/// **The danger-zone explanation was `theme.text3`** — sub-AA contrast on the
/// sentence explaining that an account deletion cannot be undone.
///
/// The two motion preferences SURVIVE, deliberately. `WaitingAnimationView`
/// was rebuilt so the RING carries progress and the preference only chooses how
/// the ambient core moves — but it does still choose that, visibly, for the
/// whole of a wait, and `OtpAnimation` still drives the code's reveal. They are
/// the same category as the accent swatch: taste the user can set, that cannot
/// misstate anything. What is NOT configurable is the information layer, and
/// that separation is the point.
struct AccountScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(Session.self) private var session
    @Environment(APIClient.self) private var api
    @Environment(IAPStore.self) private var iap

    var openCredits: () -> Void

    @State private var showChangePassword = false
    @State private var showDeleteConfirm = false
    @State private var deleteInProgress = false

    @State private var inviteCode = ""
    @State private var redeeming = false
    @State private var redeemNote: Note?
    @State private var codeCopied = false
    @State private var restoreNote: Note?
    @State private var restoreTask: Task<Void, Never>?

    /// Whether the profile fetch has completed at least once this session.
    /// Without it, "nil profile" cannot be told apart from "still loading" —
    /// which is exactly how a slow fetch got rendered as a welcome message.
    @State private var profileChecked = false

    /// A result the user is waiting for. `ok` is what stops a failure and a
    /// success rendering identically.
    private struct Note: Equatable {
        let text: String
        let ok: Bool
    }

    var body: some View {
        @Bindable var state = state
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                title
                profileCard
                balanceCard
                invite
                preferences(state: state)
                support
                legal
                dangerZone
                credit
            }
            .padding(.top, 8)
            .padding(.bottom, 140)
        }
        .scrollIndicators(.hidden)
        .task {
            // The cold-start chain fetches this, but a tab opened after a
            // failed launch fetch would otherwise sit on a placeholder
            // forever. Cheap, and it makes `profileChecked` meaningful.
            if state.profile == nil {
                await state.refreshProfile(using: ProfileAPI(client: api))
            }
            profileChecked = true
        }
        .onDisappear { restoreTask?.cancel() }
        // A sheet rather than a `FlowStage`: changing a password is a settings
        // errand, not one of the app's product flows, and it has no business
        // in the enum that drives the full-screen cover.
        .sheet(isPresented: $showChangePassword) {
            ChangePasswordScreen()
                .environment(\.theme, theme)
                .environment(api)
                .environment(session)
        }
        .confirmationDialog("Delete your account?",
                            isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("Delete account", role: .destructive) {
                Task { await deleteAccount() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently deletes your account, balance, and order history. Pending orders are auto-canceled. This can't be undone.")
        }
    }

    private var title: some View {
        Text("Account")
            .displayType(28)
            .foregroundStyle(theme.text)
            .padding(.horizontal, 20)
            .padding(.top, 6)
    }

    // MARK: - Profile

    private var profileCard: some View {
        Card {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(theme.chipBg).frame(width: 52, height: 52)
                    Text(verbatim: avatarLetter)
                        .font(RFont.display(20, weight: .semibold))
                        .foregroundStyle(theme.text)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: headlineName)
                        .font(RFont.display(17, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    profileSubtitle
                }
                Spacer(minLength: 0)
            }
            .padding(18)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
    }

    private var headlineName: String {
        if let name = state.profile?.displayName, !name.isEmpty { return name }
        return session.email ?? String(localized: "Signed in")
    }

    private var avatarLetter: String {
        let source = state.profile?.displayName?.isEmpty == false
            ? state.profile!.displayName!
            : (session.email ?? "U")
        return source.first.map { String($0).uppercased() } ?? "U"
    }

    /// Three states, never two.
    ///
    /// ⚠️ Do not restore "Welcome to vSMS" as the nil fallback. `profile` is nil
    /// while the fetch is in flight AND after it fails, so that string greeted
    /// returning users as new and made a network failure invisible.
    @ViewBuilder
    private var profileSubtitle: some View {
        if let date = state.profile?.createdAt {
            // `.formatted` rather than a fixed "MMMM yyyy" DateFormatter: the
            // month name and the month/year order are both locale-dependent.
            Text("Member since \(date.formatted(.dateTime.month(.wide).year()))")
                .font(RFont.text(13))
                .foregroundStyle(theme.text2)
        } else if profileChecked {
            Text("Couldn't load your account details")
                .font(RFont.text(13))
                .foregroundStyle(theme.warn)
        } else {
            Capsule()
                .fill(theme.chipBg)
                .frame(width: 130, height: 11)
                .shimmer()
                .accessibilityLabel(Text("Loading your account"))
        }
    }

    private var balanceCard: some View {
        Card(elevation: .lifted) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        MicroLabel("Balance")
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            MonoText("\(state.balance)", size: 36, weight: .medium, color: theme.text)
                            Text("credits")
                                .font(RFont.text(14))
                                .foregroundStyle(theme.text2)
                        }
                    }
                    Spacer()
                    Button {
                        RHaptic.select()
                        openCredits()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: RIcon.plus)
                                .font(.system(size: 13, weight: .bold))
                            Text("Top up")
                                .font(RFont.display(14, weight: .semibold))
                                .tracking(-0.2)
                        }
                        .foregroundStyle(theme.onInk)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(theme.ink, in: .rect(cornerRadius: RRadius.sm))
                        .contentShape(.rect(cornerRadius: RRadius.sm))
                    }
                    .pressable(0.96)
                }

                Rectangle().fill(theme.sep).frame(height: 0.5)
                    .padding(.top, 16)

                HStack {
                    Metric(label: "Orders", value: "\(state.orders.count)")
                    Spacer()
                    Metric(label: String(localized: "Delivered"), value: "\(state.deliveredCount)", accent: theme.live)
                    Spacer()
                    Color.clear
                }
                .padding(.top, 14)
            }
            .padding(18)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    // MARK: - Invite

    private var invite: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(label: String(localized: "Invite friends"))
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Share your code. A friend who joins with it starts with **\(AppState.inviteJoinerCredits) free credits**, and you get **5 credits** when they buy their first pack.")
                        .font(RFont.text(14))
                        .lineSpacing(2)
                        .foregroundStyle(theme.text2)
                        .fixedSize(horizontal: false, vertical: true)

                    codeBlock

                    if state.profile?.referredBy == nil {
                        Rectangle().fill(theme.sep).frame(height: 0.5)
                        HStack(spacing: 8) {
                            TextField("Have an invite code?", text: $inviteCode)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .font(RFont.mono(15))
                                .foregroundStyle(theme.text)
                                .padding(.horizontal, 12)
                                .frame(height: 42)
                                .background(theme.chipBg, in: .rect(cornerRadius: RRadius.xs))

                            Button {
                                RHaptic.select()
                                Task { await redeemCode() }
                            } label: {
                                Group {
                                    if redeeming {
                                        ProgressView().controlSize(.small).tint(theme.text2)
                                    } else {
                                        Text("Redeem")
                                            .font(RFont.display(14, weight: .semibold))
                                            .foregroundStyle(canRedeem ? theme.text : theme.text3)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .frame(height: 42)
                                .background(theme.chipBg, in: .rect(cornerRadius: RRadius.xs))
                                .contentShape(.rect(cornerRadius: RRadius.xs))
                            }
                            .pressable(0.96)
                            .disabled(!canRedeem)
                        }
                        if let note = redeemNote { noteLine(note) }
                    }
                }
                .padding(18)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
    }

    /// The code, or the reason there isn't one.
    ///
    /// It used to render a bare "—" with a disabled copy button and no
    /// explanation, which reads as a broken screen. There are exactly two
    /// reasons it can be missing and they need different answers.
    @ViewBuilder
    private var codeBlock: some View {
        if let code = state.profile?.referralCode {
            HStack(spacing: 10) {
                Button(action: copyCode) {
                    HStack(spacing: 8) {
                        Text(verbatim: code)
                            .font(RFont.mono(18, weight: .semibold))
                            .foregroundStyle(theme.text)
                        Spacer(minLength: 0)
                        Image(systemName: codeCopied ? RIcon.check : RIcon.copy)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(codeCopied ? theme.live : theme.text2)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .frame(maxWidth: .infinity)
                    .background(theme.chipBg, in: .rect(cornerRadius: RRadius.sm))
                    .contentShape(.rect(cornerRadius: RRadius.sm))
                }
                .pressable(0.98)

                if let invite = state.inviteMessage {
                    ShareLink(item: invite) {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Share")
                                .font(RFont.display(14, weight: .semibold))
                                .tracking(-0.2)
                        }
                        .foregroundStyle(theme.onInk)
                        .padding(.horizontal, 16)
                        .frame(height: 46)
                        .background(theme.ink, in: .rect(cornerRadius: RRadius.sm))
                    }
                }
            }
        } else if !profileChecked {
            Capsule()
                .fill(theme.chipBg)
                .frame(height: 46)
                .shimmer()
                .accessibilityLabel(Text("Loading your invite code"))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("We couldn't load your invite code. Your credits and orders aren't affected.")
                    .font(RFont.text(13))
                    .foregroundStyle(theme.text2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                GhostButton(label: String(localized: "Try again"),
                            icon: RIcon.refresh,
                            fillsWidth: false) {
                    RHaptic.select()
                    Task { await state.refreshProfile(using: ProfileAPI(client: api)) }
                }
            }
        }
    }

    private var canRedeem: Bool {
        !redeeming && inviteCode.trimmingCharacters(in: .whitespaces).count >= 4
    }

    /// A verdict, with its outcome legible at a glance. Success is `live`,
    /// failure is `fail`, and neither is `text3`.
    private func noteLine(_ note: Note) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: note.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(note.ok ? theme.live : theme.fail)
                .padding(.top, 1)
            Text(verbatim: note.text)
                .font(RFont.text(13, weight: .medium))
                .foregroundStyle(theme.text)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(note.ok ? theme.liveSoft : theme.failSoft,
                    in: .rect(cornerRadius: RRadius.sm))
    }

    // MARK: - Preferences

    /// Direct swatches rather than a Menu: for colour, showing the options is
    /// the whole point, and each is rendered in the exact tone it will take on
    /// the current light/dark surface.
    private func accentSwatches(state: AppState) -> some View {
        HStack(spacing: 7) {
            ForEach(AccentColor.allCases) { option in
                let isOn = state.accent == option
                Button {
                    RHaptic.select()
                    withAnimation(RMotion.select) { state.accent = option }
                } label: {
                    Circle()
                        .fill(option.swatch(isDark: theme.isDark))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle()
                                .stroke(theme.text, lineWidth: isOn ? 2 : 0)
                                .padding(-3)
                        )
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
        .padding(.trailing, 2)
    }

    /// System / Light / Dark as three visible segments, for the same reason the
    /// accent uses swatches: the options should be on screen, not behind a menu.
    ///
    /// It replaces a Bool toggle, which could not express "follow my device" —
    /// and defaulted to off, so every dark-mode user got a light app until they
    /// came here and found it.
    private func appearancePicker(state: AppState) -> some View {
        HStack(spacing: 2) {
            ForEach(AppearanceMode.allCases) { option in
                let isOn = state.appearance == option
                Button {
                    RHaptic.select()
                    withAnimation(RMotion.select) { state.appearance = option }
                } label: {
                    Image(systemName: icon(for: option))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isOn ? theme.onInk : theme.text2)
                        .frame(width: 34, height: 26)
                        .background(isOn ? theme.ink : .clear, in: .rect(cornerRadius: 8))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(theme.chipBg, in: .rect(cornerRadius: RRadius.xs))
    }

    private func icon(for mode: AppearanceMode) -> String {
        switch mode {
        case .system: "circle.lefthalf.filled"
        case .light:  "sun.max.fill"
        case .dark:   "moon.fill"
        }
    }

    private func preferences(state: AppState) -> some View {
        @Bindable var state = state
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader(label: "Preferences")
            Card {
                VStack(spacing: 0) {
                    SettingRow(
                        label: "Appearance",
                        icon: "moon.fill",
                        trailing: { appearancePicker(state: state) }
                    )
                    SettingRow(
                        label: "Accent",
                        icon: "paintpalette.fill",
                        trailing: { accentSwatches(state: state) }
                    )
                    SettingRow(
                        label: "Show success metrics",
                        icon: "chart.bar",
                        trailing: {
                            Toggle("", isOn: $state.showMetrics)
                                .labelsHidden().tint(theme.ink)
                        }
                    )
                    SettingRow(
                        label: "Default country",
                        icon: RIcon.globe,
                        trailing: {
                            Menu {
                                ForEach(state.countries) { country in
                                    Button {
                                        RHaptic.select()
                                        state.lastCountry = country
                                    } label: {
                                        Text(verbatim: "\(country.flag)  \(country.name)")
                                    }
                                }
                            } label: {
                                MenuValueLabel(text: LocalizedStringKey(state.lastCountry.name),
                                               leading: state.lastCountry.flag)
                            }
                        }
                    )
                    // Ambient motion only — the waiting RING's progress and the
                    // code itself are not configurable. See the type comment.
                    SettingRow(
                        label: "Waiting animation",
                        icon: RIcon.spark,
                        trailing: {
                            Menu {
                                ForEach(WaitingAnimation.allCases, id: \.self) { kind in
                                    Button {
                                        RHaptic.select()
                                        state.waitingAnimation = kind
                                    } label: {
                                        Text(LocalizedStringKey(kind.displayName))
                                    }
                                }
                            } label: {
                                MenuValueLabel(
                                    text: LocalizedStringKey(state.waitingAnimation.displayName))
                            }
                        }
                    )
                    SettingRow(
                        label: "Code reveal",
                        icon: RIcon.bolt,
                        trailing: {
                            Menu {
                                ForEach(OtpAnimation.allCases, id: \.self) { kind in
                                    Button {
                                        RHaptic.select()
                                        state.otpAnimation = kind
                                    } label: {
                                        Text(LocalizedStringKey(kind.displayName))
                                    }
                                }
                            } label: {
                                MenuValueLabel(
                                    text: LocalizedStringKey(state.otpAnimation.displayName))
                            }
                        }
                    )
                    SettingRow(label: "Auto-refund",
                               icon: RIcon.shield,
                               trailingText: "8 min",
                               isLast: true)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
    }

    // MARK: - Support

    private var support: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(label: "Support")
            Card {
                VStack(spacing: 0) {
                    // First, above the help centre. A static FAQ cannot answer
                    // "is my code coming?", which is the question people
                    // actually have, and it is asked at the exact moment they
                    // are about to cancel a working order.
                    //
                    // WhatsApp since 2.9 (owner decision 2026-09-05). The
                    // in-app chat relayed to Telegram and sat unanswered; a
                    // `wa.me` link lands in the inbox the owner actually
                    // reads. The prefilled text carries the build and a short
                    // account id — see `LegalLinks.supportWhatsApp`.
                    SettingRow(label: "Message us on WhatsApp", icon: "message.fill",
                               onTap: { open(LegalLinks.supportWhatsApp(userId: session.userId)) })
                    SettingRow(label: "Help center", icon: "questionmark.circle",
                               onTap: { open(LegalLinks.help) })
                    // A user-triggerable recovery for a purchase whose
                    // verification failed. It also lives in `CreditsSheet`,
                    // where the person who was charged is actually standing.
                    SettingRow(label: "Restore purchases",
                               icon: RIcon.refresh,
                               detail: restoreDetail,
                               detailTint: restoreTint,
                               onTap: restore)
                    SettingRow(label: "Contact support", icon: "envelope",
                               onTap: { openMail() })
                    // The ONLY route to Apple's manage-subscriptions sheet
                    // since 2026-09-01: every plan/renewal/cancel affordance
                    // came off the Number tab (owner decision — that tab is
                    // about receiving codes). Apple's own sheet, never a
                    // custom cancel flow, which cannot cancel anything and
                    // reads as a dark pattern.
                    SettingRow(label: "Manage subscriptions", icon: "creditcard",
                               onTap: { Task { await openManageSubscriptions() } })
                    // Only an email account HAS a password. An Apple account
                    // does not, and offering the row would open a screen whose
                    // every outcome is an error.
                    if session.isEmailUser {
                        SettingRow(label: "Change password", icon: "lock",
                                   onTap: { showChangePassword = true })
                    }
                    SettingRow(label: "Sign out", isLast: true, isDanger: true,
                               onTap: { Task { await session.signOut() } })
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
    }

    /// In-progress, then the result, then nothing. The label itself stays
    /// constant so the row does not change identity mid-tap.
    private var restoreDetail: LocalizedStringKey? {
        if iap.isRestoring { return "Checking your purchases…" }
        // Already localized at the source, so the lookup misses and it renders
        // verbatim — the same contract `TrailingText` and `ReceiptValue` use.
        if let note = restoreNote { return LocalizedStringKey(note.text) }
        return nil
    }

    private var restoreTint: Color? {
        guard let note = restoreNote, !iap.isRestoring else { return nil }
        // "Nothing left to restore" is not a failure, so it stays neutral —
        // only a real recovery gets the success colour.
        return note.ok ? theme.live : theme.text2
    }

    private var legal: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(label: "Legal")
            Card {
                VStack(spacing: 0) {
                    SettingRow(label: "Terms of use", icon: "doc.text",
                               onTap: { open(LegalLinks.terms) })
                    SettingRow(label: "Privacy policy", icon: "hand.raised",
                               onTap: { open(LegalLinks.privacy) })
                    SettingRow(label: "Refund policy", icon: RIcon.shield, isLast: true,
                               onTap: { open(LegalLinks.refund) })
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
    }

    private var credit: some View {
        Text(verbatim: "Developed by Adil Hamidi")
            .font(RFont.text(11))
            .foregroundStyle(theme.text3)
            .opacity(0.7)
            .frame(maxWidth: .infinity)
            .padding(.top, 32)
            .padding(.bottom, 16)
    }

    private var dangerZone: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(label: "Danger zone")
            Card {
                if deleteInProgress {
                    SettingRow(label: "Deleting…",
                               icon: RIcon.trash,
                               isLast: true,
                               isDanger: true)
                } else {
                    SettingRow(label: "Delete account",
                               icon: RIcon.trash,
                               isLast: true,
                               isDanger: true,
                               onTap: { showDeleteConfirm = true })
                }
            }
            // `text2`, not `text3`. This sentence explains an irreversible
            // action; the faintest ink in the palette is sub-AA and is the
            // wrong place to economise.
            Text("Permanently removes your account, balance, and order history. This can't be undone.")
                .font(RFont.text(13))
                .foregroundStyle(theme.text2)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
                .padding(.top, 10)
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
    }

    // MARK: - Actions

    private func open(_ url: URL) {
        UIApplication.shared.open(url)
    }

    private func copyCode() {
        guard let code = state.profile?.referralCode else { return }
        UIPasteboard.general.string = code
        RHaptic.copied()
        withAnimation(RMotion.content) { codeCopied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation(RMotion.content) { codeCopied = false }
        }
    }

    /// Restores, reports, and CLEARS. The result used to be parked in the
    /// row's trailing edge with nothing to remove it, so "Nothing to restore"
    /// stayed there for the rest of the session.
    private func restore() {
        guard !iap.isRestoring else { return }
        restoreTask?.cancel()
        restoreTask = Task {
            let n = await iap.restorePurchases()
            await state.refreshWallet(using: WalletAPI(client: api))
            guard !Task.isCancelled else { return }
            // Complete sentences per plural: a stitched "s" cannot be
            // translated into the Romance languages.
            let text: String
            if n == 0 {
                text = String(localized: "Nothing left to restore.")
            } else if n == 1 {
                text = String(localized: "1 purchase restored. Your credits are back.")
            } else {
                text = String(localized: "\(n) purchases restored. Your credits are back.")
            }
            withAnimation(RMotion.content) {
                restoreNote = Note(text: text, ok: n > 0)
            }
            if n > 0 { RHaptic.success() }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(RMotion.content) { restoreNote = nil }
        }
    }

    private func redeemCode() async {
        let code = inviteCode.trimmingCharacters(in: .whitespaces)
        guard code.count >= 4 else { return }
        redeeming = true
        defer { redeeming = false }
        do {
            let status = try await ProfileAPI(client: api).redeemReferral(code: code)
            switch status {
            case "ok":
                RHaptic.success()
                // Interpolated, not literal. `inviteJoinerCredits` exists
                // precisely so this figure lives in one place — it was already
                // a 150% overstatement once, when it was summed with a signup
                // grant that later went to zero. This was the last surface
                // still hardcoding it.
                redeemNote = Note(
                    text: String(localized: "Invite code applied. You got \(AppState.inviteJoinerCredits) free credits. Your friend earns \(AppState.inviteReferrerCredits) more when you buy your first pack."),
                    ok: true)
                inviteCode = ""
                await state.refreshProfile(using: ProfileAPI(client: api))
                await state.refreshWallet(using: WalletAPI(client: api))
            case "already_referred":
                RHaptic.warn()
                redeemNote = Note(text: String(localized: "You've already used an invite code."), ok: false)
            case "self":
                RHaptic.warn()
                redeemNote = Note(text: String(localized: "You can't use your own code."), ok: false)
            default: // invalid_code
                RHaptic.warn()
                redeemNote = Note(text: String(localized: "That code isn't valid."), ok: false)
            }
        } catch {
            RHaptic.warn()
            redeemNote = Note(text: String(localized: "Couldn't apply that code. Please try again."), ok: false)
        }
    }

    private func openMail() {
        if let url = URL(string: "mailto:\(LegalLinks.supportEmail)?subject=vSMS%20support") {
            UIApplication.shared.open(url)
        }
    }

    /// Apple's sheet for every subscription this Apple ID holds (line and
    /// mail groups alike). Moved here from `LineSettingsScreen` on 2026-09-01.
    private func openManageSubscriptions() async {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        else { return }
        try? await AppStore.showManageSubscriptions(in: scene)
    }

    private func deleteAccount() async {
        deleteInProgress = true
        defer { deleteInProgress = false }
        do {
            try await AccountAPI(client: api).deleteAccount()
            await session.signOut(remote: false)
        } catch let apiErr as APIError {
            state.showError(apiErr)
        } catch {
            state.lastError = String(localized: "We couldn't delete your account. Please try again.")
        }
    }
}
