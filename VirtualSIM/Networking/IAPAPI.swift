import Foundation

struct IAPVerifyResult: Decodable {
    let ok: Bool
    let credits: Int?
    let alreadyCredited: Bool?
    let balanceChanged: Bool?
}

struct IAPAPI {
    let client: APIClient

    func verify(jws: String) async throws -> IAPVerifyResult {
        struct Body: Encodable { let jws: String }
        return try await client.request(
            .post,
            path: "functions/v1/iap-verify",
            body: Body(jws: jws)
        )
    }
}
