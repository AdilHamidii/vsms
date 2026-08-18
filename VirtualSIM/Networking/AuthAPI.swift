import Foundation

struct SupabaseSession: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let user: SupabaseUser
}

struct SupabaseUser: Codable {
    let id: String
    let email: String?
    /// Which providers this identity can sign in with. GoTrue puts it in
    /// `app_metadata`; `.convertFromSnakeCase` does the rest.
    ///
    /// Read for exactly one purpose: the Account screen offers "Change
    /// password" only to an email user. An Apple-only account has no password
    /// to change, and showing the row would be a dead end.
    let appMetadata: AppMetadata?

    struct AppMetadata: Codable {
        let provider: String?
        let providers: [String]?
    }
}

/// What `POST /auth/v1/signup` returns when confirmations are on: a user, and
/// no session, because the address has not been proven yet.
struct SignUpResult: Codable {
    let id: String?
    let email: String?
    /// 🔴 EMPTY MEANS "THIS ADDRESS ALREADY HAS A CONFIRMED ACCOUNT", and the
    /// UI must NOT branch on it.
    ///
    /// GoTrue's enumeration protection answers a repeat signup with **200 and a
    /// sanitized user** — a random id, nulled timestamps and no identities —
    /// rather than an error, so that an attacker cannot use this endpoint to
    /// discover who has an account. Branching on it here would hand that
    /// oracle straight back. It is decoded only so a DEBUG build can log it.
    let identities: [Identity]?

    struct Identity: Codable { let id: String? }
}

struct AuthAPI {
    let client: APIClient

    /// Exchanges an Apple identity token for a Supabase session.
    /// `nonce` must be the *raw* nonce whose SHA256 was passed to Apple.
    func signInWithApple(idToken: String, nonce: String) async throws -> SupabaseSession {
        struct Body: Encodable {
            let provider: String
            let id_token: String
            let nonce: String
        }
        let body = Body(provider: "apple", id_token: idToken, nonce: nonce)
        return try await client.request(
            .post,
            path: "auth/v1/token",
            query: [URLQueryItem(name: "grant_type", value: "id_token")],
            body: body,
            authenticated: false
        )
    }

    // MARK: - Email + password
    //
    // ⚠️ EVERY FIELD NAME HERE IS WRITTEN IN snake_case BY HAND, matching
    // `signInWithApple` above. `JSONEncoder.relay` applies
    // `.convertToSnakeCase`, so a camelCase property would be mangled a second
    // time — `idToken` would go out as `id_token` correctly, but
    // `currentPassword` would become `current_password` only by luck of the
    // same rule. Writing the wire name literally removes the question.

    /// Creates an account. With confirmations on this returns a user and **no
    /// session** — the caller must send the user to the code screen.
    func signUp(email: String, password: String) async throws -> SignUpResult {
        struct Body: Encodable { let email: String; let password: String }
        return try await client.request(
            .post, path: "auth/v1/signup",
            body: Body(email: email, password: password),
            authenticated: false)
    }

    func signIn(email: String, password: String) async throws -> SupabaseSession {
        struct Body: Encodable { let email: String; let password: String }
        return try await client.request(
            .post, path: "auth/v1/token",
            query: [URLQueryItem(name: "grant_type", value: "password")],
            body: Body(email: email, password: password),
            authenticated: false)
    }

    /// Exchanges a 6-digit e-mail code for a session.
    ///
    /// `type` is `"signup"` when confirming a new account and `"recovery"`
    /// when resetting a password — the two are separate token columns on
    /// GoTrue's side, so the wrong one simply fails to match. Do not pass
    /// `"email"`: it is accepted but ambiguous, resolving to signup OR
    /// magiclink depending on which token happens to be set.
    func verifyEmailCode(email: String, token: String, type: String) async throws -> SupabaseSession {
        struct Body: Encodable { let type: String; let token: String; let email: String }
        return try await client.request(
            .post, path: "auth/v1/verify",
            body: Body(type: type, token: token, email: email),
            authenticated: false)
    }

    /// Sends a fresh confirmation code.
    func resendSignupCode(email: String) async throws {
        struct Body: Encodable { let type: String; let email: String }
        _ = try await client.rawRequest(
            .post, path: "auth/v1/resend",
            body: Body(type: "signup", email: email),
            authenticated: false)
    }

    /// Starts a password reset. Always answers 200, whether or not the address
    /// exists — do not surface anything that distinguishes the two.
    func requestPasswordReset(email: String) async throws {
        struct Body: Encodable { let email: String }
        _ = try await client.rawRequest(
            .post, path: "auth/v1/recover",
            body: Body(email: email),
            authenticated: false)
    }

    /// Sets a new password.
    ///
    /// `overrideToken` carries the recovery session during a reset (see
    /// `APIClient`); it is nil for a signed-in user changing their password,
    /// where the live session is used instead.
    ///
    /// `current_password` is sent whenever we have it: GoTrue ignores it unless
    /// "secure password change" is enabled in the dashboard, and requires it
    /// when it is — so sending it makes this correct under either setting
    /// rather than depending on one nobody will remember to check.
    @discardableResult
    func updatePassword(newPassword: String,
                        currentPassword: String? = nil,
                        overrideToken: String? = nil) async throws -> SupabaseUser {
        struct Body: Encodable {
            let password: String
            let current_password: String?
        }
        return try await client.request(
            .put, path: "auth/v1/user",
            body: Body(password: newPassword, current_password: currentPassword),
            authenticated: overrideToken == nil,
            overrideToken: overrideToken)
    }

    func refresh(refreshToken: String) async throws -> SupabaseSession {
        struct Body: Encodable { let refresh_token: String }
        return try await client.request(
            .post,
            path: "auth/v1/token",
            query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
            body: Body(refresh_token: refreshToken),
            authenticated: false
        )
    }

    func signOut(accessToken: String) async throws {
        // Best-effort logout — server invalidates the token.
        _ = try? await client.rawRequest(
            .post,
            path: "auth/v1/logout",
            authenticated: true
        )
    }
}
