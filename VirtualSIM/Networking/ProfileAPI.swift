import Foundation

struct Profile: Codable, Hashable {
    let userId: String
    let displayName: String?
    let createdAt: Date
}

struct ProfileAPI {
    let client: APIClient

    func currentProfile() async throws -> Profile {
        let rows: [Profile] = try await client.request(
            .get,
            path: "rest/v1/profiles",
            query: [URLQueryItem(name: "select", value: "user_id,display_name,created_at")]
        )
        guard let p = rows.first else {
            throw APIError.http(status: 404, body: "profile not found")
        }
        return p
    }
}
