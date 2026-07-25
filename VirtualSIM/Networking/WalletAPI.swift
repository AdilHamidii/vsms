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

    /// Is today's credit still unclaimed, and what is it worth?
    /// Side-effect free — this only OFFERS the claim. Never infer availability
    /// by attempting a claim; the claim is the user's explicit tap.
    func dailyCreditStatus() async throws -> DailyCreditStatus {
        try await client.request(.post, path: "rest/v1/rpc/daily_credit_status")
    }

    /// Claim today's credit. Advisory-locked and idempotent per UTC day, so a
    /// double-tap cannot pay twice — the second call returns granted:false.
    func claimDailyCredit() async throws -> DailyCreditResult {
        try await client.request(.post, path: "rest/v1/rpc/claim_daily_credit")
    }
}

struct DailyCreditStatus: Decodable {
    let available: Bool
    /// What claiming right now would grant, at the streak tier it would land on.
    let credits: Int?
    let streak: Int?
    /// Set when already claimed: what tomorrow is worth.
    let nextCredits: Int?
}

struct DailyCreditResult: Decodable {
    let granted: Bool
    let credits: Int?
    let streak: Int?
    let balance: Int?
    let reason: String?
    /// What tomorrow's claim is worth at the next streak tier (1-2 -> 1,
    /// 3-9 -> 2, 10+ -> 3). Server-computed so the ladder lives in one place.
    let nextCredits: Int?
}
