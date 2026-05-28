import Foundation

struct PushAPI {
    let client: APIClient

    func register(token: String, environment: String, bundleId: String) async throws {
        struct Body: Encodable {
            let token: String
            let environment: String
            let bundle_id: String
        }
        let _: APIClient.Empty = try await client.request(
            .post,
            path: "functions/v1/register-push",
            body: Body(token: token, environment: environment, bundle_id: bundleId)
        )
    }
}
