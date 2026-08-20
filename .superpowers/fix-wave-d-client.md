# Fix wave D — client red-team corrections

Status: all 10 items fixed, each committed separately. Build after every item:
`** BUILD SUCCEEDED **`, zero warnings.

| # | commit | what |
|---|---|---|
| 1 | `7a65606` | Dialpad keys are no longer `Button`s — a Button fires on finger-up, so no time window can work. Each key owns its press lifecycle; the `+` flag clears when the gesture ends. |
| 2 | `a6e6486` | `update_failed` added to the catalog with all six locales. Audited the other 13 strings this branch adds: already complete. |
| 3 | `6d03e85` | Mail entitlement resolved at `AuthGate`, unawaited, so Home is right on first paint. |
| 4 | `d014eb0` | `SubscriptionStore` keeps the backend code; both checkout sites re-raise it via a new `showError(BannerError)`. |
| 5 | `1838ece` | Plan/price row renders only on a line attributable to the subscription. |
| 6 | `9f14086` | `IAPStore.purchase` clears `lastError` on entry and on success. |
| 7 | `79d410c` | Reset step 1 re-runs when the field differs from the saved password; step 2 keeps the server's copy. Two new strings, six locales each. |
| 8 | `23e9f2c` | Entitlement cleared on sign-out, re-read on sign-in. |
| 9 | `6cd8dfa` | `elapsed` derived from `order.createdAt`, so the gate cannot be permissive while stale. |
| 10 | `c4c0798` | Dead sms allowance accessors + `sendBlock`, orphaned keys, redundant HStack, two stale comments. |

## Not fixed / notes

- **`"We can't call this country yet."` is missing from the catalog** and will
  ship English to six locales. It is NOT from this branch — it came in with
  `f9e274d` (international calling), which is on `main`. Left alone as out of
  scope; the full-catalog audit will catch it.
- Item 5 has no server-side attribution to use: `my_line` projects no billing
  source. The client substantiates only two cases (this launch's provisioned
  number, or the single-live-line case) and shows nothing otherwise. A
  `billing_source` column on the view would make it exact.
- `IAPStore` still shows `error.localizedDescription` on a StoreKit throw
  (raw system text, against the error-UX rule). Pre-existing, untouched.
