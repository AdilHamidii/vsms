import SwiftUI

struct AuthGate: View {
    @State private var api = APIClient()
    @State private var session: Session
    @State private var push = PushManager()
    @State private var iap = IAPStore()
    @AppStorage("onboardingComplete") private var onboardingComplete = false

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
                        await push.requestAuthorizationAndRegister()
                    }
            }
        }
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
