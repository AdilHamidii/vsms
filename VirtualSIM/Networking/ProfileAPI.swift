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
