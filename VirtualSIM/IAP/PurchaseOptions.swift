import Foundation
import StoreKit

/// The purchase options every StoreKit buy in this app must carry.
///
/// 🔴 `appAccountToken` IS THE ONLY THING THAT TIES AN APPLE PURCHASE BACK TO
/// AN ACCOUNT WHEN OUR OWN VERIFY CALL NEVER LANDS. Apple's signed transaction
/// otherwise names no user, so attribution falls to whatever WE wrote at
/// purchase time — and if the purchase call never ran (network drop, app killed
/// at the wrong second, a 500), nothing anywhere says who paid.
///
/// That is not hypothetical. Original transaction `700002748363888` — a $59.99
/// yearly bought 2026-08-22 — has four Apple notifications and **zero** rows in
/// `line_subscriptions` and `phone_lines`. The customer paid, received no
/// number, was billed again on the billing-recovery retry seventeen days later,
/// and asked for a refund within eighty minutes. It could not be recovered
/// automatically, because there was no way to learn which account it was.
///
/// Apple echoes the token back on EVERY future signed transaction for that
/// subscription, renewals included, so setting it once at purchase makes the
/// entitlement permanently attributable — that is what lets
/// `ensureSubscriptionRow` write the row from a notification alone.
///
/// ⚠️ **It must be a UUID, and a missing one yields NO option rather than a
/// substitute.** Supabase user ids are UUIDs, so the account id is passed
/// straight through. Anything unparseable — `ScreenshotMode`'s `"screenshot"`,
/// or a buyer with no session — produces an empty set: an invented token would
/// attribute a real payment to an account that does not exist, which is worse
/// than the gap it was meant to close.
enum PurchaseOptions {
    static func forUser(_ userId: String?) -> Set<Product.PurchaseOption> {
        guard let userId, let uuid = UUID(uuidString: userId) else { return [] }
        return [.appAccountToken(uuid)]
    }
}
