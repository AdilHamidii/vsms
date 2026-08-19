# Fix wave A — report

Worktree `bugfix-ux-pass`. Every commit built clean (`xcodebuild`, BUILD
SUCCEEDED, zero warnings) before being committed.

| # | commit | file(s) |
|---|---|---|
| 1 | `57763e6` | `Screens/WaitingScreen.swift` |
| 2 | `1dd9ab7` | `Components/ErrorBanner.swift`, `Networking/APIError.swift`, `State/AppState.swift`, +2 call sites |
| 3 | `44f9368` | `IAP/FreeEmailAccess.swift` (new), `Screens/HomeScreen.swift`, `Sheets/EmailDomainSheet.swift` |
| 4 | `5c86e6b` | `Sheets/CreditsSheet.swift` |
| 5 | `12915c1` | `Screens/WaitingScreen.swift` |
| 6 | `39791c8` | `Screens/HomeScreen.swift` |
| 7 | `25b46c9` | `Networking/APIError.swift`, `Components/ErrorBanner.swift` |

---

## 1. A reroll kept the old order's clock — `57763e6`

Committed unchanged from the previous agent, as instructed. `.task(id: order.id)`
on the tick and reconcile closures; the polling task stays unkeyed with a comment
saying why; `copied` resets on a new order.

## 2. Banner errors classified by code, not by rendered sentence — `1dd9ab7`

`ErrorBanner.informationalMessages` was built by rendering each known code with a
body of `{"error":"<code>"}` — no `retry_after_seconds` — and testing the live
message for **set membership**. That is exact string equality, so it breaks for
any message that interpolates server data. Exactly one does today:
`cancel_too_early` with the seconds renders *"Hang on. You can cancel in 42
seconds…"*, which matched nothing, so `isBlocking` was true — warning haptic, red
triangle, no auto-dismiss, "Check your orders" — for a purely informational wait,
on the screen with the highest cancel pressure in the app.

Changed:

- `APIError.businessCode` returns the backend's own `{"error": …}` code. It is
  deliberately nil for GoTrue responses — that envelope must never be fed to
  `parseErrorType` (the file's own existing warning).
- `AppState.BannerError { message, code }` plus `lastBannerError`. `lastError`
  survives as a computed get/set over it, so all ~40 plain-String assignment
  sites keep compiling and correctly resolve to **code == nil ⇒ blocking**,
  which is the safe default (locally-composed copy and transport failures).
- `AppState.showError(_ error: APIError)` is the code-carrying path; the 11
  sites that had an `APIError` in hand now use it.
- `isBlocking` takes the entry and tests `informationalCodes.contains(code)`.
  The code list itself is unchanged, so no error changed category.

Genuinely blocking errors behave exactly as before.

## 3. Home offered a free e-mail address the account had spent — `44f9368`

`EmailDomainSheet` resolved three states (Included / Free / Subscription) from
`mailStore.isEntitled` + `state.hasUsedFreeEmail`. Home resolved nothing: it
printed "Free" for any `isFree` domain in **three** places — the hero price, the
CTA subtitle, and the assurance line *"Free addresses cost you nothing if no code
arrives."* The free address is one per account **for life**, so a user who had
spent theirs was invited in and refused with `subscription_required` into a
paywall.

`FreeEmailAccess` (new file) is now the single definition both surfaces read.
Its own file because `LocalizedStringKey` needs `import SwiftUI`, and importing
SwiftUI into `MailSubscriptionStore.swift` makes `Transaction` ambiguous against
StoreKit — verified by a build failure, not guessed.

It stays a **UI hint**, matching both inputs: `begin_email_order` in SQL is still
the authority on what is allowed. This only decides what the screen says. The
hero also stops spending `theme.live` (the semantic "costs you nothing" green) on
the paywalled state.

New strings: *"Addresses are included with your subscription."*, *"You've used
your free address. More come with a subscription."* — six locales each, no
format specifiers.

## 4. A failed credit purchase was invisible — `5c86e6b`

`buy()` answered failure with `RHaptic.warn()` and nothing else. `errorCard`
rendered at the bottom of the ScrollView, below the assurances, the ladder header
and the whole pack list — off screen at the sheet's resting position.

A **purchase** failure now renders in the `BottomBar` immediately above the CTA.
A **load** failure keeps its inline placement, because there is no pack list above
it and there the card *is* the content. Also: no warning buzz on
`.userCancelled`, which returns false and sets no error — buzzing someone for
dismissing Apple's own sheet asserts a failure that did not happen.

No new strings.

## 5. "Active rental" on a one-off SMS purchase — `12915c1`

→ *"Verification in progress"*. Six locales, no specifiers.

## 6. First-run explainer omitted the paywall — `39791c8`

`needsExplainer` fires exactly for the first-run user who cannot afford the route
shown — with the signup grant at 0, nearly every new signup. The card read pick →
we hand you a number → the code lands here, naming no cost, while the button
directly beneath said "Buy credits".

Steps are now built from an array so a credits step can be inserted and the
numbering follows. It **quotes no figure** — prices, the grant and the pack ladder
all move server-side with no release, which is how the onboarding card promised
"+3 credits" through two versions in which the grant was 0.

`explainerNeedsCredits` checks the e-mail domain's own price in e-mail mode rather
than `routeCost` (always the SMS route). Without that split, a FREE address would
have gained a payment step it does not need — the mirror of fix 3.

New string: *"Add credits — that's how you pay for it"*, six locales.

## 7. `line_limit_reached` had no Swift case — `25b46c9`

Fell to the generic 409 *"Not available right now. Try a different option."*,
which reads as a stockout and sends the user to try another city. Nothing works
until they release a line. Mapped, and classified informational alongside
`line_exists` — a limit the user can clear is not a fault, and blocking treatment
offers "Check your orders", which is not where lines live. The copy quotes no cap
(it is `app_config.line_max_per_user`, server-side).

New string, six locales, no specifiers.

---

## Verification

- `xcodebuild -project VirtualSIM.xcodeproj -scheme VirtualSIM -configuration
  Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator'` —
  **BUILD SUCCEEDED, zero warnings**, run after each fix.
- Full-catalog format-specifier audit (multiset **and** order, positional markers
  treated as equivalent, a translation omitting a *later* argument allowed,
  `%%` ignored): **0 problems**. All four new strings carry no specifiers at all.
- `Localizable.xcstrings` diff is **40 insertions, 0 deletions** — purely
  additive; nothing was reworded or dropped.

## Nothing was judged unreal

All six remaining findings reproduced from the code. Two notes:

- **Fix 3 was not a broken flow, only a dishonest one.** `confirmGetEmail`
  already routes `subscription_required` to the paywall rather than an error
  banner, so the user did land somewhere sensible. The defect is that the app
  advertised something it had already decided not to give, one tap earlier.
- **Fix 2 is the only one with reach beyond its own screen**, since `showError`
  now carries a code from 11 call sites. The classification list is byte-identical,
  so the change is strictly "codes that were misread as blocking now are not"; a
  nil code still blocks, so no error can newly auto-dismiss.
