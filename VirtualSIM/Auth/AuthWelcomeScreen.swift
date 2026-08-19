import AuthenticationServices
import SwiftUI

/// The first screen after onboarding: pick how you get in.
///
/// Was `SignInScreen`, which offered exactly one way — Sign in with Apple —
/// and whose copy was written around that being the only door. Its argument is
/// worth keeping: most sign-in screens ask for trust, and this one earns it by
/// listing what it is NOT taking.
///
/// ⚠️ APPLE STAYS VISUALLY PRIMARY. It is one tap, it is what every existing
/// account uses (298 of 528 identities are Apple private-relay addresses), and
/// it needs no mail to be delivered to work. Email exists for people who
/// cannot or will not use an Apple ID — it is the alternative, not the
/// replacement, and the layout should keep saying so.
struct AuthWelcomeScreen: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(APIClient.self) private var api

    var onEmailSignIn: () -> Void
    var onCreateAccount: () -> Void

    @State private var currentNonce: String?
    @State private var inProgress = false
    @State private var error: String?
    @State private var appeared = false

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                AuthHeader()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        headline
                        dealCard
                            .padding(.top, 26)
                            .riseIn(appeared, index: 2)
                        returningNote
                            .padding(.top, 14)
                            .riseIn(appeared, index: 3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)

                // The CTA is pinned and the content dissolves into it, so a
                // small screen scrolls without ever hiding the only button on
                // the page behind a hard edge.
                BottomBar { buttons }
            }
        }
        .task { withAnimation(RMotion.content) { appeared = true } }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 10) {
            MicroLabel("Sign in")
                .riseIn(appeared, index: 0)
            Text("Signing in asks\nfor almost nothing.")
                .displayType(34)
                .lineSpacing(1)
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text("That's the whole idea. You're here to keep your real number to yourself.")
                .font(RFont.text(15))
                .lineSpacing(3)
                .foregroundStyle(theme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .riseIn(appeared, index: 1)
    }

    /// ⚠️ TWO OF THESE ROWS USED TO BE UNCONDITIONAL AND ARE NOW SCOPED TO
    /// APPLE. "One tap with Apple, no password to make" and "Your email stays
    /// hidden if you want it to" were true when Apple was the only door; with
    /// an email option on the same screen the first is contradicted by the
    /// button below it and the second describes a feature only Apple provides.
    /// A trust list that the screen itself disproves is worse than a shorter
    /// one.
    private var dealCard: some View {
        Card(elevation: .raised) {
            VStack(alignment: .leading, spacing: 0) {
                MicroLabel("What signing in means")
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 8)
                BenefitRow(icon: RIcon.check,
                           label: "With Apple, there's no password to make and your email can stay hidden",
                           tint: theme.live)
                RowRule()
                BenefitRow(icon: RIcon.check,
                           label: "Your real phone number never touches this app",
                           tint: theme.live)
                RowRule()
                BenefitRow(icon: RIcon.check,
                           label: "No ads, no tracking, no email list",
                           tint: theme.live)
                    .padding(.bottom, 6)
            }
        }
    }

    /// The Restore path, stated as what actually restores things.
    ///
    /// Everything a user has paid for hangs off the account, not the device: a
    /// rented line is read back from `my_line`, and credits live in `wallets`.
    /// So the restore action IS signing in again, and saying that is more
    /// useful than a Restore button whose only possible outcome before
    /// authentication is "sign in first".
    private var returningNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.accent2)
                .padding(.top, 1)
            // ⚠️ Kept SHORT because this screen now carries three controls
            // instead of one, and the note is the first thing the taller stack
            // pushes under the fold.
            Text("Used vSMS before? Sign in the same way you did last time — your number, credits and history come back.")
                .font(RFont.text(13))
                .lineSpacing(2)
                .foregroundStyle(theme.text2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private var buttons: some View {
        VStack(spacing: 12) {
            SignInWithAppleButton(.signIn,
                onRequest: { request in
                    RHaptic.select()
                    let nonce = AppleNonce.random()
                    currentNonce = nonce
                    request.requestedScopes = [.fullName, .email]
                    request.nonce = AppleNonce.sha256(nonce)
                },
                onCompletion: handleCompletion
            )
            .signInWithAppleButtonStyle(theme.isDark ? .white : .black)
            .frame(height: 54)
            .clipShape(Capsule())
            .disabled(inProgress)
            .opacity(inProgress ? 0.6 : 1)

            GhostButton(label: String(localized: "Continue with email"), action: onEmailSignIn)
                .disabled(inProgress)

            Button(action: onCreateAccount) {
                Text("New here? Create an account")
                    .font(RFont.text(13, weight: .medium))
                    .foregroundStyle(theme.accent2)
                    .padding(.vertical, 4)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(inProgress)

            AuthErrorLine(message: error)

            legal
        }
        .animation(RMotion.content, value: error)
    }

    private var legal: some View {
        VStack(spacing: 4) {
            Text("By signing in you agree to our")
                .font(RFont.text(11))
                .foregroundStyle(theme.text3)
            HStack(spacing: 4) {
                Link("Terms of Use", destination: LegalLinks.terms)
                    .font(RFont.text(11, weight: .medium))
                    .foregroundStyle(theme.text2)
                Text("and")
                    .font(RFont.text(11))
                    .foregroundStyle(theme.text3)
                Link("Privacy Policy", destination: LegalLinks.privacy)
                    .font(RFont.text(11, weight: .medium))
                    .foregroundStyle(theme.text2)
                Text(verbatim: ".")
                    .font(RFont.text(11))
                    .foregroundStyle(theme.text3)
            }
        }
        .multilineTextAlignment(.center)
    }

    private func handleCompletion(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let err):
            if let asError = err as? ASAuthorizationError, asError.code == .canceled { return }
            RHaptic.warn()
            error = String(localized: "Couldn't sign in with Apple. Please try again.")
        case .success(let auth):
            guard
                let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                let tokenData  = credential.identityToken,
                let idToken    = String(data: tokenData, encoding: .utf8),
                let nonce      = currentNonce
            else {
                RHaptic.warn()
                error = String(localized: "Apple didn't return an identity token.")
                return
            }
            inProgress = true
            error = nil
            Task {
                do {
                    let authApi = AuthAPI(client: api)
                    let supaSession = try await authApi.signInWithApple(idToken: idToken, nonce: nonce)
                    // The screen is about to be replaced by the app, so this is
                    // the only confirmation the tap ever gets.
                    RHaptic.success()
                    session.adopt(supaSession)
                } catch {
                    RHaptic.warn()
                    self.error = (error as? APIError)?.userMessage
                        ?? String(localized: "Couldn't sign in. Please try again.")
                }
                inProgress = false
            }
        }
    }
}
