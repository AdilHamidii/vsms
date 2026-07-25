import SwiftUI

struct AuthGate: View {
    @State private var api = APIClient()
    @State private var session: Session
    @State private var push = PushManager()
    @State private var iap = IAPStore()
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    // Pre-sign-in screens (onboarding, sign-in, bootstrap) run before AppState
    // exists, so they can't read its isDark preference — follow the system
    // appearance instead, otherwise they'd render light-only in Dark Mode.
    @Environment(\.colorScheme) private var colorScheme

    init() {
        let client = APIClient()
        _api = State(initialValue: client)
        _session = State(initialValue: Session(api: client))
    }

    var body: some View {
        Group {
            switch session.status {
            case .bootstrapping:
                BootstrapScreen()
            case .signedOut:
                if onboardingComplete {
                    SignInScreen()
                } else {
                    OnboardingScreen(onDone: { onboardingComplete = true })
                }
            case .signedIn:
                ContentView()
                    .task {
                        // Silent token refresh only — the permission DIALOG
                        // waits for the Waiting screen, where the user has a
                        // paid order in flight and an obvious reason to say yes.
                        await push.registerIfAuthorized()
                    }
            }
        }
        // Pre-sign-in: no AppState yet, so the default accent is correct here.
        .environment(\.theme, colorScheme == .dark ? .dark() : .light())
        .environment(api)
        .environment(session)
        .environment(push)
        .environment(iap)
        .task {
            push.attach(api: api, session: session)
            iap.attach(api: api)
            AppDelegate.push = push
            await session.bootstrap()
        }
    }
}

private struct BootstrapScreen: View {
    @Environment(\.theme) private var theme
    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            ProgressView()
                .controlSize(.large)
                .tint(theme.text2)
        }
    }
}
