import SwiftUI

/// Change the password on an email account.
///
/// Reached only from Account, and only when `session.isEmailUser` — an Apple
/// account has no password, so the row is not offered there at all.
///
/// ⚠️ THE CURRENT PASSWORD IS ALWAYS SENT, and that is deliberate rather than
/// lazy. GoTrue requires `current_password` only when "secure password change"
/// is switched on in the dashboard and ignores it otherwise, so sending it
/// makes this screen correct under EITHER setting — instead of depending on a
/// toggle nobody will remember to check before flipping.
struct ChangePasswordScreen: View {
    @Environment(\.theme) private var theme
    @Environment(APIClient.self) private var api
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var current = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var busy = false
    @State private var error: String?
    @State private var done = false
    @FocusState private var focus: Field?

    private enum Field { case current, password, confirm }
    private static let minPassword = 8

    private var mismatched: Bool { !confirm.isEmpty && confirm != password }
    private var canSubmit: Bool {
        !busy && !current.isEmpty && password.count >= Self.minPassword && confirm == password
    }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if done {
                            successNote
                        } else {
                            fields
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)

                if !done {
                    BottomBar {
                        PrimaryButton(label: String(localized: "Save"),
                                      disabled: !canSubmit, action: submit)
                    }
                }
            }
        }
        .presentationBackground(theme.bg)
        .task { focus = .current }
    }

    private var header: some View {
        HStack {
            Text("Change password")
                .font(RFont.display(19, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(theme.text)
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Image(systemName: RIcon.close)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.text2)
                    .frame(width: 34, height: 34)
                    .background(theme.chipBg, in: .circle)
                    .contentShape(.circle)
            }
            .pressable(0.9)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var fields: some View {
        if let email = session.email {
            Text("For \(email).")
                .font(RFont.text(14))
                .foregroundStyle(theme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }

        AuthSecureField(placeholder: "Current password", text: $current,
                        contentType: .password, submitLabel: .next,
                        onSubmit: { focus = .password })
            .focused($focus, equals: .current)

        AuthSecureField(placeholder: "New password", text: $password,
                        contentType: .newPassword, submitLabel: .next,
                        onSubmit: { focus = .confirm })
            .focused($focus, equals: .password)

        AuthSecureField(placeholder: "Repeat it", text: $confirm,
                        contentType: .newPassword, submitLabel: .go,
                        onSubmit: submit)
            .focused($focus, equals: .confirm)

        Text(mismatched
             ? String(localized: "Those don't match yet.")
             : String(localized: "At least \(Self.minPassword) characters."))
            .font(RFont.text(12))
            .foregroundStyle(mismatched ? theme.warn : theme.text3)

        AuthErrorLine(message: error)
    }

    private var successNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: RIcon.check)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.live)
                .padding(.top, 2)
            Text("Password changed. Use the new one next time you sign in.")
                .font(RFont.text(14))
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
    }

    private func submit() {
        guard canSubmit else { return }
        busy = true
        error = nil
        Task {
            do {
                try await AuthAPI(client: api)
                    .updatePassword(newPassword: password, currentPassword: current)
                RHaptic.success()
                done = true
                // The session is NOT torn down. GoTrue keeps the current
                // access token valid through a password change, and signing
                // the user out of the app they are standing in would read as
                // an error rather than a success.
            } catch {
                RHaptic.warn()
                self.error = (error as? APIError)?.userMessage
                    ?? String(localized: "Couldn't change your password. Try again.")
            }
            busy = false
        }
    }
}
