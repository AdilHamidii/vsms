import Foundation

struct AccountAPI {
    let client: APIClient

    func deleteAccount() async throws {
        let _: APIClient.Empty = try await client.request(
            .post,
            path: "functions/v1/delete-account",
            body: nil
        )
    }
}
