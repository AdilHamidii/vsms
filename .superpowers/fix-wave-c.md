# Fix wave C — six verified bugs

All six were real, all six fixed. `xcodebuild` (Debug, iphonesimulator,
generic destination) after every commit: **BUILD SUCCEEDED, zero warnings.**

| # | bug | commit |
|---|---|---|
| 1 | AllowanceStrip metered "200 texts left" for a dropped capability | `bf610d0` |
| 2 | plan screen labelled every price "/ month" (12× wrong after a paywall visit) | `b1119ba` |
| 3 | long-press 0 typed "+0" — international calling unreachable | `1725a73` |
| 4 | mail-subscription handler registered after the restore sweep | `adf5a06` |
| 5 | notification delegate set after launch — no deep link from terminated | `46c8c52` |
| 6 | a saved password reported as a failed one | `c8601f6` |

Notes:
- (2) plan is now read from `Transaction.currentEntitlements`; unknown ⇒ the
  Price row is omitted rather than guessed.
- (4) `MailSubscriptionStore` moved from `ContentView` to `AuthGate`, beside
  `SubscriptionStore`, registered synchronously before `iap.attach`'s sweep.
- (5) `AppDelegate` is now the sole `UNUserNotificationCenterDelegate`, set in
  `didFinishLaunchingWithOptions`, buffering the response until `push` exists;
  `PushManager.handle(response:)` replaces its delegate conformance.
- New catalog strings with all 6 translations: `%@ / month`, `%@ / year`, and
  the password-saved sign-in failure line. Single `%@`, no reorder risk.
- Out of scope as instructed: PushKit inbound-call payload keys.
