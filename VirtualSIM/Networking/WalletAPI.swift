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

    /// Claim today's free credit. Idempotent per UTC day server-side (advisory
    /// locked), so calling it on every launch and foreground is safe — the
    /// second call just comes back `granted: false`.
    func claimDailyCredit() async throws -> DailyCreditResult {
        try await client.request(.post, path: "rest/v1/rpc/claim_daily_credit")
    }
}

struct DailyCreditResult: Decodable {
    let granted: Bool
    let credits: Int?
    let streak: Int?
    let balance: Int?
    let reason: String?
}
