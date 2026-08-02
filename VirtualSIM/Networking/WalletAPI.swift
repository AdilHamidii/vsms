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

    // The daily-credit RPCs were removed from the client 2026-08-02 (feature
    // disabled server-side 2026-08-01, then removed). The no-op DB functions
    // survive only for 1.6/1.7 builds.
}
