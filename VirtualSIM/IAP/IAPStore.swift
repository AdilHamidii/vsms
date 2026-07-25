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
            if fetched.isEmpty {
                self.lastError = "Credit packs are temporarily unavailable. Please try again in a moment."
            } else {
                self.lastError = nil
            }
        } catch {
            self.lastError = "Couldn't load credit packs. Please try again in a moment."
        }
    }

    /// Display price for a pack — uses real StoreKit price if loaded,
    /// else the static fallback from `CreditPack`.
    func displayPrice(_ pack: CreditPack) -> String {
        products[pack.productId]?.displayPrice ?? pack.price
    }

    /// Per-credit price for a pack, derived from the live StoreKit price so it
    /// always matches what the store actually charges (in the buyer's currency).
    /// Falls back to the static `CreditPack.perCredit` until the product loads.
    func perCredit(_ pack: CreditPack) -> String {
        guard let product = products[pack.productId], pack.credits > 0 else {
            return pack.perCredit
        }
        let per = product.price / Decimal(pack.credits)
        return "\(per.formatted(product.priceFormatStyle)) / cr"
    }

    /// Returns true if the purchase was accepted (verified on the server).
    /// Returns false if the user cancelled or the verification failed.
    func purchase(_ pack: CreditPack) async -> Bool {
        // If products haven't loaded yet (or returned empty), try once more
        // before giving up — covers the case where the sheet's .task is still
        // mid-fetch when the user taps Buy.
        if products[pack.productId] == nil {
            await loadProducts()
        }
        guard let product = products[pack.productId] else {
            // loadProducts already set a more specific lastError if it failed.
            if lastError == nil {
                lastError = "This credit pack isn't available right now. Please try again later."
            }
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

    /// Credits granted by the most recent accepted purchase, so the UI can
    /// confirm "+N credits" instead of silently closing the sheet.
    private(set) var lastGrantedCredits: Int?

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
                    // `ok` alone is NOT success. iap-verify deliberately
                    // returns ok:true with credits:0 / balanceChanged:false for
                    // Sandbox and Xcode receipts, so StoreKit stops
                    // redelivering them — they are genuine Apple-signed
                    // transactions that cost $0. Checking only `ok` meant every
                    // TestFlight tester "bought" a pack, the sheet closed as a
                    // success, the balance never moved, and nothing said why.
                    lastGrantedCredits = resp.credits
                    // alreadyCredited is a genuine success: StoreKit redelivers
                    // a receipt we already granted, so the balance legitimately
                    // does not move again.
                    if resp.balanceChanged != true && resp.alreadyCredited != true {
                        lastError = "That purchase was made in a test environment, so no credits were added."
                        return false
                    }
                    return true
                }
                lastError = "We couldn't confirm your purchase. Please try again."
                return false
            } catch let apiErr as APIError {
                lastError = apiErr.userMessage
                return false
            } catch {
                lastError = "We couldn't confirm your purchase. Please try again."
                return false
            }
        case .unverified:
            lastError = "We couldn't verify that purchase. Please try again."
            return false
        }
    }
}
