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

    /// Which providers this account can sign in with, e.g. `["apple"]` or
    /// `["email"]`. Cached in the Keychain alongside the tokens so it survives
    /// a cold launch, since nothing re-reads the user until a refresh lands.
    var providers: [String] = []

    /// True when the account has a password to change. An Apple-only account
    /// does not, and offering the row would be a dead end.
    var isEmailUser: Bool { providers.contains("email") }

    /// The signed-in user's id, nil otherwise. For surfaces that want to
    /// mention the account without owning the status enum (the WhatsApp
    /// support prefill).
    var userId: String? {
        if case .signedIn(let id) = status { return id }
        return nil
    }

    private var refreshToken: String?
    private let api: APIClient
    private let auth: AuthAPI

    private enum KKey {
        static let refresh = "supabase.refresh_token"
        static let access  = "supabase.access_token"
        static let userId  = "supabase.user_id"
        static let email   = "supabase.email"
        static let providers = "supabase.providers"
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
            self.providers = (KeychainStore.get(KKey.providers) ?? "")
                .split(separator: ",").map(String.init)
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
        // Same non-nil discipline as `email` directly above, and for the same
        // reason: a response that simply omits `app_metadata` must not erase
        // what we already know. `/token?grant_type=refresh_token` is the one
        // that tends to omit it.
        if let list = session.user.appMetadata?.providers, !list.isEmpty {
            self.providers = list
            KeychainStore.set(list.joined(separator: ","), for: KKey.providers)
        } else if let single = session.user.appMetadata?.provider, !single.isEmpty {
            self.providers = [single]
            KeychainStore.set(single, for: KKey.providers)
        }
    }

    /// 🔴 ONLY A GENUINE CREDENTIAL REJECTION MAY DESTROY THE SESSION.
    ///
    /// This used to `catch` everything and call `signOut(remote: false)`, which
    /// nils both tokens and wipes all four Keychain keys. `bootstrap()` calls
    /// this on EVERY cold launch, and `auth.refresh` throws on transport
    /// failure (`URLError`), on any 5xx, and on a malformed body — so
    /// **launching the app with no network signed the user out.** No race and
    /// no expiry required; just being offline at the wrong moment.
    ///
    /// It also made a concurrent-refresh race destructive: GoTrue rotates the
    /// refresh token on use, so if two 401s each triggered a refresh, the loser
    /// failed and cleared the tokens the winner had just adopted.
    ///
    /// Only 400/401 from GoTrue means "this refresh token is no longer valid",
    /// which is the one case where signing out is the correct, honest outcome.
    /// Everything else is transient: keep the session and let the next request
    /// retry. A stale access token costs one failed call; a wrongly-cleared
    /// Keychain costs the user their session.
    @discardableResult
    func refresh() async -> Bool {
        guard let refreshToken else { return false }
        do {
            let s = try await auth.refresh(refreshToken: refreshToken)
            adopt(s)
            return true
        } catch let error as APIError {
            if case .http(let status, _) = error, status == 400 || status == 401 {
                await signOut(remote: false)
            }
            return false
        } catch {
            // URLError and anything else unexpected — transport, not identity.
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
        providers = []
        status = .signedOut
        KeychainStore.remove(KKey.access)
        KeychainStore.remove(KKey.refresh)
        KeychainStore.remove(KKey.userId)
        KeychainStore.remove(KKey.email)
        KeychainStore.remove(KKey.providers)
    }
}
