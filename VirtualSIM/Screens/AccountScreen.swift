import SwiftUI

struct AccountScreen: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var state
    @Environment(Session.self) private var session
    @Environment(APIClient.self) private var api

    var openCredits: () -> Void

    @State private var showDeleteConfirm = false
    @State private var deleteInProgress = false

    var body: some View {
        @Bindable var state = state
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                title
                profileCard
                balanceCard
                preferences(state: state)
                support
                legal
                dangerZone
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
        guard let date = state.profile?.createdAt else { return "Welcome to vSIM OTP" }
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

    private func openMail() {
        if let url = URL(string: "mailto:\(LegalLinks.supportEmail)?subject=vSIM%20OTP%20support") {
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
