import Foundation
import StoreKit

/// One product id, in one place.
///
/// ⚠️ These must NEVER appear in `PRODUCT_TO_CREDITS` server-side — one entry
/// there pays out wallet credits on every renewal, forever.
enum MailProduct {
    static let monthlyId = "com.anthersystems.VirtualSIM.mail.monthly"
    /// $29.99/year with a 3-day free trial.
    static let yearlyId = "com.anthersystems.VirtualSIM.mail.yearly"

    /// 🔴 EVERY product in the group. An id missing from here is routed to the
    /// CREDITS path by `IAPStore.handle`, which sends it to `iap-verify`, which
    /// 400s it as `unknown_product` and pages the owner — for a purchase the
    /// user genuinely made and Apple genuinely charged. The server's
    /// `MAIL_SUBSCRIPTION_PRODUCT_IDS` is the mirror of this list; they must
    /// move together.
    static let allIds = [monthlyId, yearlyId]

    /// How many addresses a subscriber may take per UTC day.
    ///
    /// 🔴 MIRRORS `app_config.email_sub_daily_cap` (seeded 25 in
    /// `20260818160001_email_subscriptions.sql`). The two must move together:
    /// this number is rendered on the paywall as a promise, and the server is
    /// what actually refuses with `daily_cap_reached`. A client that promises
    /// more than the server allows is App Store 2.3.1 (accurate metadata) —
    /// which is exactly why the paywall no longer says "unlimited".
    ///
    /// It is quoted in EXACTLY ONE user-facing string (`MailPaywallScreen`'s
    /// intro). Every other surface states that a daily limit exists without
    /// naming a figure, so a server-side change to the cap falsifies one
    /// sentence rather than five.
    static let dailyAddressCap = 25
}

/// Which plan the paywall is offering.
///
/// A SEPARATE App Store subscription group from the line. Apple allows one
/// active subscription per group, so putting these in the line group would make
/// buying e-mail replace a subscriber's phone number — and a user may
/// legitimately hold both a line and a mail subscription.
enum MailPlan: String, CaseIterable, Identifiable {
    case monthly
    case yearly

    var id: String { rawValue }
}

/// The e-mail subscription: addresses on the free domains, up to a daily cap.
///
/// ── Server state is the authority ────────────────────────────────────────
///
/// `Transaction.currentEntitlements` drives UI hints only. Whether an order is
/// allowed is decided by `begin_email_order` in SQL — the device can be
/// offline, restored from a backup, or simply wrong, and an entitlement the
/// device asserts is an entitlement an attacker can assert.
///
/// ── There is still exactly ONE `Transaction.updates` listener ────────────
///
/// `IAPStore.init` claims that stream and `Transaction.updates` is not
/// multicast, so a second `for await` would split it and each listener would
/// see roughly half the transactions. This store registers a handler with
/// `IAPStore` and never opens its own.
@Observable
@MainActor
final class MailSubscriptionStore {
    /// Monthly by default: the lower commitment. Defaulting to the expensive
    /// option is a dark pattern.
    var selectedPlan: MailPlan = .monthly

    private(set) var products: [Product] = []
    /// A UI hint only — never a gate. The server decides.
    private(set) var isEntitled = false
    private(set) var isPurchasing = false
    var lastError: String?

    private var apiClient: APIClient?

    #if DEBUG
    /// Prices for the App Store screenshot harness.
    ///
    /// Xcode applies `Products.storekit` when Xcode itself launches the app;
    /// `simctl` does not, so a scripted screenshot run loads no products at all
    /// and `MailPaywallScreen` renders "The App Store isn't offering this
    /// subscription right now" with no plan rows and no CTA under it. That
    /// exact frame has already been uploaded to App Store Connect once as a
    /// subscription's review screenshot — a reviewer opened it and saw an
    /// error instead of a purchase screen.
    /// `SubscriptionStore.ScreenshotPricing` exists for the line paywall for
    /// precisely the same reason; this is its e-mail twin.
    ///
    /// ⚠️ **These are not placeholder strings.** The frame BECOMES an App
    /// Store review screenshot, so every figure has to equal what the store
    /// will really charge. They mirror `Products.storekit`, which is itself
    /// kept in step with App Store Connect by hand. If a price moves in ASC,
    /// it moves in all three.
    ///
    /// The whole thing is `#if DEBUG`, so a Release archive cannot be put into
    /// this state by any launch argument or server response — the same
    /// guarantee `ScreenshotMode` documents for its sample data.
    struct ScreenshotPricing {
        var monthly = "$2.99"
        var yearly = "$29.99"
        /// ($2.99 × 12 − $29.99) ÷ ($2.99 × 12) = 16.4% → 16, which is what
        /// `yearlySavingsPercent` computes from the live prices.
        var savingsPercent = 16
        var trial = "3 days"
    }

    /// Non-nil ONLY under `ScreenshotMode`. Every read of it is behind
    /// `#if DEBUG`, so this is inert in a shipping build.
    var screenshotPricing: ScreenshotPricing?
    #endif

    func attach(api: APIClient) { self.apiClient = api }

    func product(for plan: MailPlan) -> Product? {
        let id = plan == .monthly ? MailProduct.monthlyId : MailProduct.yearlyId
        return products.first { $0.id == id }
    }

    /// Whether the paywall has anything to offer. The screen gates its plan
    /// picker, price block and CTA on THIS rather than on `products` directly,
    /// so the screenshot shim has exactly one place to answer from and the
    /// three gates cannot disagree with each other.
    var hasProducts: Bool {
        #if DEBUG
        if screenshotPricing != nil { return true }
        #endif
        return !products.isEmpty
    }

    /// The store's own price string, localized by StoreKit for the user's
    /// storefront. Never hardcoded outside the DEBUG shim: the credit-pack
    /// ladder drifted to $4.99-vs-€5.99 on its top revenue product precisely
    /// because a price was assumed rather than read.
    func displayPrice(for plan: MailPlan) -> String? {
        #if DEBUG
        if let s = screenshotPricing { return plan == .yearly ? s.yearly : s.monthly }
        #endif
        return product(for: plan)?.displayPrice
    }

    /// Yearly saving against twelve monthly payments, computed from the LIVE
    /// StoreKit prices in the user's own currency. The two prices are set
    /// independently in App Store Connect and per territory, so a percentage
    /// written into the app is a claim that goes wrong silently the first time
    /// either one moves.
    var yearlySavingsPercent: Int? {
        #if DEBUG
        if let s = screenshotPricing { return s.savingsPercent }
        #endif
        guard let m = product(for: .monthly)?.price,
              let y = product(for: .yearly)?.price, m > 0 else { return nil }
        let twelve = m * 12
        guard twelve > y else { return nil }
        let pct = ((twelve - y) / twelve) * 100
        return max(1, Int((pct as NSDecimalNumber).doubleValue.rounded()))
    }

    /// "3 days" — or nil when there is no trial to promise.
    ///
    /// 🔴 nil is the important case and it is NOT an error. Apple grants one
    /// introductory offer per subscription GROUP per Apple ID, so someone who
    /// already trialled the monthly gets nothing here and StoreKit reports no
    /// offer. Every trial claim on the paywall hangs off this, so an ineligible
    /// user is never shown "3 days free" and then charged immediately — which
    /// is a refund, a one-star review, and an App Store 3.1.2 problem.
    var yearlyTrialLabel: String? {
        #if DEBUG
        if let s = screenshotPricing { return s.trial }
        #endif
        guard let offer = product(for: .yearly)?.subscription?.introductoryOffer,
              offer.paymentMode == .freeTrial else { return nil }
        let n = offer.period.value
        switch offer.period.unit {
        case .day:   return n == 1 ? String(localized: "1 day")   : String(localized: "\(n) days")
        case .week:  return n == 1 ? String(localized: "1 week")  : String(localized: "\(n) weeks")
        case .month: return n == 1 ? String(localized: "1 month") : String(localized: "\(n) months")
        case .year:  return n == 1 ? String(localized: "1 year")  : String(localized: "\(n) years")
        @unknown default: return nil
        }
    }

    func load() async {
        #if DEBUG
        // The harness supplies every figure this screen renders. A real
        // `Product.products(for:)` here would come back empty under `simctl`
        // and could write `lastError` across the top of the frame.
        if screenshotPricing != nil { return }
        #endif
        do {
            products = try await Product.products(for: MailProduct.allIds)
        } catch {
            // A load failure is not "you are not subscribed" — leave the hint
            // untouched and let the paywall say the store is unreachable.
            lastError = String(localized: "The App Store isn't reachable right now.")
        }
        await refreshEntitlement()
    }

    /// Forget the entitlement when the ACCOUNT changes.
    ///
    /// 🔴 This store is owned by `AuthGate`, so it outlives a sign-out — and
    /// `isEntitled` is a per-ACCOUNT claim rendered as a price ("Included") on
    /// Home. Without this, user A's entitlement stayed true for user B on the
    /// same device until something happened to refresh it, telling a stranger
    /// their addresses were paid for. The server refuses either way; the screen
    /// was the thing that lied.
    func clearEntitlement() { isEntitled = false }

    func refreshEntitlement() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let tx) = result, MailProduct.allIds.contains(tx.productID) {
                isEntitled = true
                return
            }
        }
        isEntitled = false
    }

    func purchase() async -> Bool {
        guard !isPurchasing, let product = product(for: selectedPlan) else { return false }
        isPurchasing = true
        defer { isPurchasing = false }
        lastError = nil
        do {
            switch try await product.purchase() {
            case .success(let verification):
                return await submit(verification)
            case .userCancelled:
                return false
            case .pending:
                lastError = String(localized: "That purchase is waiting for approval.")
                return false
            @unknown default:
                return false
            }
        } catch {
            lastError = String(localized: "That purchase didn't go through.")
            return false
        }
    }

    /// Send the signed transaction to the server, which is what actually grants
    /// the entitlement. `finish()` only after the server has recorded it —
    /// finishing first retires the transaction forever and a failed record
    /// would leave a paying user with nothing.
    func submit(_ result: VerificationResult<Transaction>) async -> Bool {
        guard case .verified(let tx) = result, let api = apiClient else { return false }
        guard let jws = jwsRepresentation(of: result) else { return false }
        do {
            try await EmailAPI(client: api).verifyMailSubscription(signedTransaction: jws)
            await tx.finish()
            isEntitled = true
            return true
        } catch {
            lastError = (error as? APIError)?.userMessage
                ?? String(localized: "Your subscription went through but we couldn't switch it on. It'll retry automatically.")
            return false
        }
    }

    private func jwsRepresentation(of result: VerificationResult<Transaction>) -> String? {
        if case .verified = result { return result.jwsRepresentation }
        return nil
    }

    /// Restore on a reinstall, a new account, or a second device.
    ///
    /// 🔴 THE THING BEING RESTORED IS THE SERVER ROW, NOT THE LOCAL
    /// ENTITLEMENT. This used to `AppStore.sync()`, read
    /// `currentEntitlements` and report success — a true statement about the
    /// DEVICE that says nothing about our database. On a reinstall or a new
    /// account the paywall dismissed triumphantly while the server had no row
    /// at all, so ordering kept being refused with `subscription_required`
    /// and raising this same paywall: an unrecoverable loop the moment
    /// enforcement is on, on the one screen that exists to escape it.
    ///
    /// It now resubmits the verified transaction's JWS through `submit` — the
    /// exact path a fresh purchase takes, so there is ONE definition of "the
    /// server knows about this subscription" rather than two that can
    /// disagree — and reports success only when the server acknowledges.
    ///
    /// `submit` calls `finish()`, which is a documented no-op on a
    /// transaction that is already finished, as everything in
    /// `currentEntitlements` will be.
    func restore() async -> Bool {
        try? await AppStore.sync()
        lastError = nil
        for await result in Transaction.currentEntitlements {
            guard case .verified(let tx) = result,
                  MailProduct.allIds.contains(tx.productID) else { continue }
            // `submit` owns the success path: it sets `isEntitled` and
            // surfaces its own error copy when the server refuses.
            return await submit(result)
        }
        // Genuinely nothing to restore. The hint must follow the finding —
        // a stale `true` from an earlier session would leave the UI claiming
        // a subscription that neither Apple nor the server can see.
        isEntitled = false
        return false
    }
}
