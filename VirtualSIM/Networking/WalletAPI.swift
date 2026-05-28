import Foundation

struct Wallet: Codable, Equatable {
    let userId: String
    let balance: Int
    let updatedAt: Date
}

struct WalletAPI {
    let client: APIClient

    func currentWallet() async throws -> Wallet {
        let rows: [Wallet] = try await client.request(
            .get,
            path: "rest/v1/wallets",
            query: [URLQueryItem(name: "select", value: "user_id,balance,updated_at")]
        )
        guard let w = rows.first else {
            throw APIError.http(status: 404, body: "wallet not found")
        }
        return w
    }
}
