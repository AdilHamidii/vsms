import SwiftUI

struct AuthGate: View {
    @State private var api = APIClient()
    @State private var session: Session
    @State private var push = PushManager()
    @State private var iap = IAPStore()
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    // The splash is themed from the STORED preference, not the system scheme,
    // unlike its siblings below. It is the one pre-sign-in screen that hands
    // straight over to `ContentView` on the common path (a returning, signed-in
    // user), and ContentView forces `state.isDark` — so matching the system
    // here would recolour the whole screen at the handoff.
    @AppStorage(PrefKey.isDark) private var prefIsDark = false
    @AppStorage(PrefKey.accent) private var prefAccent = AccentColor.green.rawValue
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
                SplashScreen(state: .indeterminate)
                    .environment(\.theme, prefIsDark
                                 ? .dark(AccentColor(rawValue: prefAccent) ?? .green)
                                 : .light(AccentColor(rawValue: prefAccent) ?? .green))
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
                        // Quiet provisional registration so users who never
                        // reach the Waiting screen are still reachable by the
                        // daily-credit and winback nudges. No dialog is shown.
                        await push.registerProvisionalIfUndetermined()
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

// BootstrapScreen (a bare centred ProgressView) was replaced by SplashScreen.
// A spinner alone gave the launch no identity and, more importantly, looked
// identical whether the session refresh was working or wedged.
