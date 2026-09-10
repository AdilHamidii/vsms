import Foundation

struct Profile: Codable, Hashable {
    let userId: String
    let displayName: String?
    let createdAt: Date
    let referralCode: String?
    let referredBy: String?
}

struct ProfileAPI {
    let client: APIClient

    func currentProfile() async throws -> Profile {
        let rows: [Profile] = try await client.request(
            .get,
            path: "rest/v1/profiles",
            query: [URLQueryItem(name: "select", value: "user_id,display_name,created_at,referral_code,referred_by")]
        )
        guard let p = rows.first else {
            throw APIError.http(status: 404, body: "profile not found")
        }
        return p
    }

    /// Rename the signed-in user.
    ///
    /// `display_name` is the ONLY column the client holds `update` on —
    /// `profiles` is otherwise read-only to it, which is what stops a user
    /// PATCHing their own `referred_by` and farming the referral grant. So the
    /// body carries that one key and nothing else, and the row is addressed by
    /// `user_id=eq.` because RLS filters ROWS, not statements: an unfiltered
    /// PATCH would be a table-wide UPDATE that RLS narrows silently.
    ///
    /// Decoded as `APIClient.Empty`: PostgREST answers a PATCH with 204 and no
    /// body unless asked for a representation, and `APIClient` has no hook for
    /// a `Prefer` header. The caller re-derives the new name locally.
    func updateDisplayName(_ name: String, userId: String) async throws {
        struct Body: Encodable { let display_name: String }
        let _: APIClient.Empty = try await client.request(
            .patch,
            path: "rest/v1/profiles",
            query: [URLQueryItem(name: "user_id", value: "eq.\(userId)")],
            body: Body(display_name: name)
        )
    }

    /// Attach an inviter by code. Returns the server status:
    /// ok | already_referred | invalid_code | self.
    @discardableResult
    func redeemReferral(code: String) async throws -> String {
        struct Body: Encodable { let code: String }
        struct Result: Decodable { let ok: Bool; let status: String }
        let r: Result = try await client.request(
            .post, path: "functions/v1/redeem-referral",
            body: Body(code: code)
        )
        return r.status
    }
}
