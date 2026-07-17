import AuthenticationServices
import SwiftUI

struct SignInScreen: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(APIClient.self) private var api

    @State private var currentNonce: String?
    @State private var inProgress = false
    @State private var error: String?

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                lockup
                Spacer(minLength: 20)
                headline
                dealCard
                    .padding(.top, 26)
                Spacer(minLength: 20)
                buttons
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 44)
        }
    }

    private var lockup: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.ink)
                .frame(width: 26, height: 26)
                .overlay(
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.onInk)
                )
            Text("vSMS")
                .font(RFont.display(19, weight: .bold))
                .tracking(-0.3)
                .foregroundStyle(theme.text)
            Spacer()
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Signing in asks\nfor almost nothing.")
                .font(RFont.display(30, weight: .bold))
                .tracking(-0.8)
                .lineSpacing(2)
                .foregroundStyle(theme.text)
            Text("That's the whole idea — you're here to keep your real number to yourself.")
                .font(RFont.text(15))
                .lineSpacing(3)
                .foregroundStyle(theme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dealCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                Text("WHAT SIGNING IN MEANS")
                    .font(RFont.text(11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(theme.text3)
                    .padding(.bottom, 16)
                DealRow(text: "One tap with Apple — no password to make")
                DealRow(text: "Your email stays hidden if you want it to")
                DealRow(text: "Your real phone number never touches this app")
                DealRow(text: "No ads, no tracking, no email list", last: true)
            }
            .padding(20)
        }
    }

    private var buttons: some View {
        VStack(spacing: 14) {
            SignInWithAppleButton(.signIn,
                onRequest: { request in
                    let nonce = AppleNonce.random()
                    currentNonce = nonce
                    request.requestedScopes = [.fullName, .email]
                    request.nonce = AppleNonce.sha256(nonce)
                },
                onCompletion: handleCompletion
            )
            .signInWithAppleButtonStyle(theme.isDark ? .white : .black)
            .frame(height: 52)
            .clipShape(.rect(cornerRadius: 14))
            .disabled(inProgress)
            .opacity(inProgress ? 0.6 : 1)

            if let error {
                Text(error)
                    .font(RFont.text(13))
                    .foregroundStyle(theme.fail)
                    .multilineTextAlignment(.center)
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
                    Text(".")
                        .font(RFont.text(11))
                        .foregroundStyle(theme.text3)
                }
            }
            .multilineTextAlignment(.center)
        }
    }

    private struct DealRow: View {
        @Environment(\.theme) private var theme
        let text: String
        var last: Bool = false

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.live)
                    .frame(width: 22, height: 22)
                    .background(theme.liveSoft, in: .circle)
                Text(text)
                    .font(RFont.text(14))
                    .foregroundStyle(theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.bottom, last ? 0 : 14)
        }
    }

    private func handleCompletion(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let err):
            if let asError = err as? ASAuthorizationError, asError.code == .canceled { return }
            error = "Couldn't sign in with Apple. Please try again."
        case .success(let auth):
            guard
                let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                let tokenData  = credential.identityToken,
                let idToken    = String(data: tokenData, encoding: .utf8),
                let nonce      = currentNonce
            else {
                error = "Apple didn't return an identity token."
                return
            }
            inProgress = true
            error = nil
            Task {
                do {
                    let auth = AuthAPI(client: api)
                    let supaSession = try await auth.signInWithApple(idToken: idToken, nonce: nonce)
                    session.adopt(supaSession)
                } catch {
                    self.error = (error as? APIError)?.userMessage ?? "Couldn't sign in. Please try again."
                }
                inProgress = false
            }
        }
    }
}
