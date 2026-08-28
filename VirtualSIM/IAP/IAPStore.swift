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
        // A structural check with no caller is not a check. Debug-only, and it
        // runs before the paywall can ever be shown.
        CreditPack.assertLadderImproves()

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
        // Sweep transactions that arrived BEFORE the API client existed.
        // `Transaction.updates` starts listening in init(), but attach() runs
        // later from AuthGate — so an update landing in that window hit
        // `guard let api = apiClient` and was dropped for the whole launch.
        Task { await restorePurchases() }
    }

    /// Re-verify every unfinished transaction.
    ///
    /// Consumables don't need StoreKit "restore", but a purchase whose
    /// verification failed had NO user-triggerable recovery at all: the
    /// backend paged the owner and the user's only route was email. This is
    /// both the automatic sweep and the manual Account button.
    /// Returns the number of transactions successfully credited.
    @discardableResult
    func restorePurchases() async -> Int {
        guard apiClient != nil else { return 0 }
        isRestoring = true
        defer { isRestoring = false }
        var credited = 0
        for await result in Transaction.unfinished {
            if await handle(result) { credited += 1 }
        }
        return credited
    }

    private(set) var isRestoring = false

    func loadProducts() async {
        #if DEBUG
        // The shim already answers for every pack. Letting the real fetch run
        // would find no products (`simctl` applies no StoreKit configuration),
        // set `lastError`, and put "Credit packs are temporarily unavailable"
        // into a frame whose whole purpose is showing the packs.
        if screenshotPricing != nil { return }
        #endif
        if isLoadingProducts { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let fetched = try await Product.products(for: CreditPack.allProductIds)
            var map: [String: Product] = [:]
            for p in fetched { map[p.id] = p }
            self.products = map
            if fetched.isEmpty {
                self.lastError = String(localized: "Credit packs are temporarily unavailable. Please try again in a moment.")
            } else {
                self.lastError = nil
            }
        } catch {
            self.lastError = String(localized: "Couldn't load credit packs. Please try again in a moment.")
        }
    }

    #if DEBUG
    /// Display prices keyed by productId, non-nil ONLY under `ScreenshotMode`.
    ///
    /// Xcode applies `Products.storekit` when Xcode itself launches the app;
    /// `simctl` does not, so a scripted screenshot run loads no products and
    /// every row of the ladder renders "Unavailable" over a disabled CTA. That
    /// is the same failure that put the paywall's error state into App Store
    /// Connect as a review screenshot — see `SubscriptionStore.ScreenshotPricing`.
    ///
    /// ⚠️ **These are not placeholder strings.** The frame becomes an App Store
    /// review screenshot for the credit packs, so every figure has to equal what
    /// the store will really charge. They are set at the call site from the live
    /// App Store Connect tiers, which `Products.storekit` and
    /// `CreditPack.priceUsd` are kept in step with by hand. If a price moves in
    /// ASC, it moves in all three.
    ///
    /// Per-credit needs no shim: it falls through to `CreditPack.perCredit`,
    /// derived from the same `priceUsd` those tiers are mirrored into.
    ///
    /// The whole thing is `#if DEBUG`, so a Release archive cannot be put into
    /// this state by any launch argument or server response.
    var screenshotPricing: [String: String]?
    #endif

    /// Has StoreKit answered at all? Distinct from "this pack is missing":
    /// until it has, a missing product means "still loading". Every consumer
    /// goes through this rather than `products.isEmpty`, so the screenshot
    /// harness has ONE place to substitute into.
    var hasLoadedProducts: Bool {
        #if DEBUG
        if screenshotPricing != nil { return true }
        #endif
        return !products.isEmpty
    }

    /// Is there something to sell for this pack? False once loading has
    /// finished means the row degrades — or, for an `optional` pack, drops out.
    func has(_ pack: CreditPack) -> Bool {
        #if DEBUG
        if let s = screenshotPricing { return s[pack.productId] != nil }
        #endif
        return products[pack.productId] != nil
    }

    /// Display price for a pack — uses real StoreKit price if loaded,
    /// else the static fallback from `CreditPack`.
    func displayPrice(_ pack: CreditPack) -> String {
        #if DEBUG
        if let s = screenshotPricing, let p = s[pack.productId] { return p }
        #endif
        return products[pack.productId]?.displayPrice ?? pack.price
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
        // 🔴 THE PREVIOUS ATTEMPT'S ERROR IS NOT THIS ATTEMPT'S. Nothing
        // cleared it, so failing a purchase, dismissing the sheet and
        // reopening it pinned the error card under the CTA before the user had
        // touched anything — and cancelling Apple's own sheet then re-fired
        // the warning haptic for a failure that was already over. Cleared
        // BEFORE `loadProducts`, which sets its own more specific message that
        // the guard below depends on finding.
        lastError = nil
        // If products haven't loaded yet (or returned empty), try once more
        // before giving up — covers the case where the sheet's .task is still
        // mid-fetch when the user taps Buy.
        if products[pack.productId] == nil {
            await loadProducts()
        }
        guard let product = products[pack.productId] else {
            Analytics.shared.track("purchase_result", [
                "product": .string(pack.productId), "outcome": "failed"])
            // loadProducts already set a more specific lastError if it failed.
            if lastError == nil {
                lastError = String(localized: "This credit pack isn't available right now. Please try again later.")
            }
            return false
        }
        // `outcome` is taken from StoreKit's own result, never inferred from
        // the Bool this function returns: `.userCancelled` and a rejected
        // receipt both return false, and telling them apart is the one signal
        // this product has never had.
        func note(_ outcome: String) {
            Analytics.shared.track("purchase_result", [
                "product": .string(pack.productId), "outcome": .string(outcome)])
        }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let accepted = await handle(verification)
                note(accepted ? "success" : "failed")
                // A purchase that went through leaves no error behind, even if
                // the shared transaction listener set one meanwhile.
                if accepted { lastError = nil }
                return accepted
            case .userCancelled:
                note("cancelled")
                return false
            case .pending:
                note("pending")
                lastError = String(localized: "Purchase is pending parental approval.")
                return false
            @unknown default:
                note("failed")
                return false
            }
        } catch {
            note("failed")
            lastError = error.localizedDescription
            return false
        }
    }

    /// Credits granted by the most recent accepted purchase, so the UI can
    /// confirm "+N credits" instead of silently closing the sheet.
    private(set) var lastGrantedCredits: Int?

    /// Subscription transactions are forwarded here rather than to a second
    /// `Transaction.updates` listener.
    ///
    /// `Transaction.updates` is NOT multicast: a second `for await` over it
    /// splits the stream, so two listeners would each see roughly half the
    /// transactions and neither would know it. `SubscriptionStore.attach` sets
    /// this; nothing else may open a listener.
    var onSubscription: ((VerificationResult<Transaction>) async -> Bool)?

    /// Mail-subscription transactions are forwarded here for the same reason:
    /// `MailSubscriptionStore.attach` sets this, and nothing else may open a
    /// second `Transaction.updates` listener.
    var onMailSubscription: ((VerificationResult<Transaction>) async -> Bool)?

    /// Server-verify the signed transaction. Returns true if accepted.
    private func handle(_ result: VerificationResult<Transaction>) async -> Bool {
        guard let api = apiClient else { return false }

        // Dispatch by product BEFORE the credits path. `iap-verify` returns 400
        // `unknown_product` for anything not in PRODUCT_TO_CREDITS *and pages
        // the owner*, so a renewal falling through to it would page on every
        // renewal forever and 400 a legitimate transaction.
        if case .verified(let tx) = result, LineProduct.allIds.contains(tx.productID) {
            return await onSubscription?(result) ?? false
        }

        if case .verified(let tx) = result, MailProduct.allIds.contains(tx.productID) {
            return await onMailSubscription?(result) ?? false
        }

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
                        lastError = String(localized: "That purchase was made in a test environment, so no credits were added.")
                        return false
                    }
                    return true
                }
                lastError = String(localized: "We couldn't confirm your purchase. Please try again.")
                return false
            } catch let apiErr as APIError {
                lastError = apiErr.userMessage
                return false
            } catch {
                lastError = String(localized: "We couldn't confirm your purchase. Please try again.")
                return false
            }
        case .unverified:
            lastError = String(localized: "We couldn't verify that purchase. Please try again.")
            return false
        }
    }
}
