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
| name | `vSMS: Temp Number, Receive SMS` | unchanged (30/30) |
| subtitle | `Second Phone Number & eSIM` | `Temp Mail & Phone Verification` (30/30) |

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

**Ratings cap position; keywords only buy eligibility.** That is why
`shouldRequestReview` fires on the **first** delivered code.

**Live review state, read from ASC 2026-08-05 — there are FIVE, not three, and
the US still has zero:**

| date | rating | store | |
|---|---|---|---|
| 08-02 | 5★ | ESP | "Best app ever !!!! Really useful" |
| 08-02 | **1★** | DEU | "Scam" — turkey number unavailable, **"after one day price increased"**, UK not working |
| 07-10 | 5★ | FRA | |
| 07-09 | 5★ | POL | |
| 06-22 | 5★ | POL | |

Two landed on 08-02, two days after the threshold dropped to one code (and
after 1.6/1.7 shipped, which re-arms the per-version gate). **Apple gives no
attribution**, so that is timing, not proof — and note one of the two was the
1★. The DEU complaint about the price rising overnight is the **cost ratchet**
working as designed (rises apply immediately, falls are smoothed); it is
correct and it reads as bait-and-switch.

**Why there are no US reviews: the eligible pool is ~5.** Only 26 users have
ever received a code; by storefront (buyers only — the other 16 coded users
never bought, so their storefront is unknowable) that is USA 5, FRA 2, ESP 2,
SWE 1. At the ~10% prompt→review rate the rest of the data implies, five
eligible users predicts 0.5 reviews. **The prompt is not the constraint; the
number of people who ever receive a code is.**

⚠️ **A second, unquantified leak: the review prompt lives on
`OtpScreen.onAppear`, but the delivery push already contains the code**
(`Your code is ${result.code}` in `poll-active-orders`). A user who reads it
off the lock screen and types it straight into the target app never opens that
screen and is never prompted — and that is the *designed* flow, since the ✕ was
made non-destructive precisely because users must leave to paste the number.
How often is **not measurable server-side**: whether `OtpScreen` appeared is
device-side UserDefaults, and `push_devices.updated_at` cannot separate "warm
foreground" from "never came back". The fix, if wanted, is to fire the prompt
on app-foreground after a recent delivered code rather than tying it to one
screen — a client release. Do **not** strip the code out of the push to force
users in; that trades real UX for a review.

⚠️ **Never let email keywords go live ahead of the build that ships email.**
