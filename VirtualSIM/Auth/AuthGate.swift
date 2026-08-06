import SwiftUI

struct AuthGate: View {
    @State private var api = APIClient()
    @State private var session: Session
    @State private var push = PushManager()
    @State private var iap = IAPStore()
    /// The rented line's subscription. Separate from `IAPStore` because a
    /// subscription is an entitlement rather than a credit grant — but it
    /// deliberately does NOT open its own `Transaction.updates` listener; see
    /// `SubscriptionStore`.
    @State private var subs = SubscriptionStore()
    /// Owns CallKit and PushKit for the rented line.
    ///
    /// Constructed here rather than in `ContentView` because it registers a
    /// `CXProvider` delegate and must outlive any view that presents a call —
    /// and because an incoming call has to be reportable whatever screen the
    /// app happens to be on.
    @State private var calls = CallController()
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
    @AppStorage(PrefKey.accent) private var prefAccent = AccentColor.green.rawValue
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
        .environment(subs)
        .environment(calls)
        .task {
            push.attach(api: api, session: session)
            iap.attach(api: api)
            // AFTER iap.attach, because this registers the subscription handler
            // on the single shared transaction listener that IAPStore owns.
            subs.attach(api: api, iap: iap)
            // No `voice:` argument yet — the TelnyxRTC package is not added, so
            // this leaves `NullVoiceClient` in place and `isVoiceAvailable`
            // false, which is what keeps the dialer unreachable. Pass a real
            // client here and the whole calling path lights up.
            calls.attach(api: api)
            AppDelegate.push = push

            #if DEBUG
            // App Store screenshots are produced on a SIMULATOR, because that
            // is the only way to get Apple's exact accepted pixel sizes — and
            // Sign in with Apple does not work there, so the whole app is
            // unreachable behind this gate. See `ScreenshotMode`; the entire
            // path is compiled out of Release.
            if let shot = ScreenshotMode.screen {
                // `onboarding` is the one screen that lives BEFORE the gate, so
                // it wants the opposite treatment: stay signed out, and force
                // the first-run branch regardless of what a previous launch on
                // this simulator left in UserDefaults.
                if shot == .onboarding {
                    onboardingComplete = false
                    session.status = .signedOut
                } else {
                    session.status = .signedIn(userId: "screenshot")
                }
                return
            }
            #endif

            await session.bootstrap()
        }
    }
}

// BootstrapScreen (a bare centred ProgressView) was replaced by SplashScreen.
// A spinner alone gave the launch no identity and, more importantly, looked
// identical whether the session refresh was working or wedged.
