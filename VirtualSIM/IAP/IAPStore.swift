import Foundation
import StoreKit

@Observable
@MainActor
final class IAPStore {
    /// Loaded StoreKit products keyed by productId.
    var products: [String: Product] = [:]
    var isLoadingProducts = false
    var lastError: String?

    private var apiClient: APIClient?

    init() {
        // Listen for transactions that complete outside an active purchase
        // flow (interrupted, ask-to-buy, replayed on a new device, etc.).
        Task.detached { [weak self] in
            for await update in Transaction.updates {
                _ = await self?.handle(update)
            }
        }
    }

    func attach(api: APIClient) {
        self.apiClient = api
    }

    func loadProducts() async {
        if isLoadingProducts { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let fetched = try await Product.products(for: CreditPack.allProductIds)
            var map: [String: Product] = [:]
            for p in fetched { map[p.id] = p }
            self.products = map
        } catch {
            self.lastError = "Couldn't load products: \(error.localizedDescription)"
        }
    }

    /// Display price for a pack — uses real StoreKit price if loaded,
    /// else the static fallback from `CreditPack`.
    func displayPrice(_ pack: CreditPack) -> String {
        products[pack.productId]?.displayPrice ?? pack.price
    }

    /// Returns true if the purchase was accepted (verified on the server).
    /// Returns false if the user cancelled or the verification failed.
    func purchase(_ pack: CreditPack) async -> Bool {
        guard let product = products[pack.productId] else {
            lastError = "Product not loaded yet — try again in a moment."
            return false
        }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                return await handle(verification)
            case .userCancelled:
                return false
            case .pending:
                lastError = "Purchase is pending parental approval."
                return false
            @unknown default:
                return false
            }
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Server-verify the signed transaction. Returns true if accepted.
    private func handle(_ result: VerificationResult<Transaction>) async -> Bool {
        guard let api = apiClient else { return false }
        switch result {
        case .verified(let tx):
            let jws = result.jwsRepresentation
            do {
                let resp = try await IAPAPI(client: api).verify(jws: jws)
                if resp.ok {
                    await tx.finish()
                    return true
                }
                lastError = "Server rejected the transaction."
                return false
            } catch {
                lastError = error.localizedDescription
                return false
            }
        case .unverified(_, let error):
            lastError = "StoreKit could not verify: \(error.localizedDescription)"
            return false
        }
    }
}
