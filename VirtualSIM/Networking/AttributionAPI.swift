import Foundation

/// Apple Search Ads attribution. The client only ever hands the opaque
/// AdServices token to our server — resolving it against Apple's endpoint
/// needs no auth, but doing it server-side is what lets the result be joined
/// to purchases, which is the entire point of the feature.
///
/// Fire-and-forget by design: the response is decoded as `APIClient.Empty`, so
/// there is no client-side contract to break if the endpoint's body ever
/// changes (see CLAUDE.md — a snake_case property name is a decode FAILURE).
struct AttributionAPI {
    let client: APIClient

    func submit(token: String) async throws {
        struct Body: Encodable { let token: String }
        let _: APIClient.Empty = try await client.request(
            .post,
            path: "functions/v1/record-attribution",
            body: Body(token: token)
        )
    }
}
