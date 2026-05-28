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
