import SwiftUI

// The email half of the door. Three screens, all built from the same pieces as
// the rest of the app — `Card`, `PrimaryButton`, `MicroLabel`, `BottomBar`,
// `riseIn` — plus the two fields in `AuthFields.swift`.
//
// ⚠️ NONE OF THESE MAY USE `ErrorBanner`. It reads `AppState`, which does not
// exist above `ContentView`. Errors go inline through `AuthErrorLine`, which is
// also the right shape for "this field is wrong".

// MARK: - Sign in

struct EmailSignInScreen: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(APIClient.self) private var api

    var onBack: () -> Void
    var onForgot: () -> Void
    /// The address needs confirming before it can sign in. The caller pushes
    /// the code screen; we do not treat it as a failure, because it is not one
    /// — the account exists and the user simply never finished.
    var onNeedsConfirmation: (String) -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var appeared = false
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    private var canSubmit: Bool {
        !busy && looksLikeEmail(email) && !password.isEmpty
    }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                AuthHeader(onBack: onBack)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        MicroLabel("Sign in")
                            .riseIn(appeared, index: 0)
                        Text("Welcome back.")
                            .displayType(30)
                            .foregroundStyle(theme.text)
                            .riseIn(appeared, index: 1)

                        AuthTextField(placeholder: "Email", text: $email,
                                      contentType: .username, submitLabel: .next,
                                      onSubmit: { focus = .password })
                            .focused($focus, equals: .email)
                            .riseIn(appeared, index: 2)

                        AuthSecureField(placeholder: "Password", text: $password,
                                        contentType: .password, submitLabel: .go,
                                        onSubmit: submit)
                            .focused($focus, equals: .password)
                            .riseIn(appeared, index: 3)

                        Button(action: onForgot) {
                            Text("Forgot your password?")
                                .font(RFont.text(13, weight: .medium))
                                .foregroundStyle(theme.accent2)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
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
                    PrimaryButton(label: String(localized: "Sign in"),
                                  disabled: !canSubmit, action: submit)
                }
            }
        }
        .task {
            withAnimation(RMotion.content) { appeared = true }
            focus = .email
        }
    }

    private func submit() {
        guard canSubmit else { return }
        busy = true
        error = nil
        Task {
            do {
                let supa = try await AuthAPI(client: api)
                    .signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
                RHaptic.success()
                session.adopt(supa)
            } catch {
                RHaptic.warn()
                // An unconfirmed account is not a wrong password, and telling
                // the user it is would send them to reset a password that
                // works. Route them to the code screen instead.
                if isUnconfirmed(error) {
                    busy = false
                    onNeedsConfirmation(email.trimmingCharacters(in: .whitespaces))
                    return
                }
                self.error = (error as? APIError)?.userMessage
                    ?? String(localized: "Couldn't sign in. Please try again.")
            }
            busy = false
        }
    }

    private func isUnconfirmed(_ error: Error) -> Bool {
        guard case .http(_, let body)? = error as? APIError, let body else { return false }
        return body.contains("email_not_confirmed")
    }
}

// MARK: - Create an account

struct EmailSignUpScreen: View {
    @Environment(\.theme) private var theme
    @Environment(APIClient.self) private var api

    var onBack: () -> Void
    var onSent: (String) -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var appeared = false
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    /// Matches the dashboard's minimum. GoTrue answers `weak_password` below
    /// it, so this only saves a round trip — it is not the rule.
    private static let minPassword = 8

    private var canSubmit: Bool {
        !busy && looksLikeEmail(email) && password.count >= Self.minPassword
    }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                AuthHeader(onBack: onBack)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        MicroLabel("Create an account")
                            .riseIn(appeared, index: 0)
                        Text("An email and a\npassword. That's it.")
                            .displayType(30)
                            .lineSpacing(1)
                            .foregroundStyle(theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .riseIn(appeared, index: 1)

                        AuthTextField(placeholder: "Email", text: $email,
                                      contentType: .username, submitLabel: .next,
                                      onSubmit: { focus = .password })
                            .focused($focus, equals: .email)
                            .riseIn(appeared, index: 2)

                        AuthSecureField(placeholder: "Password", text: $password,
                                        contentType: .newPassword, submitLabel: .go,
                                        onSubmit: submit)
                            .focused($focus, equals: .password)
                            .riseIn(appeared, index: 3)

                        Text("At least \(Self.minPassword) characters.")
                            .font(RFont.text(12))
                            .foregroundStyle(theme.text3)
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
                    PrimaryButton(label: String(localized: "Send me a code"),
                                  disabled: !canSubmit, action: submit)
                }
            }
        }
        .task {
            withAnimation(RMotion.content) { appeared = true }
            focus = .email
        }
    }

    private func submit() {
        guard canSubmit else { return }
        busy = true
        error = nil
        let address = email.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                let result = try await AuthAPI(client: api).signUp(email: address, password: password)
                #if DEBUG
                // 🔴 LOGGED, NEVER BRANCHED ON. An empty `identities` array is
                // GoTrue telling us this address already has a confirmed
                // account — deliberately as a 200, so that this endpoint
                // cannot be used to discover who has one. Acting on it here
                // would hand that oracle straight back to a caller.
                if result.identities?.isEmpty == true {
                    print("[auth] signup returned a sanitized user — address likely already registered")
                }
                #endif
                RHaptic.success()
                busy = false
                onSent(address)
            } catch {
                RHaptic.warn()
                self.error = (error as? APIError)?.userMessage
                    ?? String(localized: "Couldn't create your account. Please try again.")
                busy = false
            }
        }
    }
}

// MARK: - The code

struct CodeEntryScreen: View {
    enum Purpose {
        case signup, recovery
        /// GoTrue keeps the confirmation and recovery tokens in separate
        /// columns, so the wrong type here simply never matches.
        var verifyType: String { self == .signup ? "signup" : "recovery" }
    }

    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(APIClient.self) private var api

    let email: String
    let purpose: Purpose
    var onBack: () -> Void
    /// Recovery only: hands the caller the access token from the verified
    /// session, WITHOUT adopting it — see `APIClient.overrideToken`.
    var onVerified: (String) -> Void

    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var resendIn = 0
    @State private var appeared = false
    @FocusState private var focused: Bool

    private static let length = 6

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                AuthHeader(onBack: onBack)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        MicroLabel("Check your email")
                            .riseIn(appeared, index: 0)
                        Text("Enter the code\nwe just sent.")
                            .displayType(30)
                            .lineSpacing(1)
                            .foregroundStyle(theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .riseIn(appeared, index: 1)
                        Text("Sent to \(email).")
                            .font(RFont.text(14))
                            .foregroundStyle(theme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                            .riseIn(appeared, index: 2)

                        codeField.riseIn(appeared, index: 3)

                        resendRow.riseIn(appeared, index: 4)

                        AuthErrorLine(message: error)

                        if let notice {
                            Text(verbatim: notice)
                                .font(RFont.text(13))
                                .foregroundStyle(theme.text2)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // 🔴 THE HONEST UI FOR ENUMERATION PROTECTION. If the
                        // address already had an account, sign-up answered 200
                        // and sent NO mail — by design, so the endpoint cannot
                        // be used to discover who is registered. No error is
                        // available to show, so the screen names the two moves
                        // that actually work instead of leaving the user
                        // waiting for a code that will never arrive.
                        if purpose == .signup {
                            Text("Nothing arriving? You may already have an account with this address — go back and sign in, or reset your password.")
                                .font(RFont.text(12))
                                .foregroundStyle(theme.text3)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)

                BottomBar {
                    PrimaryButton(label: String(localized: "Confirm"),
                                  disabled: busy || code.count < Self.length,
                                  action: submit)
                }
            }
        }
        .task {
            withAnimation(RMotion.content) { appeared = true }
            focused = true
            await countDown()
        }
    }

    private var codeField: some View {
        // `.oneTimeCode` is what puts the emailed code on the keyboard bar, so
        // the user never leaves the app to read it. On a product that sells
        // verification codes, making people copy ours by hand would be a poor
        // joke.
        TextField("000000", text: $code)
            .font(RFont.mono(26, weight: .semibold))
            .foregroundStyle(theme.text)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .multilineTextAlignment(.center)
            .focused($focused)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(theme.chipBg, in: RoundedRectangle(cornerRadius: RRadius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RRadius.sm, style: .continuous)
                    .stroke(focused ? theme.ink.opacity(0.55) : theme.sep, lineWidth: focused ? 1.5 : 1)
            )
            .animation(RMotion.select, value: focused)
            .onChange(of: code) { _, value in
                let digits = String(value.filter(\.isNumber).prefix(Self.length))
                if digits != value { code = digits }
                if digits.count == Self.length, !busy { submit() }
            }
    }

    private var resendRow: some View {
        HStack(spacing: 6) {
            Text("Didn't get it?")
                .font(RFont.text(13))
                .foregroundStyle(theme.text3)
            Button(action: resend) {
                Text(resendIn > 0
                     ? String(localized: "Resend in \(resendIn)s")
                     : String(localized: "Send a new code"))
                    .font(RFont.text(13, weight: .semibold))
                    .foregroundStyle(resendIn > 0 ? theme.text3 : theme.accent2)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(resendIn > 0 || busy)
            Spacer(minLength: 0)
        }
    }

    private func submit() {
        guard code.count == Self.length, !busy else { return }
        busy = true
        error = nil
        notice = nil
        Task {
            do {
                let supa = try await AuthAPI(client: api)
                    .verifyEmailCode(email: email, token: code, type: purpose.verifyType)
                RHaptic.success()
                switch purpose {
                case .signup:
                    // Confirmed: this IS the session, and the server has just
                    // paid the signup grant on the same transition.
                    session.adopt(supa)
                case .recovery:
                    // 🔴 DO NOT ADOPT. This is a real session, and adopting it
                    // would drop the user into the app with the old password
                    // still set and no idea they never finished the reset.
                    onVerified(supa.accessToken)
                }
            } catch {
                RHaptic.warn()
                self.error = (error as? APIError)?.userMessage
                    ?? String(localized: "That code didn't work. Ask for a new one.")
                code = ""
            }
            busy = false
        }
    }

    private func resend() {
        guard resendIn == 0 else { return }
        error = nil
        Task {
            do {
                switch purpose {
                case .signup:  try await AuthAPI(client: api).resendSignupCode(email: email)
                case .recovery: try await AuthAPI(client: api).requestPasswordReset(email: email)
                }
                notice = String(localized: "Sent. It can take a minute to arrive.")
                RHaptic.select()
            } catch {
                self.error = (error as? APIError)?.userMessage
                    ?? String(localized: "Couldn't send a new code. Try again shortly.")
            }
            resendIn = 60
            await countDown()
        }
    }

    private func countDown() async {
        while resendIn > 0, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            resendIn -= 1
        }
    }
}
