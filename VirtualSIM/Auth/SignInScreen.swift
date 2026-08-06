import AuthenticationServices
import SwiftUI

/// The one screen between onboarding and the product.
///
/// Its argument is unusual and worth keeping: most sign-in screens ask for
/// trust, and this one earns it by listing what it is NOT taking. The headline
/// and the list are the same claim from two directions, which is why the list
/// is a real card of `BenefitRow`s and not fine print.
///
/// ⚠️ `DealRow` — a tinted check circle plus a primary-ink label — used to live
/// here as a private struct, and it was the best row pattern in the app while
/// every selling screen elsewhere used `Bullet` (a 4pt grey dot at 13pt
/// `text2`, i.e. the app's fine-print device). That pattern is now the shared
/// `BenefitRow`, so this file uses it rather than keeping a private twin that
/// would drift the moment either was restyled.
struct SignInScreen: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(APIClient.self) private var api

    @State private var currentNonce: String?
    @State private var inProgress = false
    @State private var error: String?
    @State private var appeared = false

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                lockup
                    .padding(.horizontal, 20)
                    .padding(.top, 20)

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
                    .padding(.top, 22)
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

    private var lockup: some View {
        HStack(spacing: 8) {
            BrandWordmark(size: 22)
            Spacer()
        }
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

    private var dealCard: some View {
        Card(elevation: .raised) {
            VStack(alignment: .leading, spacing: 0) {
                MicroLabel("What signing in means")
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 8)
                BenefitRow(icon: RIcon.check,
                           label: "One tap with Apple, no password to make",
                           tint: theme.live)
                RowRule()
                BenefitRow(icon: RIcon.check,
                           label: "Your email stays hidden if you want it to",
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

    /// The returning-user half of the deal, and the honest form of "Restore".
    ///
    /// Everything a user has paid for hangs off the account, not the device: a
    /// rented line is read back from `my_line`, and credits live in `wallets`.
    /// So the restore action IS signing in with the same Apple ID, and saying
    /// that is more useful than a Restore button whose only possible outcome
    /// before authentication is "sign in first".
    private var returningNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.accent2)
                .padding(.top, 1)
            Text("Used vSMS before? Sign in with the same Apple ID and your number, credits and history come back. None of it is stored on this phone.")
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

            if let error {
                Text(error)
                    .font(RFont.text(13))
                    .foregroundStyle(theme.fail)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }

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
        .animation(RMotion.content, value: error)
    }

    private func handleCompletion(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let err):
            if let asError = err as? ASAuthorizationError, asError.code == .canceled { return }
            RHaptic.warn()
            error = "Couldn't sign in with Apple. Please try again."
        case .success(let auth):
            guard
                let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                let tokenData  = credential.identityToken,
                let idToken    = String(data: tokenData, encoding: .utf8),
                let nonce      = currentNonce
            else {
                RHaptic.warn()
                error = "Apple didn't return an identity token."
                return
            }
            inProgress = true
            error = nil
            Task {
                do {
                    let auth = AuthAPI(client: api)
                    let supaSession = try await auth.signInWithApple(idToken: idToken, nonce: nonce)
                    // The screen is about to be replaced by the app, so this is
                    // the only confirmation the tap ever gets.
                    RHaptic.success()
                    session.adopt(supaSession)
                } catch {
                    RHaptic.warn()
                    self.error = (error as? APIError)?.userMessage ?? "Couldn't sign in. Please try again."
                }
                inProgress = false
            }
        }
    }
}
