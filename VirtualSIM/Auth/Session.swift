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
    var email: String?

    private var refreshToken: String?
    private let api: APIClient
    private let auth: AuthAPI

    private enum KKey {
        static let refresh = "supabase.refresh_token"
        static let access  = "supabase.access_token"
        static let userId  = "supabase.user_id"
        static let email   = "supabase.email"
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
            self.email = KeychainStore.get(KKey.email)
            self.status = .signedIn(userId: userId)
            _ = await self.refresh()
        } else {
            self.status = .signedOut
        }
    }

    func adopt(_ session: SupabaseSession) {
        self.accessToken = session.accessToken
        self.refreshToken = session.refreshToken
        self.email = session.user.email
        self.status = .signedIn(userId: session.user.id)
        KeychainStore.set(session.accessToken,  for: KKey.access)
        KeychainStore.set(session.refreshToken, for: KKey.refresh)
        KeychainStore.set(session.user.id,      for: KKey.userId)
        if let email = session.user.email {
            KeychainStore.set(email, for: KKey.email)
        }
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
        email = nil
        status = .signedOut
        KeychainStore.remove(KKey.access)
        KeychainStore.remove(KKey.refresh)
        KeychainStore.remove(KKey.userId)
        KeychainStore.remove(KKey.email)
    }
}
