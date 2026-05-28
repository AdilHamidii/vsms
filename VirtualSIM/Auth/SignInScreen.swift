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
            VStack(spacing: 28) {
                Spacer()
                logo
                copy
                Spacer()
                buttons
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 60)
        }
    }

    private var logo: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(theme.ink)
                .frame(width: 88, height: 88)
            Image(systemName: "bolt.fill")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(theme.onInk)
        }
        .shadow(color: theme.glow, radius: 24, x: 0, y: 6)
    }

    private var copy: some View {
        VStack(spacing: 10) {
            Text("Relay")
                .font(RFont.display(34, weight: .bold))
                .tracking(-0.8)
                .foregroundStyle(theme.text)
            Text("Get a temporary number, receive the code, done.")
                .font(RFont.text(15))
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.text2)
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

            Text("By signing in you agree to the Terms and Refund Policy.")
                .font(RFont.text(11))
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.text3)
        }
    }

    private func handleCompletion(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let err):
            if let asError = err as? ASAuthorizationError, asError.code == .canceled { return }
            error = err.localizedDescription
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
                    self.error = error.localizedDescription
                }
                inProgress = false
            }
        }
    }
}
