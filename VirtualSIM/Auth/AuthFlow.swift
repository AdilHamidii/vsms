import SwiftUI

/// Everything between onboarding and the product.
///
/// ── Why a hand-rolled stack and not `NavigationStack` ────────────────────
///
/// This runs INSIDE `AuthGate`, above `ContentView` — so `AppState`,
/// `FlowStage` and the app's `fullScreenCover(item:)` machinery do not exist
/// yet, and neither does the floating `TabBar` that is the documented reason
/// this app avoids navigation pushes at all. A route enum plus an array is the
/// same vocabulary `OnboardingScreen` already uses, it needs no system chrome
/// to fight, and it keeps "where am I in auth" in exactly one place.
///
/// The exit is not a route: `session.adopt` flips `Session.status`, `AuthGate`
/// swaps this whole view for `ContentView`, and the stack goes away with it.
enum AuthRoute: Hashable {
    case welcome
    case signIn
    case signUp
    /// Confirming a brand-new account.
    case confirmCode(email: String)
    case forgot
    /// Confirming a password reset. Same screen as `confirmCode`, different
    /// GoTrue token type — they are separate columns server-side, so the wrong
    /// one simply never matches.
    case resetCode(email: String)
    /// Reached only with a live recovery token that we have deliberately NOT
    /// adopted as a session. See `APIClient.overrideToken`.
    case newPassword(email: String, token: String)
}

struct AuthFlowScreen: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var stack: [AuthRoute] = [.welcome]

    private var current: AuthRoute { stack.last ?? .welcome }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            content
                .transition(transition)
                .id(current)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch current {
        case .welcome:
            AuthWelcomeScreen(
                onEmailSignIn: { push(.signIn) },
                onCreateAccount: { push(.signUp) })
        case .signIn:
            EmailSignInScreen(
                onBack: pop,
                onForgot: { push(.forgot) },
                onNeedsConfirmation: { email in push(.confirmCode(email: email)) })
        case .signUp:
            EmailSignUpScreen(
                onBack: pop,
                onSent: { email in push(.confirmCode(email: email)) })
        case .confirmCode(let email):
            CodeEntryScreen(email: email, purpose: .signup, onBack: pop, onVerified: { _ in })
        case .forgot:
            ForgotPasswordScreen(
                onBack: pop,
                onSent: { email in push(.resetCode(email: email)) })
        case .resetCode(let email):
            CodeEntryScreen(email: email, purpose: .recovery, onBack: pop,
                            onVerified: { token in push(.newPassword(email: email, token: token)) })
        case .newPassword(let email, let token):
            SetNewPasswordScreen(email: email, recoveryToken: token, onBack: pop)
        }
    }

    private var transition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                          removal: .move(edge: .leading).combined(with: .opacity))
    }

    private func push(_ route: AuthRoute) {
        withAnimation(reduceMotion ? nil : RMotion.panel) { stack.append(route) }
    }

    private func pop() {
        guard stack.count > 1 else { return }
        withAnimation(reduceMotion ? nil : RMotion.panel) { _ = stack.removeLast() }
    }
}
