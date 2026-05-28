import Foundation

@Observable
final class Session {
    enum Status: Equatable {
        case bootstrapping
        case signedOut
        case signedIn(userId: String)
    }

    var status: Status = .bootstrapping
    var accessToken: String?

    private var refreshToken: String?
    private let api: APIClient
    private let auth: AuthAPI

    private enum KKey {
        static let refresh = "supabase.refresh_token"
        static let access  = "supabase.access_token"
        static let userId  = "supabase.user_id"
    }

    init(api: APIClient) {
        self.api = api
        self.auth = AuthAPI(client: api)
        api.attach(self)
    }

    func bootstrap() async {
        if let access = KeychainStore.get(KKey.access),
           let refresh = KeychainStore.get(KKey.refresh),
           let userId  = KeychainStore.get(KKey.userId) {
            self.accessToken = access
            self.refreshToken = refresh
            self.status = .signedIn(userId: userId)
            // Try refresh once on boot so tokens are fresh.
            _ = await self.refresh()
        } else {
            self.status = .signedOut
        }
    }

    func adopt(_ session: SupabaseSession) {
        self.accessToken = session.accessToken
        self.refreshToken = session.refreshToken
        self.status = .signedIn(userId: session.user.id)
        KeychainStore.set(session.accessToken,  for: KKey.access)
        KeychainStore.set(session.refreshToken, for: KKey.refresh)
        KeychainStore.set(session.user.id,      for: KKey.userId)
    }

    @discardableResult
    func refresh() async -> Bool {
        guard let refreshToken else { return false }
        do {
            let s = try await auth.refresh(refreshToken: refreshToken)
            adopt(s)
            return true
        } catch {
            await signOut(remote: false)
            return false
        }
    }

    func signOut(remote: Bool = true) async {
        if remote, let token = accessToken {
            try? await auth.signOut(accessToken: token)
        }
        accessToken = nil
        refreshToken = nil
        status = .signedOut
        KeychainStore.remove(KKey.access)
        KeychainStore.remove(KKey.refresh)
        KeychainStore.remove(KKey.userId)
    }
}
