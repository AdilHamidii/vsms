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
    /// Which plan the paywall is offering. Monthly by default: it is the lower
    /// commitment, and defaulting to the expensive option is a dark pattern.
    var selectedPlan: LinePlan = .monthly

    #if DEBUG
    /// Stand-in pricing for `ScreenshotMode`, and ONLY for it.
    ///
    /// Xcode applies `Products.storekit` when Xcode itself launches the app;
    /// `simctl` does not, so a scripted screenshot run gets no products and the
    /// paywall renders "The App Store isn't offering this subscription right
    /// now" over a disabled button. That exact frame was uploaded to App Store
    /// Connect as the monthly subscription's review screenshot — a reviewer
    /// opening it saw an error instead of a purchase screen.
    ///
    /// ⚠️ **These are not placeholder strings.** The frame becomes an App
    /// Store review screenshot, so every figure has to equal what the store
    /// will really charge. They mirror `Products.storekit`, which is itself
    /// kept in step with App Store Connect by hand. If a price moves in ASC,
    /// it moves in all three.
    ///
    /// The whole thing is `#if DEBUG`, so a Release archive cannot be put into
    /// this state by any launch argument or server response — same guarantee
    /// `ScreenshotMode` already documents for its sample line and threads.
    struct ScreenshotPricing {
        var monthly = "$9.99"
        var yearly = "$99.99"
        /// ($9.99 × 12 − $99.99) ÷ ($9.99 × 12) = 16.6% → 17, which is what
        /// `yearlySavingsPercent` computes from the live prices.
        var savingsPercent = 17
        var trial = "3 days"
    }

    /// Non-nil ONLY under `ScreenshotMode`. Every read of it is behind
    /// `#if DEBUG`, so this is inert in a shipping build.
    var screenshotPricing: ScreenshotPricing?
    #endif

    /// The product the CTA will actually buy. Everything user-facing — price,
    /// renewal sentence, trial claim — reads from THIS, so the button can never
    /// charge for a plan other than the one on screen.
    var selectedProduct: Product? {
        selectedPlan == .yearly ? yearlyProduct : product
    }

    /// Yearly saving against twelve monthly payments, computed from the LIVE
    /// StoreKit prices in the user's own currency. Never hardcoded: the two
    /// prices are set independently in App Store Connect and in different
    /// territories, so "save 17%" written into the app is a claim that goes
    /// wrong silently the first time either price moves.
    var yearlySavingsPercent: Int? {
        #if DEBUG
        if let s = screenshotPricing { return s.savingsPercent }
        #endif
        guard let m = product?.price, let y = yearlyProduct?.price, m > 0 else { return nil }
        let twelve = m * 12
        guard twelve > y else { return nil }
        let pct = ((twelve - y) / twelve) * 100
        return max(1, Int((pct as NSDecimalNumber).doubleValue.rounded()))
    }

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

    /// "3 days" — or nil when there is no trial to promise.
    ///
    /// 🔴 nil is the important case and it is NOT an error. Apple grants one
    /// introductory offer per subscription GROUP per Apple ID, so someone who
    /// already trialled the monthly gets nothing here and StoreKit reports no
    /// offer. Every trial claim in the UI hangs off this, so an ineligible user
    /// is never shown "3 days free" and then charged $99.99 immediately —
    /// which is a refund, a one-star review, and an App Store 3.1.2 problem.
    var trialLabel: String? {
        #if DEBUG
        if let s = screenshotPricing { return s.trial }
        #endif
        guard let offer = yearlyIntroOffer, offer.paymentMode == .freeTrial else { return nil }
        let n = offer.period.value
        switch offer.period.unit {
        case .day:   return n == 1 ? String(localized: "1 day")   : String(localized: "\(n) days")
        case .week:  return n == 1 ? String(localized: "1 week")  : String(localized: "\(n) weeks")
        case .month: return n == 1 ? String(localized: "1 month") : String(localized: "\(n) months")
        case .year:  return n == 1 ? String(localized: "1 year")  : String(localized: "\(n) years")
        @unknown default: return nil
        }
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
    var displayPrice: String? {
        #if DEBUG
        if let s = screenshotPricing {
            return selectedPlan == .yearly ? s.yearly : s.monthly
        }
        #endif
        return selectedProduct?.displayPrice
    }

    // MARK: - What the paywall may ask
    //
    // The paywall used to read `product` / `yearlyProduct` directly, i.e. it
    // depended on StoreKit's `Product` type just to answer "is there a plan to
    // show?". `Product` has no public initializer, so that made the screen
    // impossible to render without a live StoreKit session — which is why the
    // review screenshot attached in App Store Connect was of the paywall's
    // FAILURE state. These four say what the view actually means, and are the
    // single place the screenshot harness substitutes into.

    /// Is there a monthly plan to sell? Distinct from "has it loaded yet".
    var hasMonthly: Bool {
        #if DEBUG
        if screenshotPricing != nil { return true }
        #endif
        return product != nil
    }

    /// Is there a yearly plan to sell? When false the paywall offers monthly
    /// alone rather than a choice one side of which cannot be bought.
    var hasYearly: Bool {
        #if DEBUG
        if screenshotPricing != nil { return true }
        #endif
        return yearlyProduct != nil
    }

    var monthlyPriceDisplay: String? {
        #if DEBUG
        if let s = screenshotPricing { return s.monthly }
        #endif
        return product?.displayPrice
    }

    var yearlyPriceDisplay: String? {
        #if DEBUG
        if let s = screenshotPricing { return s.yearly }
        #endif
        return yearlyProduct?.displayPrice
    }

    // MARK: - Purchase

    /// Buy the subscription for a number that has already been reserved.
    ///
    /// The reservation happens BEFORE this, deliberately: everything that could
    /// refuse — Telnyx float, an existing line, a paused product — has to
    /// happen before Apple takes money, because an Apple refund is the one
    /// money path we cannot drive.
    func purchase(phoneNumber: String, city: String, monthlyCents: Int?) async -> Bool {
        guard !isPurchasing else { return false }
        // The SELECTED product, not the monthly. Buying anything other than the
        // plan shown next to the button is the worst bug this screen could have.
        guard let product = selectedProduct else {
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
            // StoreKit REFUSES to sell a subscription this Apple ID already
            // holds — it shows its own "You're currently subscribed to this"
            // alert and then throws. The throw carries no code worth branching
            // on (it differs by OS version and by environment), so ask the
            // entitlement instead of guessing at the error.
            //
            // This matters because "Please try again" is advice that can never
            // work in that state: every retry hits the same refusal. The user
            // who sees it is, by definition, someone who has PAID and has no
            // number — so the message has to name Restore, which is the control
            // that actually recovers them.
            lastError = await holdsLineEntitlement()
                ? String(localized: "You're already subscribed. Tap Restore to finish setting up your number.")
                : String(localized: "That purchase didn't complete. Please try again.")
            return false
        }
    }

    /// Does this Apple ID already hold one of our subscriptions?
    ///
    /// A UI hint only, never an authority — `my_line` decides whether a line
    /// exists. StoreKit knows what Apple is charging for; it does not know
    /// whether we ever managed to deliver it.
    private func holdsLineEntitlement() async -> Bool {
        for await result in Transaction.currentEntitlements {
            if case .verified(let tx) = result, LineProduct.allIds.contains(tx.productID) {
                return true
            }
        }
        return false
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

        // 🔴 "No pending purchase" conflates two states that need OPPOSITE
        // handling, and only the SERVER can tell them apart:
        //
        //   • a RENEWAL, or a replay on a new device — a line already exists,
        //     ASSN drives it server-side, and finishing is correct;
        //   • a FIRST purchase whose provisioning failed on an earlier launch
        //     and is now being swept by `restorePurchases()`. `pending` is
        //     in-memory, so it is nil here BY CONSTRUCTION on every relaunch.
        //
        // Finishing the second case retires the transaction forever: StoreKit
        // stops redelivering it, and the user is left paying every month for a
        // number that was never created — with Restore, their only recovery,
        // having been the thing that destroyed the recovery. The `APIError`
        // path below deliberately leaves the transaction unfinished for exactly
        // this sweep; blind-finishing it here quietly undid that.
        guard let want = pending else {
            // An unreadable server counts as "no line". Wrong in the safe
            // direction on purpose: an unfinished transaction costs a
            // redelivery, a wrongly finished one costs the money.
            // ⚠️ `isLive`, NOT `!lines.isEmpty`. `fetchAll()` returns every
            // `my_line` row including `released` and `failed` ones, which are
            // deliberately retained for history — so the first version of this
            // guard was satisfied by the corpse of a previous rental and
            // finished the transaction anyway, which is the exact bug it was
            // written to prevent. A resubscriber, or anyone whose earlier
            // activation failed, hit it every time.
            let lines = (try? await LineAPI(client: api).fetchAll()) ?? []
            guard lines.contains(where: { $0.status.isLive }) else {
                lastError = String(localized: "You're subscribed, but your number hasn't been set up yet. Contact support — don't buy again.")
                return false
            }
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
}

/// Which plan the paywall is offering.
///
/// Both are in the SAME App Store subscription group, so Apple treats a switch
/// between them as an upgrade/downgrade and prorates it — a user can never end
/// up holding both, which matters because `phone_lines_one_apple_line_per_user`
/// would refuse the second line and they would be paying for nothing.
enum LinePlan: String, CaseIterable, Identifiable {
    case monthly
    case yearly

    var id: String { rawValue }
}

extension LineProduct {
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
