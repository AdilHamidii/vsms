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
    /// The e-mail subscription's store.
    ///
    /// 🔴 OWNED HERE, NOT IN `ContentView`, AND THAT IS THE WHOLE FIX.
    /// `iap.attach(api:)` starts the unfinished-transaction sweep, and
    /// `ContentView`'s task registered `onMailSubscription` only AFTER
    /// `await state.coldStart(api:)` — six sequential fetches, ~3 seconds. So
    /// on every launch the sweep reached `IAPStore.handle`, found the handler
    /// nil, and dropped the transaction forever. `MailSubscriptionStore.submit`
    /// deliberately leaves a transaction UNFINISHED when the server call fails,
    /// expecting exactly that sweep to recover it — so a failed mail
    /// subscription was only ever recoverable through the paywall's manual
    /// Restore, which most users never open. `SubscriptionStore` was registered
    /// synchronously before the sweep and was fine; this one was the odd one
    /// out. Anything else that handles a transaction must be registered here,
    /// before `iap.attach`'s sweep can run.
    @State private var mailStore = MailSubscriptionStore()
    /// Owns CallKit and PushKit for the rented line.
    ///
    /// Constructed here rather than in `ContentView` because it registers a
    /// `CXProvider` delegate and must outlive any view that presents a call —
    /// and because an incoming call has to be reportable whatever screen the
    /// app happens to be on.
    ///
    /// Adopts the instance the app delegate built at launch rather than making
    /// its own: PushKit's registry and the `CXProvider` have to exist before
    /// the first VoIP push, which can arrive before any view has been created.
    @State private var calls = CallController.shared
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
                    AuthFlowScreen()
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
        .environment(mailStore)
        .environment(calls)
        // The stores are owned HERE and so survive a sign-out. `isEntitled` is
        // a per-ACCOUNT claim, so it must not: it would otherwise carry from
        // one user to the next on a shared device, pricing the free address as
        // "Included" for someone who has paid nothing. Re-read on the way back
        // in, which is also what makes a mid-session sign-in correct.
        .onChange(of: session.status) { _, status in
            switch status {
            case .signedOut:    mailStore.clearEntitlement()
            case .signedIn:     Task { await mailStore.refreshEntitlement() }
            case .bootstrapping: break
            }
        }
        .task {
            push.attach(api: api, session: session)
            // Attached here, with the other stores, because onboarding runs
            // BEFORE sign-in and its events must already be queueing. The
            // flush itself is gated on `session.status` inside `Analytics`.
            Analytics.shared.attach(api: api, session: session)
            // Registered BEFORE the sweep. `iap.attach` starts
            // `restorePurchases()` in a Task, so it cannot observe a handler
            // assigned in a LATER task — which is how the mail subscription's
            // recovery path was silently dead. Both stores register here,
            // synchronously, in the same task that starts the sweep.
            mailStore.attach(api: api)
            // 🔴 RESOLVED HERE, NOT IN THE DOMAIN SHEET. `isEntitled` starts
            // false and `EmailDomainSheet.task` was its only refresher, so on
            // every cold launch a PAYING subscriber's Home screen priced the
            // free address as "Subscription", in the paywall colour, until
            // they happened to open a sheet they had no reason to open. The
            // app told a customer to buy what they had already bought.
            //
            // Deliberately NOT awaited: this reads `Transaction.currentEntitlements`
            // locally and cold launch is already six sequential round-trips,
            // so it resolves long before the splash lifts without any
            // measurement lengthening the boot critical path.
            Task { await mailStore.refreshEntitlement() }
            // One shared `Transaction.updates` listener lives on `IAPStore`
            // (see `SubscriptionStore`'s note on why) — this registers the
            // e-mail subscription's handler on it rather than opening a second
            // one, which would split the stream and mean at most one listener
            // sees any given renewal.
            iap.onMailSubscription = { [weak mailStore] result in
                await mailStore?.submit(result) ?? false
            }
            iap.attach(api: api)
            // AFTER iap.attach, because this registers the subscription handler
            // on the single shared transaction listener that IAPStore owns.
            // Safe despite the sweep: `attach` only SCHEDULES it, so every
            // synchronous statement in this task runs first.
            subs.attach(api: api, iap: iap)
            // The real WebRTC client, which is what sets `isVoiceAvailable` and
            // makes the dialer reachable. Constructing it only opens a socket
            // when `prepareVoice()` mints a token, so a user with no line pays
            // nothing for it.
            calls.attach(api: api, voice: TelnyxVoiceClient())
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
