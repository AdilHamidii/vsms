---
name: aso-listing
description: App Store listing, keywords, screenshots and search performance for vSMS. Use when editing the store listing, choosing keywords, adding a localization, or reasoning about installs and conversion.
---

## ASO — search is the ENTIRE acquisition channel (2026-07-31)

Measured over 15 days: **20,884 impressions and all 143 downloads came from App
Store search.** Zero browse, zero referral, zero ads. There is no other channel,
so listing metadata is not a marketing nicety here — it is the funnel.

Full study: **`docs/aso-study-2026-07-31.md`**. Exact strings to paste:
**`docs/app-store-listing.md`** — and note that file had *drifted from the live
listing* (it documented a name and keywords that were never live). **Read ASC
before trusting it**: `GET /v1/appInfos/{id}/appInfoLocalizations` for
name+subtitle, `GET /v1/appStoreVersions/{id}/appStoreVersionLocalizations` for
keywords and description.

The funnel, US, 6 matched days: 7,107 impressions → 174 taps (**2.45%**) → 119
installs (**68.4% tap→install**). **The product page converts well; the search
result does not.** That is icon/title/subtitle/first-screenshots — so screenshot
work outranks description work. Non-US: **2,629 impressions → 0 taps, 0
downloads**, with an en-US-only listing.

**Strategy, from the owner: SMS is the revenue product, temp email is an
acquisition hook that "won't generate much revenue".** So email reaches the index
through *additive* surfaces — the keyword field and extra localizations — and
never by displacing SMS terms from the name. Changed for 1.6:

| field | from | to |
|---|---|---|
| name | `vSMS: Temp Number, Receive SMS` | unchanged (30/30) — **SUPERSEDED: live name is `vSMS: Second Number & Temp SMS` as of the 2.7–2.9 number refocus (read from ASC 2026-09-06)** |
| subtitle | `Second Phone Number & eSIM` | `Temp Mail & Phone Verification` (30/30) — **SUPERSEDED: live subtitle is `2nd Phone Line & Verification`** |

`Temp Mail` is intact by owner decision — it duplicates `Temp` from the name at a
cost of 5 characters, deliberately, because an exact phrase in a high-weight
field beats the same words composed from atoms. The old subtitle targeted a
cluster owned by TextNow (913k ratings) *and* advertised a paused product.

**`anonymous` was removed from the keyword field and must not come back.** Sign
in with Apple is mandatory and 203 of 204 accounts carry an email address, so it
is an unverifiable claim under 2.3.7. Also dropped: `privacy`/`private` (owned by
VPNs and password managers) and `data` (eSIM paused).

**The biggest remaining lever is localization, and it is unused.** The listing is
**en-US only** — one 160-character indexed surface (30 name + 30 subtitle + 100
keywords). Apple indexes *every* localization listed for a storefront. Adding
**Spanish (Mexico)** gives a second full keyword field **in the US storefront**;
**English (U.K.)** is Apple's additional language for most non-English
storefronts and the default in India. Two corrections to common ASO advice,
checked against Apple's own table: en-GB/en-AU/en-CA do **nothing** for the US,
and India's default is English (U.K.), not Hindi.

**Apple exposes no per-query search terms** (`Source Info` is empty on all 650
analytics rows), so keyword attribution is before/after inference only. Change
one layer at a time and allow 7–14 days.

**Ratings cap position; keywords only buy eligibility.** This is the ASO
ceiling, and the app has **8 ratings** across every storefront (2026-09-11,
`https://itunes.apple.com/lookup?id=6774768570&country=<cc>` →
`userRatingCount`; `customerReviews` in the ASC API shows only the WRITTEN
ones and cannot see a silent star).

🔴 **SIX OF THE SEVEN WRITTEN REVIEWS ARE THE OWNER'S FRIENDS (owner,
2026-09-11). The app has ONE organic review in its entire history — the DEU
1★ — and that user never received a code, so the prompt never fired for
them.** Reason from this and nothing else:

| date | rating | store | |
|---|---|---|---|
| 08-08 | 5★ | FRA | friend |
| 08-08 | 5★ | USA | friend — so the US storefront has **zero** organic ratings |
| 08-02 | 5★ | ESP | friend |
| 08-02 | **1★** | DEU | **the only organic one** — turkey number unavailable, **"after one day price increased"**, UK not working |
| 07-10 | 5★ | FRA | friend |
| 07-09 | 5★ | POL | friend |
| 06-22 | 5★ | POL | friend |

Ratings by storefront: fr 3, pl 2, us 1, de 1, es 1. Seven of those eight are
the table above, so **exactly ONE silent rating exists** (the third French
one) — and the owner's friends are the likeliest source of that too. The DEU
complaint about the price rising overnight is the **cost ratchet** working as
designed (rises apply immediately, falls are smoothed); it is correct and it
reads as bait-and-switch.

🔴 **THE NATIVE REVIEW PROMPT HAS NEVER PRODUCED A MEASURABLE RATING, AND IT
HAS NOT BEEN ABLE TO FIRE AT ALL SINCE 2026-08-19.** 215 users have received a
code all-time and 189 of them since 2026-08-08, against ~1 unattributable
silent rating. Two separate causes, one per era, and neither is user
indifference:

- **Since `1fa0838` (2026-08-19, live in 2.3+ and therefore in 2.11): the
  prompt is unreachable.** `ContentView`'s foreground handler is the only call
  site and it gates on `reviewableRecentDelivery()`, which reads a UserDefaults
  stamp written ONLY by the newly-appeared-code diff in `loadOrders` /
  `loadEmailOrders`. **No real delivery arrives through those.** The SMS code is
  written by `apply(server:for:wallet:)` (`self.orders[idx] = updated`) and the
  e-mail code by `refreshEmailOrder` (`emailOrders[i] = fresh`) — the
  single-order polls, neither of which stamps anything. `WaitingScreen` polls
  every 4s, so the poll always wins: by the time the list refresh runs, the code
  is already in `previouslyDelivered`, the diff is empty, and nothing is
  recorded. `hadPriorState` then closes the cold-launch path by design, because
  `orders` starts empty.
- **Before that: it fired ~0.9s after the code rendered on `OtpScreen`** —
  exactly when the user is rushing to paste, i.e. the reflex-dismiss position —
  and only for users who opened that screen at all, which the delivery push
  (`Your code is ${result.code}` in `poll-active-orders`) lets them skip. Do
  **not** strip the code out of the push to force users in; that trades real UX
  for a review.

⚠️ **Nothing is instrumented at the call site**, so "prompt shown and declined"
and "prompt never fired" are indistinguishable in the data. Any fix must add an
event, or the next reading is as blind as this one.

⚠️ **A decision was already made from the friend reviews and it should not be
repeated.** On 2026-07-31 the threshold dropped from the second delivered code
to the first, reasoning that "7 users reached two codes and produced all 3
reviews (~43%)". Those three were friends; the 43% was not a prompt→review rate
and no such rate has ever been measured. ✅ `shouldRequestReview` and the comment
stating that figure were both DELETED on 2026-09-11 when the prompt was rebuilt
around `AppState.reviewPromptBlocker` — see `.claude/rules/ios-client.md`, "The
review prompt". The instrumentation added there
(`review_prompt_eligible` / `_blocked` / `_requested`) is the first thing in this
product's history that can produce a real prompt→rating rate; it ships in 2.13
build 63 and has no reading yet.

⚠️ **Never let email keywords go live ahead of the build that ships email.**
