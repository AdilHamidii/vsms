# Organic acquisition for vSMS — design (2026-09-15)

Owner brief: *"main focus should be acquisition, asa is good but i dont want it
anymore, organic traffic is okay but i need more. can we get 200 users a day?"*
Budget **€0**. Owner will do hands-on work *"if it's clearly worth it"*.

This document answers that question, records the evidence it rests on, and
specifies five phases of work. Everything here is €0 cash.

🔴 **Every number below carries the date it was measured and the query that
re-derives it. Re-run them; do not quote this file.** It will be wrong within
days, like every other number block in this repo.

---

## 1. The answer to "200 a day"

**No — not in 60 days, and not from a new channel.** The honest target is a
4–6× lift on the channel that already works:

| | now (2026-09-15) | +30 days | +90 days |
|---|---|---|---|
| organic signups/day | ~20–25 | ~55 (recover to the August level) | 80–150 |
| net revenue/month | ~$205 | ~$400 | $700–1,000 |

200/day is the tail outcome of every lever landing at once, not the expected
one. It is written here as the thing NOT being promised, because the App Store
is the whole channel and a 7× on it needs ratings the app does not have.

### Why no new channel is proposed

Researched 2026-09-15 against measured third-party data, not vibes:

| channel | realistic ceiling | time to first result | verdict |
|---|---|---|---|
| TikTok / Shorts / Reels | low tens/day *if* a post hits | 4–12 weeks | no documented case in this category; content is policy-adjacent under TikTok's platform-manipulation rules |
| YouTube long-tail | single digits/day | months | queries already owned by competitor content marketing; viewers land on free WEB tools and never install |
| Reddit / forums | single digits/day | days | real but small; already built (Phase 5) |
| Owned website / SEO | low tens/day, eventually | **6–18 months** | competes against free no-install tools; quackr.io ranks **#1** in the US for "temporary phone number" and gets only ~19k visits/mo from it |
| Product Hunt | one-time spike | days | not repeatable |
| Cross-promotion networks | low tens/day if partnered | weeks | partner matching is hard for a gray-area category |

**Combined incremental ceiling across all of them: ~20–60/day, after months of
sustained unpaid effort.** Against that, ASO alone plausibly returns 60–125/day
incremental in the same window. The owner's hours are worth more in Phases 0–3.

⚠️ **TextNow is not a counter-example.** Its 919k ratings came from a decade of
*paid* user acquisition — 100+ ad partners tested via Adjust, up to 20% of paid
installs rejected as fraud — plus a broader free-calling utility. It is cited in
growth writing as proof that organic works at scale; it is not.

---

## 2. The evidence base

### 2.1 The business, measured

Last 30 days to 2026-09-15: **52 Production purchases ≈ $240 gross** across
seven currencies (USD 152.16 / EUR 55.89 / NGN 7,900 / INR 698 / JPY 800 /
AED 25.98 / CAD 4.99), ≈ **$205 net** at Apple's 15% Small Business rate.

**64 of 100 all-time payments are the USA storefront** (FRA 12, everything else
≤3). A US install is worth several times an EU one — which is the single fact
that should steer every locale and keyword decision, and which the ASA spend
was pointed away from.

Matured cohort (signed up 15–45 days ago): **957 signups → 171 SMS orders, 199
mail orders, 20 payers = 2.1%.** Revenue per signup ≈ **$0.23 gross / $0.19
net**. So 200/day would be ≈$1,140/mo net less ~$100 of free-mail wholesale.

```sql
-- revenue by currency, 30d (decode the JWS payload we already persist)
with d as (select (convert_from(decode(replace(replace(split_part(raw_jws,'.',2),'-','+'),'_','/')
       || repeat('=', (4 - length(split_part(raw_jws,'.',2)) % 4) % 4),'base64'),'UTF8'))::jsonb p
  from iap_receipts where environment='Production' and raw_jws is not null
    and created_at > now()-interval '30 days')
select p->>'currency' cur, round(sum((p->>'price')::numeric)/1000,2) gross, count(*) n
from d group by 1 order by 2 desc;

-- matured conversion cohort
with c as (select user_id uid from profiles
           where created_at between now()-interval '45 days' and now()-interval '15 days')
select count(*) cohort,
  count(*) filter (where exists(select 1 from orders o where o.user_id=c.uid)) placed_sms,
  count(*) filter (where exists(select 1 from email_orders e where e.user_id=c.uid)) placed_mail,
  count(*) filter (where exists(select 1 from iap_receipts r
                   where r.user_id=c.uid and r.environment='Production')) paid
from c;
```

### 2.2 The channel is ~96% organic, and ASA is over

**1,032 organic vs 42 paid-attributed install rows, all time.** Apple Search
Ads has produced 42 users in the product's history.

As of 2026-09-15 **all 14 campaigns in the account (vSMS and vRoam alike) read
`ENABLED` but `NOT_RUNNING`, serving reason `CREDIT_CARD_DECLINED`** — dark
since ~09-13. Before dying they spent **€58.73 for 36 vSMS installs, blended
CPI €1.63**, against an owner bar of €1.00. The owner has decided against ASA;
this plan does not depend on it and does not ask for the card to be fixed.

One finding from that spend is worth keeping: **BROAD ad groups carried almost
all impressions and installs; EXACT rows were single digits or zero across all
three campaigns.** If ASA is ever revived, never build an all-EXACT European
campaign.

### 2.3 🔴 Organic fell ~60% in eight days, and nothing recorded it

Daily signups with ASA-attributed users removed:

```
08-27 → 09-04    45–75/day   (mean ≈ 58, peak 75 on 08-29)
09-05 → 09-11    33–54/day   (mean ≈ 40)
09-12 → 09-15    15, 20, 30, 11   (mean ≈ 20)
```

Two step-downs, not a drift: **~09-07 and ~09-12.**

```sql
select p.created_at::date d, count(*) total,
  count(*) filter (where ia.attributed is true) paid_asa,
  count(*) filter (where ia.attributed is not true) organic_or_unknown
from profiles p left join install_attributions ia on ia.user_id = p.user_id
where p.created_at > now()-interval '30 days' group by 1 order by 1;
```

Three listing changes landed in that window. Read from ASC 2026-09-15 —
the keyword field is stored per version, so this history is recoverable:

| version | live | en-US keyword field |
|---|---|---|
| 2.0–2.11 | to 09-11 | `email,virtual,disposable,temporary,online,otp,code,inbox,fake,spam,signup,burner,text,call,receive` |
| 2.13 | 09-12 | `email,virtual,disposable,temporary,online,otp,code,burner,mail,verify,receive,text,call,2nd,get` |
| 2.14 | 09-13 | `sim,virtual,disposable,temporary,online,otp,code,burner,mail,verify,receive,text,call,2nd,get,usa` |

Plus the subtitle, which went `2nd Phone Line & Verification` →
`USA Phone Line & Verification` with 2.10 on 09-06 — one day before the first
step-down.

🔴 **2.14 deleted `email` from the en-US field, and that edit is in no document
and matches no approval.** `scripts/asc-keywords.py` and `CLAUDE.md` both still
carry the 2.13 list as the approved field; 2.14's was hand-edited to add `sim`
and `usa`, and `email` is what was dropped to make room.

- Apple does not substring-match, so `mail` does not cover `email`.
  **`temporary email`, `disposable email` and `email verification` stopped
  being formable in the largest storefront**, while temp-email is ~half of all
  order volume.
- Confirmed by measurement, not inference: `temporary email` is popularity 71 /
  difficulty 52 — scored a **good target** — and vSMS is **not in the top 182**
  in en-US.
- 🔴 **`usa` bought nothing.** The subtitle has carried `USA Phone Line &
  Verification` since 2.10, and Apple indexes name + subtitle + keyword field
  as ONE pool. `asc-keywords.py`'s own header states this. So a duplicate token
  was paid for with a live one.
- 2.13 separately spent slots on `2nd` and `get`. `get` buys nothing at any
  difficulty. `2nd` was re-bought because the subtitle change had just dropped
  it.

⚠️ **What is NOT established: that these edits caused the drop.** There is no
rank history to test against (§2.4), Apple publishes no per-query attribution,
and a competitor move or an algorithm change would produce the same shape. The
correlation is tight — three listing changes, three step-downs — and the
`email` mechanism is confirmed by a measured rank. That is the honest strength
of the claim: **one confirmed regression inside an unexplained decline.**

### 2.4 🔴 There is no measurement on the only channel that matters

`aso_db_stats` on 2026-09-15 returns **one tracked app: MedVault.** vSMS has
never been rank-tracked. Nothing anywhere pulls App Store Connect Analytics.

Consequences, stated plainly:

- The 09-12 collapse is **permanently undiagnosable**. There is no before.
- It is impossible to tell a **visibility** loss (fewer impressions) from a
  **conversion** loss (same impressions, fewer installs) — which are opposite
  problems with opposite fixes.
- Every ASO change shipped so far has been read out by watching signups, which
  confounds ranking, seasonality, and the other two changes in the same release.

This is why Phase 0 comes first and blocks the rest.

### 2.5 Current US ranks (iTunes Search, 2026-09-15)

| phrase | pop | diff | rank | | phrase | pop | diff | rank |
|---|---|---|---|---|---|---|---|---|
| receive sms | 83 | 53 | **#13**\* | | temp mail | 81 | 65 | #48 |
| temp number | 78 | 65 | **#19** | | second number | 71 | 66 | #65 |
| virtual number | 77 | 66 | #26 | | sms verification | 68 | 54 | #70 |
| burner *(single word)* | — | — | #37 | | second phone number | 91 | 73 | #77 |
| virtual phone number | 65 | 62 | #55 | | otp number | 52 | 48 | #112 |

\* measured as `receive sms online` (#13, pop 64 / diff 45).

**Outside the top ~175:** `temporary email`, `temporary phone number`,
`disposable email`, `burner email`, `us phone number`, `whatsapp verification`,
`fake number`, `text now`.

The single-word tokens in the keyword field (`email`, `mail`, `online`, `call`,
`get`) score **75–83 difficulty as standalone queries** against Gmail (2.4M
ratings), Outlook (9.2M), Mail (4.4M). They are only worth anything as raw
material for phrases.

⚠️ **en-GB is near-invisible on the identical English field** — only
`receive sms online` (#142) and `temp number` (#114) place at all. Flagged as
a research item, not a lever; GB has 0 ratings against US's 1.

### 2.6 The asymmetry the name change rests on

On `temp number` (pop 78), **4 of the top 5 results are apps with 0–23 ratings
that carry the exact phrase in their app name.** On `second phone number`
(pop 91) the top 5 are TextNow (920k ratings), Text Free (603k), Text Me
(673k), Burner and 2Number.

So exact title-phrase match visibly beats ratings volume in one cluster and
visibly does not in the other. ⚠️ **This is inference from the competitor set,
not a controlled test** — but it is the whole basis for Phase 2, and it is why
Phase 2 trades away the `second …` cluster without regret.

### 2.7 The untouched markets

vSMS is sellable with an **en-US fallback listing and zero ratings** in
Indonesia, Turkey, Vietnam, Thailand, India, Korea, Taiwan, Hong Kong,
Netherlands and Ukraine (Poland has 2 ratings, also fallback). China stays
excluded — Apple/MIIT forbid CallKit on that storefront and the app ships it.

Keyword difficulty there runs **20–39 against 65–73 in the US**, with
competitors that are mostly 0-rating apps: Turkish `gecici numara` (diff 32),
`sanal numara` (39), Dutch `tijdelijk nummer` (23) and `tijdelijke email` (21),
Polish `tymczasowy email` (20), Ukrainian `тимчасовий номер` (28) — all scored
"Hidden Gem" or "Sweet Spot".

This is the largest piece of free inventory the product has, and nothing is
standing on it.

---

## 3. The phases

Ordered by dependency, not by size. Phase 0 blocks everything because without
it no later phase can be read out.

### Phase 0 — See the channel (week 1, no App Store release required)

**Deliverables**

1. **Daily rank tracking.** Register vSMS (`com.anthersystems.VirtualSIM`, id
   `6774768570`) in the aso-connect DB and track ~40 phrases across the
   revenue storefronts (us, fr, de, es, it, gb, br, pl at minimum). Daily
   snapshot, persisted, so movement is a time series rather than a memory.
2. **An App Store Connect Analytics puller**, as a `scripts/asc-analytics.py`
   in the style of the existing `asc-*.py` scripts: impressions → product page
   views → installs, **split by source** (App Store Search / Browse /
   Referrer / Web), per storefront, daily. This is the only thing that can
   separate a visibility loss from a conversion loss.
3. **A daily line in the Telegram ops bot** — yesterday's installs and
   impressions, and the three largest rank moves. One registry entry and one
   handler per `.claude/rules/ops-bot.md`; **re-run `telegram-setup`** after,
   or the `/` menu keeps the old list.

**Read-out.** None — this phase produces the instrument, not a result. It is
done when a rank series exists for ≥7 consecutive days and the analytics
puller has returned a full storefront × source table at least once.

🔴 **Start the rank series BEFORE Phase 1 or 2 ships.** A read-out that begins
after the change is not a read-out.

### Phase 1 — Undo the regressions (next release)

**Deliverables** — all in `scripts/asc-keywords.py`, applied to a
`PREPARE_FOR_SUBMISSION` version (the script refuses a version in review, by
design, and that refusal stays):

- **Restore `email`** to the en-US field. This is the one confirmed loss.
- **Remove `usa`** — already indexed via the subtitle; it is a pure duplicate.
- **Remove `get`** — buys nothing at any difficulty.
- **Re-evaluate `sim` and `2nd`** against the scorer before keeping either.
- Leave every other token and every other locale alone this round.

**Read-out.** `temporary email`, `disposable email` and `temp mail` rank in
en-US, 7–14 days after the version is live, against the Phase 0 baseline.

### Phase 2 — The app name (same release as Phase 1)

**Change the name to `vSMS: Temp Number, Receive SMS`** — exactly 30/30
characters — and localize it across all 13 locales.

**Why this candidate.** It converts the two highest-opportunity phrases
measured into exact contiguous phrases in the highest-weight field:
`receive sms` (pop 83, the best opportunity score of anything tested, and
already the app's best rank at #13) and `temp number` (pop 78, #19, the cluster
where title match demonstrably beats ratings — §2.6).

It is the **only ≤30-character candidate that keeps `sms` as a literal word**,
so it does not put the app's best keyword at risk. Candidates rejected:
`vSMS: Temp Number & Second Line` is 31 characters and does not fit;
`vSMS: Temp Number & Temp Mail` (29) and `vSMS Temp Number: Second Line` (29)
both silently drop `sms`.

**What it gives up.** The `second …` cluster: `second number` (#65) and
`second phone number` (#77). Both are already too deep to be visible, and §2.6
says the incumbents there are not beatable by phrasing at any ratings level
this app will reach.

**Keyword-field consequence.** The name gains `receive`, so drop `receive` from
the field; the name loses `second`, so add `second` back. Roughly
character-neutral.

**Risks, stated:**

- A name change carries no formal ranking reset, but ranking has inertia and an
  8-rating app has little to fall back on if a query de-indexes during re-crawl.
- Shipping Phases 1 and 2 together makes attribution hard. They are separable
  **only because they move different queries** — Phase 1 moves the email
  cluster, Phase 2 moves `temp number` / `receive sms` — and **only if Phase 0
  is already tracking both sets.** If Phase 0 slips, Phase 2 must wait a
  release.
- 🔴 The localized names must be scored in their own storefronts. A name cannot
  be copied between locales: each indexes against a different subtitle and a
  different competitor set.

**Read-out.** `temp number`, `receive sms online`, `second number` in en-US at
7 and 14 days.

### Phase 3 — The empty markets (the volume lever)

**Add ten App Store locales**: `id`, `tr`, `vi`, `th`, `hi`, `ko`, `zh-Hant`,
`nl`, `uk`, plus a native `pl`. For each: name, subtitle, 100-char keyword
field, description and release notes, **each scored in its own storefront**
against its own name+subtitle pool.

🔴 **`zh-Hant` only — never `zh-Hans`.** Traditional Chinese serves the Taiwan
and Hong Kong storefronts. Simplified Chinese is the China storefront, where
the app is deliberately unavailable because Apple/MIIT forbid CallKit and the
app ships it. Adding `zh-Hans` metadata is the first step toward re-listing
there by accident.

Expect roughly **+15–30% of current organic installs within 60–90 days**
(Apple review plus indexing lag is ~2–4 weeks). Each market is individually
small; the case is that ten near-empty pools beat one more slice of a saturated
one.

**Constraints carried from the repo's existing rules:**

- 🔴 **No listing field may quote a price, in any locale** — release notes and
  description included. Scan every locale for `[$€£¥₹]` before submission and
  expect zero hits.
- **Never name or allude to a supplier** in any user-facing copy.
- **Never claim a delivery rate** the app cannot keep. Temp SMS delivers ~22%
  per attempt; the app's one organic review is already someone angry about a
  promise that did not hold.
- Screenshots fall back to `en-US` and are **not** part of this phase. The
  owner composes screenshots themselves and receives raw captures only.

**Read-out.** Signups and installs per storefront, which Phase 0's analytics
puller reports natively.

### Phase 4 — Ratings

8 ratings (2026-09-15: us 1, de 1, fr 3, es 1, pl 2) structurally cap every
term above difficulty ~60, which is most of the US catalogue. Six of the seven
written reviews are the owner's friends; the one organic review is the DEU 1★.

The rebuilt review prompt covering all three products ships in 2.15 and has not
reached users. **Run `python3 scripts/app-ratings.py` on a schedule starting
now** — Apple gives no attribution for a rating, so an interrupted time series
is only a read-out if it begins before the change lands.

No further work is specified here. This phase is a measurement obligation, not
a build.

### Phase 5 — Reddit

Already built and live as of 2026-09-15 (`reddit-scan`, hourly, read-only;
`/leads` in the ops bot). The owner replies by hand from their own account.

🔴 **Nothing in this plan changes that.** There is no posting path, the token
is `client_credentials` so submit/comment endpoints 403, and that absent
capability is the safety property. Undisclosed automated promotion risks a
sitewide **domain** ban, which would cost the legitimate channel permanently.

Expect single digits per day. It is real and it is free; it is not the plan.

---

## 4. Explicitly out of scope

- **Apple Search Ads.** Owner decision. The account is dark on a declined card
  and this plan does not ask for it back.
- **TikTok, YouTube, an owned website, SEO.** §1. Revisit only if Phases 0–3
  land and the ceiling is genuinely hit.
- **Sibling apps / an ASO portfolio.** Raised and withdrawn on 2026-09-15: the
  `temp number` title-match finding argues for renaming vSMS, not for shipping
  more apps, and Guideline 4.3 duplicate-app risk attaches to the whole
  developer account.
- **Subtitle changes.** `USA Phone Line & Verification` stays this round. Its
  tokens combine weakly (`phone verification` ranks #132) and `usa` does not
  appear to buy rank — but changing it in the same release as the name makes
  both unreadable, and `usa` may be doing unmeasured conversion work for a
  storefront that is 64% of revenue. It is a later, separate test.
- **Retention and conversion work.** Owner has explicitly closed this:
  *"we tried to improve user retention multiple times, we did our best."*

---

## 5. Risks

| risk | mitigation |
|---|---|
| The 09-12 drop has a cause none of these phases touch (algorithm, competitor, seasonality) | Phase 0 makes the next one diagnosable. Phase 1 fixes a confirmed regression regardless of whether it was the cause. |
| The name change loses more than it gains | Single variable, 7–14 day read on three named queries, and the positions it trades away are already invisible. Reverting costs one release. |
| Phases 1 and 2 shipping together are unreadable | They move disjoint query sets, tracked separately from Phase 0. If Phase 0 slips, Phase 2 waits. |
| Ten new locales is a large one-off with slow feedback | Each is independent; ship in two batches of five so the first batch reads out before the second is written. |
| More installs into a funnel that delivers a code ~22% of the time produces more 1★ reviews | Real, and it pulls against Phase 4. The delivery explainer shipped in 2.14 to address it. Watch the ratings series, not just the count. |
| The keyword field drifts again by hand, unrecorded | Phase 0's tracking would surface it. `asc-keywords.py` is the only sanctioned writer; a hand edit that disagrees with it is a defect. |

---

## 6. Open questions

- **Was the 09-07 step-down the subtitle change?** `2nd Phone Line` → `USA
  Phone Line` is a one-token swap, which looks too small to explain −40%. No
  rank history exists to test it. Left open, deliberately.
- **Why is en-GB near-invisible on the identical English field?** Worth one
  investigation once Phase 0 is tracking GB.
- **Does `usa` in the subtitle earn its place on conversion?** Unmeasured in
  both directions. Phase 0's analytics puller (impressions → product page views
  → installs) is what would answer it.
