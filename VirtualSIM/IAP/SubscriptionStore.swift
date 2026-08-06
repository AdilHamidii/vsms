import Foundation
import StoreKit

/// The app's first auto-renewable subscription: the rented second number.
///
/// ── Why this is not part of `IAPStore` ────────────────────────────────────
///
/// `IAPStore` is a five-consumable machine whose `handle()` hardcodes
/// "verify → finish → set `lastGrantedCredits`". A subscription is an
/// *entitlement*, not a grant: nothing is credited, the server provisions a
/// physical resource instead, and "already processed" is the normal steady
/// state rather than an edge case. Folding the two together would reproduce
/// the `PurchaseIntent` bug class one layer down — a single code path silently
/// answering for whichever product happened to be set last.
///
/// ── But there is still exactly ONE `Transaction.updates` listener ─────────
///
/// `IAPStore.init` already claims that stream in a detached task, and
/// `Transaction.updates` is not multicast: a second `for await` over it would
/// split the stream, so each listener would see roughly half the transactions
/// and neither would know. This store therefore registers a handler WITH
/// `IAPStore` and never opens its own listener. See `IAPStore.onSubscription`.
///
/// ── Server state is the authority, always ────────────────────────────────
///
/// `Transaction.currentEntitlements` drives UI hints only. Whether a line
/// exists, and what state it is in, comes from `my_line` — the device can be
/// offline, restored from a backup, or simply wrong, and a number is a real
/// resource that costs money every month whatever StoreKit believes.
@Observable
@MainActor
final class SubscriptionStore {
    /// The MONTHLY plan. Every existing call site means this one.
    private(set) var product: Product?
    /// The YEARLY plan — $99.99 with a 3-day free trial, same subscription
    /// group. Held separately rather than in a list so the existing monthly
    /// call sites keep their meaning; the paywall reads both.
    private(set) var yearlyProduct: Product?

    /// The trial, straight from StoreKit rather than hardcoded. `nil` when the
    /// product has no introductory offer, or when this Apple ID is no longer
    /// eligible — Apple allows ONE introductory offer per subscription GROUP
    /// per Apple ID, so a user who trialled the monthly cannot trial the
    /// yearly. Reading it live is what stops the paywall promising a free trial
    /// to someone who will be charged immediately.
    var yearlyIntroOffer: Product.SubscriptionOffer? {
        yearlyProduct?.subscription?.introductoryOffer
    }
    private(set) var isLoadingProduct = false
    private(set) var isPurchasing = false
    var lastError: String?

    /// Set once a purchase has been verified AND the server has provisioned.
    /// The provisioning screen watches this to know the flow finished.
    private(set) var provisionedE164: String?

    private var apiClient: APIClient?

    /// What the client just bought, so the transaction handler — which may fire
    /// from the shared listener at any moment, including on a later launch —
    /// knows which number to provision. Nil means "we did not initiate this",
    /// which is the renewal case and is handled server-side by ASSN.
    private var pending: (phoneNumber: String, city: String, monthlyCents: Int?)?

    func attach(api: APIClient, iap: IAPStore) {
        self.apiClient = api
        // One listener, two products. See the class note.
        iap.onSubscription = { [weak self] result in
            await self?.handle(result) ?? false
        }
    }

    // MARK: - Product

    func loadProduct() async {
        if isLoadingProduct || product != nil { return }
        isLoadingProduct = true
        defer { isLoadingProduct = false }
        do {
            // Both plans in one call. `product` stays the MONTHLY so every
            // existing call site keeps its meaning; the yearly is exposed
            // alongside it for the paywall to offer.
            let fetched = try await Product.products(for: LineProduct.allIds)
            product = fetched.first { $0.id == LineProduct.monthlyId }
            yearlyProduct = fetched.first { $0.id == LineProduct.yearlyId }
            if product == nil {
                lastError = String(localized: "Second numbers are temporarily unavailable. Please try again in a moment.")
            }
        } catch {
            lastError = String(localized: "Couldn't load subscription details. Please try again in a moment.")
        }
    }

    /// The store's own price string, localized by StoreKit for the user's
    /// storefront. NEVER a hardcoded "$9.99": the credit-pack ladder drifted to
    /// $4.99-vs-€5.99 on its top revenue product precisely because prices were
    /// assumed rather than read.
    var displayPrice: String? { product?.displayPrice }

    // MARK: - Purchase

    /// Buy the subscription for a number that has already been reserved.
    ///
    /// The reservation happens BEFORE this, deliberately: everything that could
    /// refuse — Telnyx float, an existing line, a paused product — has to
    /// happen before Apple takes money, because an Apple refund is the one
    /// money path we cannot drive.
    func purchase(phoneNumber: String, city: String, monthlyCents: Int?) async -> Bool {
        guard !isPurchasing else { return false }
        guard let product else {
            lastError = String(localized: "Second numbers are temporarily unavailable. Please try again in a moment.")
            return false
        }
        isPurchasing = true
        pending = (phoneNumber, city, monthlyCents)
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                return await handle(verification)
            case .userCancelled:
                pending = nil
                return false
            case .pending:
                // Ask-to-buy or SCA. The transaction arrives later on the
                // shared listener, so this is not a failure — but it must not
                // read as success either.
                lastError = String(localized: "Your purchase needs approval. We'll set up your number as soon as it's approved.")
                return false
            @unknown default:
                pending = nil
                return false
            }
        } catch {
            pending = nil
            lastError = String(localized: "That purchase didn't complete. Please try again.")
            return false
        }
    }

    /// Verify with the server, then provision.
    ///
    /// ⚠️ `finish()` is called only when the server accepted the transaction.
    /// Finishing an unverified or failed one retires it forever — StoreKit
    /// stops redelivering, and a paid subscription with no number becomes
    /// unrecoverable without a manual refund. `iap-verify` has already been
    /// bitten by exactly this on the credits path.
    @discardableResult
    private func handle(_ result: VerificationResult<Transaction>) async -> Bool {
        guard let api = apiClient else { return false }
        guard case .verified(let tx) = result else {
            lastError = String(localized: "We couldn't verify that purchase. Please try again.")
            return false
        }
        // Not ours. The shared listener forwards everything, and a credit pack
        // reaching here would be sent to a function that refuses it.
        // `allIds`, not just the monthly: a yearly purchase reaching here and
        // being disowned would be forwarded to the credits path, which 400s it
        // as an unknown product on a transaction Apple has already charged.
        guard LineProduct.allIds.contains(tx.productID) else { return false }

        // A renewal, or a transaction replayed on a new device. There is no
        // number to provision — ASSN drives renewals server-side — so finish it
        // and let `loadLine` reflect whatever the server already knows.
        guard let want = pending else {
            await tx.finish()
            return true
        }

        do {
            let res = try await LineAPI(client: api).verifySubscription(
                signedTransaction: result.jwsRepresentation,
                phoneNumber: want.phoneNumber,
                city: want.city,
                monthlyCents: want.monthlyCents)
            guard res.ok else {
                lastError = String(localized: "Your subscription went through but we couldn't set the number up. Contact support, and don't buy again.")
                return false
            }
            await tx.finish()
            pending = nil
            provisionedE164 = res.e164
            return true
        } catch let apiErr as APIError {
            // Deliberately NOT finished. The transaction stays unfinished so
            // `IAPStore.restorePurchases()` sweeps it on the next launch and
            // the money is recoverable by construction rather than by a
            // support ticket.
            lastError = apiErr.userMessage
            return false
        } catch {
            lastError = String(localized: "Your subscription went through but we couldn't set the number up. It'll retry automatically.")
            return false
        }
    }

    func clearProvisioned() { provisionedE164 = nil }
}

/// One product id, in one place.
///
/// ⚠️ It must NEVER appear in `PRODUCT_TO_CREDITS` server-side — one entry
/// there pays out credits on every renewal, forever.
enum LineProduct {
    static let monthlyId = "com.anthersystems.VirtualSIM.line.monthly"
    /// $99.99/year with a 3-day free trial. SAME subscription group as the
    /// monthly (22289428), which is what makes them upgrade/downgrade siblings
    /// Apple prorates and stops a user holding both.
    static let yearlyId = "com.anthersystems.VirtualSIM.line.yearly"

    /// 🔴 EVERY product in the group. A subscription id missing from here is
    /// routed to the CREDITS path by `IAPStore.handle`, which sends it to
    /// `iap-verify`, which 400s it as `unknown_product` and pages the owner —
    /// for a purchase the user genuinely made and Apple genuinely charged.
    /// The server's `LINE_SUBSCRIPTION_PRODUCT_IDS` is the mirror of this list;
    /// they must move together.
    static let allIds = [monthlyId, yearlyId]

    /// The advertised monthly allowance, for the PRE-purchase paywall only.
    ///
    /// ⚠️ These mirror the `phone_lines` schema defaults (`sms_allowance 200`,
    /// `voice_allowance_seconds 6000`) and they are the ONLY copy in the client.
    /// They were previously inline literals on `LineCheckoutScreen`, which is
    /// the shape that has already burned this codebase twice — the "+3 credits"
    /// onboarding card that kept promising a grant after it went to zero, and
    /// `inviteJoinerCredits`, a client constant derived from a server value that
    /// silently became a 150% overstatement.
    ///
    /// Mirroring is only acceptable here because these change by MIGRATION, not
    /// by config: `app_config` can be edited without a release, a schema default
    /// cannot. That is the same test that made mirroring the referral bonus safe
    /// and mirroring the signup grant unsafe.
    ///
    /// **If you change either default, change it here in the same commit.**
    /// After purchase nothing reads these — `AllowanceStrip` reads the real
    /// values off the `Line` the server returns, which is always authoritative.
    static let smsAllowance = 200
    static let voiceAllowanceMinutes = 100
}
