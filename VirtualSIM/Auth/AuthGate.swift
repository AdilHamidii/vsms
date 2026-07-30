import SwiftUI

struct AuthGate: View {
    @State private var api = APIClient()
    @State private var session: Session
    @State private var push = PushManager()
    @State private var iap = IAPStore()
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    // Pre-sign-in screens (onboarding, sign-in, splash) run before AppState
    // exists, so they read the same UserDefaults it will. Via @AppStorage so a
    // change applies live, falling back to the migration path when the key has
    // never been written.
    //
    // These used to hard-follow the SYSTEM scheme, with the note "otherwise
    // they'd render light-only in Dark Mode" — a fair workaround when the only
    // preference was a Bool defaulting to false. Now that `.system` exists and
    // is the default, that case is covered by the preference itself, and an
    // explicit Light/Dark choice is honoured here too instead of being ignored
    // until the app proper loads.
    @AppStorage(PrefKey.appearance) private var appearanceRaw = ""
    @AppStorage(PrefKey.accent) private var prefAccent = AccentColor.blue.rawValue
    @Environment(\.colorScheme) private var colorScheme

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? AppState.storedAppearance()
    }
    private var resolvedTheme: Theme {
        let accent = AccentColor(rawValue: prefAccent) ?? .green
        return appearance.isDark(system: colorScheme) ? .dark(accent) : .light(accent)
    }

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
        .environment(\.theme, resolvedTheme)
        // nil under `.system`, which is what actually lets the device decide.
        .preferredColorScheme(appearance.colorScheme)
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
