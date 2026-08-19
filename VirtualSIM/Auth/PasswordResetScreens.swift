import SwiftUI

// Password reset, in two screens either side of `CodeEntryScreen`.
//
// 🔴 THE WHOLE FLOW DELIBERATELY NEVER TOUCHES A LINK. `site_url` is
// `relay://auth` and NOTHING in this app handles that scheme — there is no
// deep-link handler at all — so a link-based reset would need one built, and
// mail clients open links in in-app browsers where they die anyway. Corporate
// mail scanners also pre-fetch links, consuming a single-use token before the
// user ever taps it. A 6-digit code has none of those failure modes, and this
// app is in the business of delivering 6-digit codes.

// MARK: - Ask for the code

struct ForgotPasswordScreen: View {
    @Environment(\.theme) private var theme
    @Environment(APIClient.self) private var api

    var onBack: () -> Void
    var onSent: (String) -> Void

    @State private var email = ""
    @State private var busy = false
    @State private var error: String?
    @State private var appeared = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                AuthHeader(onBack: onBack)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        MicroLabel("Reset password")
                            .riseIn(appeared, index: 0)
                        Text("We'll send you\na code.")
                            .displayType(30)
                            .lineSpacing(1)
                            .foregroundStyle(theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .riseIn(appeared, index: 1)

                        AuthTextField(placeholder: "Email", text: $email,
                                      contentType: .username, submitLabel: .go,
                                      onSubmit: submit)
                            .focused($focused)
                            .riseIn(appeared, index: 2)

                        AuthErrorLine(message: error)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)

                BottomBar {
                    PrimaryButton(label: String(localized: "Send me a code"),
                                  disabled: busy || !looksLikeEmail(email),
                                  action: submit)
                }
            }
        }
        .task {
            withAnimation(RMotion.content) { appeared = true }
            focused = true
        }
    }

    private func submit() {
        guard !busy, looksLikeEmail(email) else { return }
        busy = true
        error = nil
        let address = email.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                try await AuthAPI(client: api).requestPasswordReset(email: address)
            } catch {
                // ⚠️ ONLY TRANSPORT FAILURES SURFACE HERE. `/recover` answers
                // 200 whether or not the address exists, and that is
                // deliberate — it must not become a way to ask "does this
                // person have an account?". So we advance on success AND on a
                // business error, and stop only when the request itself could
                // not be made.
                if (error as? APIError) == nil {
                    self.error = String(localized: "Couldn't reach the server. Check your connection.")
                    busy = false
                    return
                }
            }
            RHaptic.select()
            busy = false
            onSent(address)
        }
    }
}

// MARK: - Set the new one

struct SetNewPasswordScreen: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(APIClient.self) private var api

    let email: String
    /// The access token from the verified recovery session. Held here rather
    /// than adopted — see `APIClient.overrideToken`.
    let recoveryToken: String
    var onBack: () -> Void

    @State private var password = ""
    @State private var confirm = ""
    @State private var busy = false
    @State private var error: String?
    @State private var appeared = false
    @FocusState private var focus: Field?
    /// The password the server has ALREADY accepted, if it has. Non-nil means
    /// the change landed and only the sign-in is outstanding — see `submit()`.
    @State private var changedPassword: String?

    private enum Field { case password, confirm }
    private static let minPassword = 8

    private var mismatched: Bool { !confirm.isEmpty && confirm != password }
    private var canSubmit: Bool {
        !busy && password.count >= Self.minPassword && confirm == password
    }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                AuthHeader(onBack: onBack)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        MicroLabel("New password")
                            .riseIn(appeared, index: 0)
                        Text("Pick a new one.")
                            .displayType(30)
                            .foregroundStyle(theme.text)
                            .riseIn(appeared, index: 1)

                        AuthSecureField(placeholder: "New password", text: $password,
                                        contentType: .newPassword, submitLabel: .next,
                                        onSubmit: { focus = .confirm })
                            .focused($focus, equals: .password)
                            .riseIn(appeared, index: 2)

                        AuthSecureField(placeholder: "Repeat it", text: $confirm,
                                        contentType: .newPassword, submitLabel: .go,
                                        onSubmit: submit)
                            .focused($focus, equals: .confirm)
                            .riseIn(appeared, index: 3)

                        Text(mismatched
                             ? String(localized: "Those don't match yet.")
                             : String(localized: "At least \(Self.minPassword) characters."))
                            .font(RFont.text(12))
                            .foregroundStyle(mismatched ? theme.warn : theme.text3)
                            .riseIn(appeared, index: 4)

                        AuthErrorLine(message: error)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)

                BottomBar {
                    // Stops promising a save that has already happened.
                    PrimaryButton(label: changedPassword == nil
                                  ? String(localized: "Save and sign in")
                                  : String(localized: "Sign in"),
                                  disabled: !canSubmit, action: submit)
                }
            }
        }
        .task {
            withAnimation(RMotion.content) { appeared = true }
            focus = .password
        }
    }

    /// 🔴 TWO SERVER CALLS, TWO OUTCOMES, TWO MESSAGES — never one `do`.
    ///
    /// This used to run `updatePassword` and `signIn` inside a single `do` with
    /// one catch reading "Couldn't save your new password. Try again." So a
    /// transient failure on the SECOND call reported the FIRST as failed while
    /// the password had in fact been changed: the user then retried with their
    /// old password, which no longer worked, or left believing nothing had
    /// happened and could not sign in with either one.
    ///
    /// `changedPassword` records the one the server accepted, so a retry signs
    /// in with THAT rather than re-sending a recovery token that may already be
    /// spent, and the CTA stops claiming it will save anything.
    private func submit() {
        guard canSubmit else { return }
        busy = true
        error = nil
        Task {
            let api = AuthAPI(client: self.api)

            // Step 1 — change the password. Skipped once it has succeeded.
            if changedPassword == nil {
                do {
                    try await api.updatePassword(newPassword: password,
                                                 overrideToken: recoveryToken)
                    changedPassword = password
                } catch {
                    RHaptic.warn()
                    self.error = (error as? APIError)?.userMessage
                        ?? String(localized: "Couldn't save your new password. Try again.")
                    busy = false
                    return
                }
            }

            // Step 2 — only NOW is the recovery session worth adopting: the
            // password it was issued to change has actually been changed.
            do {
                let supa = try await api.signIn(email: email,
                                                password: changedPassword ?? password)
                RHaptic.success()
                session.adopt(supa)
            } catch {
                RHaptic.warn()
                // States the part that is already true. Whatever happens next,
                // the new password is the one that works.
                self.error = String(localized: "Your new password is saved, but we couldn't sign you in just now. Try again with it.")
                busy = false
            }
        }
    }
}
