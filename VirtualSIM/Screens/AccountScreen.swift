import SwiftUI

struct AccountScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(Session.self) private var session
    @Environment(APIClient.self) private var api

    var openCredits: () -> Void

    @State private var showDeleteConfirm = false
    @State private var deleteInProgress = false

    @State private var inviteCode = ""
    @State private var redeeming = false
    @State private var redeemMsg: String?
    @State private var codeCopied = false

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
            .font(RFont.display(28, weight: .bold))
            .tracking(-0.7)
            .foregroundStyle(theme.text)
            .padding(.horizontal, 20)
            .padding(.top, 6)
    }

    private var profileCard: some View {
        Card {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(theme.chipBg).frame(width: 52, height: 52)
                    Text(avatarLetter)
                        .font(RFont.display(20, weight: .semibold))
                        .foregroundStyle(theme.text)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(headlineName)
                        .font(RFont.display(17, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(memberSinceLine)
                        .font(RFont.text(13))
                        .foregroundStyle(theme.text2)
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
        return session.email ?? "Signed in"
    }

    private var avatarLetter: String {
        let source = state.profile?.displayName?.isEmpty == false
            ? state.profile!.displayName!
            : (session.email ?? "U")
        return source.first.map { String($0).uppercased() } ?? "U"
    }

    private var memberSinceLine: String {
        guard let date = state.profile?.createdAt else { return "Welcome to vSMS" }
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return "Member since \(f.string(from: date))"
    }

    private var balanceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("BALANCE")
                            .font(RFont.text(12, weight: .medium))
                            .tracking(0.2)
                            .foregroundStyle(theme.text2)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            MonoText("\(state.balance)", size: 36, weight: .medium, color: theme.text)
                            Text("credits")
                                .font(RFont.text(14))
                                .foregroundStyle(theme.text2)
                        }
                    }
                    Spacer()
                    Button(action: openCredits) {
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
                        .background(theme.ink, in: .rect(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }

                Rectangle().fill(theme.sep).frame(height: 0.5)
                    .padding(.top, 16)

                HStack {
                    Metric(label: "Orders", value: "\(state.orders.count)")
                    Spacer()
                    Metric(label: "Delivered", value: "\(state.deliveredCount)", accent: theme.live)
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

    private var invite: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(label: "Invite friends")
                .padding(.horizontal, 4)
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Share your code. A friend who joins with it gets **2 free credits** — and you get **5 credits** when they buy their first pack.")
                        .font(RFont.text(14))
                        .lineSpacing(2)
                        .foregroundStyle(theme.text2)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Button(action: copyCode) {
                            HStack(spacing: 8) {
                                Text(state.profile?.referralCode ?? "—")
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
                            .background(theme.chipBg, in: .rect(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .disabled(state.profile?.referralCode == nil)

                        if let code = state.profile?.referralCode {
                            ShareLink(item: inviteMessage(code)) {
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
                                .background(theme.ink, in: .rect(cornerRadius: 12))
                            }
                        }
                    }

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
                                .background(theme.chipBg, in: .rect(cornerRadius: 10))

                            Button {
                                Task { await redeemCode() }
                            } label: {
                                Text(redeeming ? "…" : "Redeem")
                                    .font(RFont.display(14, weight: .semibold))
                                    .foregroundStyle(canRedeem ? theme.text : theme.text3)
                                    .padding(.horizontal, 16)
                                    .frame(height: 42)
                                    .background(theme.chipBg, in: .rect(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .disabled(!canRedeem)
                        }
                        if let redeemMsg {
                            Text(redeemMsg)
                                .font(RFont.text(12))
                                .foregroundStyle(theme.text3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(18)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
    }

    private var canRedeem: Bool {
        !redeeming && inviteCode.trimmingCharacters(in: .whitespaces).count >= 4
    }

    /// Direct swatches rather than a Menu: for colour, showing the options is
    /// the whole point, and each is rendered in the exact tone it will take on
    /// the current light/dark surface.
    private func accentSwatches(state: AppState) -> some View {
        HStack(spacing: 7) {
            ForEach(AccentColor.allCases) { option in
                let isOn = state.accent == option
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { state.accent = option }
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

    private func preferences(state: AppState) -> some View {
        @Bindable var state = state
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader(label: "Preferences")
                .padding(.horizontal, 4)
            Card {
                VStack(spacing: 0) {
                    SettingRow(
                        label: "Appearance",
                        icon: "moon.fill",
                        trailing: {
                            Toggle("", isOn: $state.isDark)
                                .labelsHidden().tint(theme.ink)
                        }
                    )
                    SettingRow(
                        label: "Accent",
                        icon: "paintpalette.fill",
                        trailing: { accentSwatches(state: state) }
                    )
                    SettingRow(
                        label: "Waiting animation",
                        icon: RIcon.spark,
                        trailing: {
                            Menu {
                                ForEach(WaitingAnimation.allCases, id: \.self) { kind in
                                    Button(kind.displayName) { state.waitingAnimation = kind }
                                }
                            } label: {
                                Text(state.waitingAnimation.displayName)
                                    .font(RFont.text(14))
                                    .foregroundStyle(theme.text2)
                            }
                        }
                    )
                    SettingRow(
                        label: "OTP reveal",
                        icon: RIcon.bolt,
                        trailing: {
                            Menu {
                                ForEach(OtpAnimation.allCases, id: \.self) { kind in
                                    Button(kind.displayName) { state.otpAnimation = kind }
                                }
                            } label: {
                                Text(state.otpAnimation.displayName)
                                    .font(RFont.text(14))
                                    .foregroundStyle(theme.text2)
                            }
                        }
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
                                        state.lastCountry = country
                                    } label: {
                                        Text("\(country.flag)  \(country.name)")
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(state.lastCountry.flag).font(.system(size: 14))
                                    Text(state.lastCountry.name)
                                        .font(RFont.text(14))
                                        .foregroundStyle(theme.text2)
                                }
                            }
                        }
                    )
                    SettingRow(label: "Auto-refund",
                               icon: RIcon.shield,
                               trailingText: "20 min",
                               isLast: true)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
    }

    private var support: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(label: "Support")
                .padding(.horizontal, 4)
            Card {
                VStack(spacing: 0) {
                    SettingRow(label: "Help center", icon: "questionmark.circle",
                               onTap: { open(LegalLinks.help) })
                    SettingRow(label: "Contact support", icon: "envelope",
                               onTap: { openMail() })
                    SettingRow(label: "Sign out", isLast: true, isDanger: true,
                               onTap: { Task { await session.signOut() } })
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
    }

    private var legal: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(label: "Legal")
                .padding(.horizontal, 4)
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
        Text("Developed by Adil Hamidi")
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
                .padding(.horizontal, 4)
            Card {
                SettingRow(label: deleteInProgress ? "Deleting…" : "Delete account",
                           icon: RIcon.trash,
                           isLast: true,
                           isDanger: true,
                           onTap: { showDeleteConfirm = true })
            }
            Text("Permanently removes your account, balance, and order history.")
                .font(RFont.text(12))
                .foregroundStyle(theme.text3)
                .padding(.horizontal, 18)
                .padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
    }

    // MARK: - Actions

    private func open(_ url: URL) {
        UIApplication.shared.open(url)
    }

    private func inviteMessage(_ code: String) -> String {
        String(localized: "Get a private temporary number for verification codes on vSMS — my invite code \(code) gives you 2 free credits: https://apps.apple.com/app/id6774768570")
    }

    private func copyCode() {
        guard let code = state.profile?.referralCode else { return }
        UIPasteboard.general.string = code
        codeCopied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            codeCopied = false
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
                redeemMsg = String(localized: "Invite code applied 🎉 You got 2 free credits — your friend earns 5 more when you buy your first pack.")
                inviteCode = ""
                await state.refreshProfile(using: ProfileAPI(client: api))
                await state.refreshWallet(using: WalletAPI(client: api))
            case "already_referred":
                redeemMsg = String(localized: "You've already used an invite code.")
            case "self":
                redeemMsg = String(localized: "You can't use your own code.")
            default: // invalid_code
                redeemMsg = String(localized: "That code isn't valid.")
            }
        } catch {
            redeemMsg = String(localized: "Couldn't apply that code. Please try again.")
        }
    }

    private func openMail() {
        if let url = URL(string: "mailto:\(LegalLinks.supportEmail)?subject=vSMS%20support") {
            UIApplication.shared.open(url)
        }
    }

    private func deleteAccount() async {
        deleteInProgress = true
        defer { deleteInProgress = false }
        do {
            try await AccountAPI(client: api).deleteAccount()
            await session.signOut(remote: false)
        } catch let apiErr as APIError {
            state.lastError = apiErr.userMessage
        } catch {
            state.lastError = "We couldn't delete your account. Please try again."
        }
    }
}
