import SwiftUI

struct AuthGate: View {
    @State private var api = APIClient()
    @State private var session: Session

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
                SignInScreen()
            case .signedIn:
                ContentView()
            }
        }
        .environment(api)
        .environment(session)
        .task {
            await session.bootstrap()
        }
    }
}

private struct BootstrapScreen: View {
    @Environment(\.theme) private var theme
    var body: some View {
        ZStack {
            (theme.bg).ignoresSafeArea()
            ProgressView()
                .controlSize(.large)
                .tint(theme.text2)
        }
    }
}
