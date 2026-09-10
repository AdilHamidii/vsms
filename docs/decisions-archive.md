# Decisions archive — resolved issues, changelog, superseded reasoning

**Not loaded into any session.** This is where the root `CLAUDE.md` sends
things that were true, are still worth being able to find, and no longer earn
their place in a file that is loaded in full on every request.

Three kinds of thing live here:

1. **Resolved issues.** A `Known-open` entry whose bug is fixed. The *rule* it
   taught, if it has one, was kept in the root file's gotchas list — only the
   incident narrative is here.
2. **The changelog**, an index of dates to search for rather than something to
   read top to bottom.
3. **Superseded reasoning** — the per-provider credit divisors, the store
   redesigns that reversed, the grant that moved four times. Kept because a
   decision that reversed twice will be proposed a third time, and the argument
   against it is here. (The four failed attempts at inbound calling are NOT
   here: they live in `.claude/rules/telephony.md`, next to the design that
   finally worked.)

⚠️ **Everything in this file is dated and may be stale.** It records what was
true when it was written, and nothing here is maintained. Verify against the
code or the live system before acting on any of it.

If you need something carried into neither this archive nor a
`.claude/rules/*` file, the pre-split root file is in version control: `git show 726acf5:CLAUDE.md`.


## Home tab — first-session paths (2026-09-10)

The measurement behind the Home tab (CLAUDE.md, "Home leads the app"). Over the
first session of the 241 users who signed up 2026-09-04 → 09-10, on live build
2.11, which landed every new user on the Temp tab: 70 stayed on Temp (2 opened
support), 68 bounced Temp → Number (11 opened support), 61 stayed on Number (7
did nothing), 27 touched neither (20 did nothing), 15 went Number → Temp. A
quarter bounced between the two product tabs, and that cohort produced 11 of
the 15 support taps.

Re-derive rather than quoting those counts — the query below is what produced
them, and the same query read after 2.13 is adopted is how the Home tab is
judged (alongside `home_card_tapped` by `card`):

```sql
-- FIRST session = the session in which onboarding_done fired.
with u as (select id as user_id from auth.users where created_at >= '2026-09-04'),
fs as (select distinct on (e.user_id) e.user_id, e.session_id
       from app_events e join u using(user_id) where e.name='onboarding_done'
       order by e.user_id, e.created_at),
ev as (select f.user_id, e.name, e.created_at from fs f
       join app_events e on e.user_id=f.user_id and e.session_id=f.session_id),
firsts as (select user_id,
    min(created_at) filter (where name='line_store_view') t_line,
    min(created_at) filter (where name in ('service_selected','country_selected','checkout_view')) t_sms,
    bool_or(name='order_submitted') sms_order, bool_or(name='line_purchase_result') line_sheet,
    bool_or(name='email_order_submitted') email_order, bool_or(name='support_whatsapp_open') support
  from ev group by 1)
select case when t_line is null and t_sms is null then 'neither'
            when t_line is null then 'sms only' when t_sms is null then 'line only'
            when t_line < t_sms then 'line then sms' else 'sms then line' end path,
       count(*) users, count(*) filter (where sms_order) sms_orders,
       count(*) filter (where email_order) email_orders,
       count(*) filter (where line_sheet) line_sheets, count(*) filter (where support) support
from firsts group by 1 order by 2 desc;
```

## Changelog


Reasoning for each of these lives in the topic section above; this is only an
index, so "why is it like this" has a date to search for.

- **08-23 (later) — build 43's submission cancelled, 2.3 resubmitted as
  build 44 (11:22Z).** Two changes rode in: the paywall's "≈ N verifications"
  per-row estimate REMOVED (owner: "horrible" — it was derived from a catalog
  median that moves hourly; rows now carry exact credits + per-credit price
  only, `UnitPrice`/`deriveUnit` deleted from `CreditsSheet`), and a
  five-item line-UI batch aimed at the 3.9-minute cancel: the empty inbox is
  a proof-of-life instruction ("text it from your own phone"), the screenshot
  fixtures no longer show an outgoing reply the product refuses to send, the
  minutes meter moved from Messages to Calls, read-only threads state the
  limit, the city picker quotes the live monthly price, and the Calls empty
  state no longer claims received calls. Six new keys translated.
  **`rent-line-credits` had its FIRST real use the same day**: a
  credits-billed Toronto test line for the owner's dev account
  (`+14377804893`, line `f595c56a-…`, 20 credits granted via
  `goodwill-credit`, active to 2026-09-22, `billing='credits'`). The whole
  order → messaging-attach → voice-provision sequence worked; **inbound SMS
  on a credits-billed line is still untested** — the owner got the number in
  the app but never texted it. Note the credits path has NO renewal
  mechanism proven: watch what `reclaim_lapsed_lines` does to it on Sep 22.
- **08-22/23 — 2.3 (build 43), submitted 08-23 09:55Z.** Diagnosed the
  pack-sales collapse (2.0's number-first onboarding cut `create-order`
  calls 30/day → 1; then grant 0; then grant 5 covered 49 of 52 first
  orders so nobody met a paywall) → grant **3**, and
  `AppState.minDefaultCredits = 3` demotes the bargain bin in every
  app-made pick. UI: single-column paywall with all six packs + correct
  preselect; Number store CTA/escape above the tab bar; e-mail code screen
  sells the next address; honest calling copy ("Taking incoming calls —
  Not yet"); **every own-record label removed** (owner decision); seven
  audit items (tierAdvice gone, waiting notice, priced top-up, Popular
  list, e-mail CTA, one auth door, mail-plan entry points). Store-side:
  EUR prices on credits.60/150 fixed (ladder had inverted in euros); the
  line's 3-day trial DELETED after 3 of 3 conversions declined $99.99;
  swap repriced to 8 credits (≥3× margin); mail subscription ENFORCED
  (first subscriber within a minute of the 2.2 push). Listing rewritten on
  all 13 locales (live 2.2 text still promised "in and out" texts and
  calls). 101 new strings translated; `scripts/asc-release.py`,
  `scripts/audit-xcstrings.py`, `scripts/asc-fix-eur-pack-prices.py` added.
  Telegram ops bot overhaul merged to main the same day. (The build-44 tree
  was installed and launched on the owner's phone at midday 08-23 — an
  earlier version of this line said the RC never reached it.) Still not
  done: the Number swap's Telnyx half is unprobed live — the first real
  swap is the probe.
- **08-19/20 — 2.2 (build 42): a bug + UX pass, red-teamed.** Four discovery
  agents (client correctness, first-session UX, backend money paths, error
  copy) produced ~30 candidates; 21 were fixed, then an adversarial pass broke
  12 of the FIXES and those were corrected in turn.

  🔴 **The lesson worth keeping: a fix can be worse than the bug, and only an
  adversarial reader finds it.** `settle_stale_calls` was changed so a call
  that "never connected" settles to zero, gated on `provider_call_session_id`
  — chosen specifically to AVOID gating on client-supplied `status`. But that
  column is written by `attach_line_call_session` straight from
  `report-line-call`'s request body, so it is equally client-supplied, and the
  new gate made SILENCE the winning move: never report, and the sweep billed
  nothing at all, where before it cost 2 credits per dial. All six live
  `line_calls` rows were already sitting at `credits_reserved = 0` by the time
  it was caught. Reverted to billing the server-set reservation. **Any future
  gate on call billing must key on data the DEVICE CANNOT SET** — and note
  `provider_call_session_id` is client-supplied despite the name.

  Also fixed: the waiting screen kept the previous order's clock across a
  reroll (unkeyed `.task`), so cancel and both reroll buttons were live at t=0
  and every tap 429'd; banner errors were classified by comparing RENDERED
  STRINGS, so "you can cancel in 42 seconds" — which carries interpolated
  server data — was treated as a blocking red error; the dialpad could not
  produce a usable `+` at all, making international calling unreachable; Home
  advertised a free e-mail address that was already spent, and printed the cash
  value of a credit price; the notification delegate was registered after
  launch, so a push tapped from a terminated app never deep-linked; a
  `MailSubscriptionStore` on `AuthGate` survived sign-out and leaked one user's
  entitlement to the next; the watchdog had been permanently red since 08-17
  because `20260817100000` retired SMSPVA without writing the
  `smspva_retired` flag its own guards read.

- **08-18 (second stream, merged into 2.1)** The dialer never got out of the
  way of the call it placed: `InCallOverlay` is a root `.overlay` and the
  dialer is a `fullScreenCover`, which always renders above it — so a live call
  drew UNDERNEATH the keypad, invisible and unendable from inside the app. See
  trap 5 under "Calling". Also in this stream: **email + password auth** end to
  end (Resend on `mail.vsmsapp.com`, 6-digit codes, grant paid only on
  confirmation against a normalized address), a **four-page onboarding** that
  leads with temp SMS instead of the $9.99 subscription, and a cleanup pass
  (5 dead declarations, 2 drifted constants including a missing `988` in
  `send-line-message`'s emergency set, both Swift 6 actor-isolation warnings).
  ⚠️ This stream ran in parallel with the one below and did not know about the
  outbound-SMS pivot; where the two disagreed, the pivot won.
- **08-17/18** Owner asked to "fix everything" toward $2,000/mo (lifetime is
  $273; best month ~$200 net). Three parallel audits (money, first-session
  funnel, number-line pivot) plus the ASA research. **The catalog was 39%
  unfillable**: SMSPVA was retired from routing that morning and the hourly
  `sync-prices` re-activated all 6,305 of its routes the same evening — 5,955
  with no 5sim/HeroSMS fallback. Fixed in code (`SMSPVA_RETIRED` in
  `sync-prices`) and via `blocked_routes` (survives the evidence un-hide);
  15,293 → 8,988 active routes, zero unfillable. **The Apple-lapse leak**:
  the only active→suspended path was an EXPIRED notification, zero had ever
  arrived, and three yearly trials were lapsing in 40h — `reclaim_lapsed_
  lines()` gained a `current_period_end` backstop (20260818110000) 88 minutes
  before the first one. **The watchdog watched no money**: added provider
  RUNWAY (fired at once — 5sim covered ~2.6 days), the credit-line rent
  heartbeat, and the lapse STATE, as a companion function so no existing
  clause was regenerated (20260818120000). **Apple refunds now revoke
  credits** (`revoke_iap_purchase`, one transaction, capped at the balance
  with the shortfall paged — `wallets_balance_check` deliberately kept). **ASA
  keyword rewrite** applied and read-back-verified: 11 second-number/
  authenticator terms paused, `sms verification` resumed, 4 verification
  terms added, first 23 negatives; the €20/day is spent 14.6% because the
  account goes dark 1 day in 3 (both campaigns, identical days — billing, no
  API can show it). **AdServices attribution** shipped end to end (client in
  2.1). **Money settings by owner decision**: signup grant 2 → **0**, free
  email cap 3 → **1**, orphan-number sweep ON, `line.yearly` KEPT on sale.
  **The number line PIVOTED to receive + call out** (see the header) — 2.1
  removes every send affordance, sells international calling on the store
  screen for the first time, and the inbound push now leads with the
  extracted code. Copy corrected the same day: "receives texts from anywhere"
  was FALSE (`international_inbound: false`, unfixable via API) → "US and
  Canadian senders". **First-session fixes in 2.1**: RecoveryScreen's ranked
  retry silently re-ordered the FAILED country (117 users saw it), the hero
  priced and graded a route the button would not buy, no purchase moment
  existed after a delivered code, the paywall dead-ended on a partial
  StoreKit answer, per-provider hold + `retry_after_seconds` in the client.
  **A regression I introduced and reverted the same day**: raising the 5sim
  hold to 155 while shipped 2.0 hardcodes 90 — see the hold section. **2.1
  (build 40) SUBMITTED 2026-08-18 07:29Z — `WAITING_FOR_REVIEW`**, version
  `2a703399-…`, submission `7fa935aa-…`, build uploaded via `altool` with
  `BuildMachineOSBuild` patched to 25F84 (verified inside the IPA), release
  notes patched on all 13 locales. Its last commit before archive added the
  "Not yet" ledger rows (sending texts / receiving from outside US+CA) to the
  store pitch AND the checkout screen, screenshot-verified on both. Read ASC
  for the review state, not this line.
- **08-17** The second-number line met its first real customers and most of it
  did not work. **Voice was provisioned lazily** in `mint-line-token` while
  messaging was provisioned at rental, so five of six sold numbers had no Telnyx
  connection at all and could neither call nor ring — fixed in
  `_shared/lineVoice.ts` (provisioned at rental, repaired hourly by the renamed
  `sync-line-voice`), all 6 lines repaired live. **Two money exploits, both
  introduced the same day by the fixes above them**: the client could settle its
  own live call to zero and keep talking, and `+1900`/`+1976`/Caribbean ranges
  billed against the free minute allowance. **International calling enabled** to
  50 rated destinations (53 Telnyx ISO2s) with the two-gate design and 49
  refusal rows for premium ranges. **Outbound SMS found to be entirely broken**
  (1 sent / 6 failed, `40010`), retracting the "Canada needs no 10DLC" premise
  the launch was built on; sends are now refused up front and the copy no longer
  promises them. Client: the Number tab's hero header, `VoiceReadinessNotice`,
  post-call allowance refresh, one-tap verification-code copy, and 53 error
  messages that had never reached the string catalog. A five-agent adversarial
  audit produced the inbound-calling and subscription findings now in
  Known-open. **Five of six items I had listed as known-open were already
  fixed** — verified by reading the code rather than trusting the list.
- **08-10** eSIM provider switched SMSPool → **eSIM Access** (owner decision;
  line STAYS PAUSED until the ~$50 top-up). New `_shared/esimaccess.ts`
  (probed live: RT-AccessCode-only auth, ×10,000 money units, HTTP-200
  failures, async allocation with 200010=ALLOCATING, esimTranNo-not-iccid);
  `sync-esim-plans` rewritten to 2 calls + fail-loud + the flag-safe
  `REGION_CC` map (regional/global packages included — letter-free synthetic
  codes because `flagEmoji()` strips non-letters and "NA-3" renders 🇳🇦);
  `create-esim-order` gained the prefix gate, a pre-charge balance guard, the
  price echo, an idempotent retry and a two-phase persist (ea_order_no lands
  before the allocation poll); `check-esim-usage` routes on
  `esim_orders.provider` (legacy SMSPool body verbatim for the 12 live rows);
  `delete-account` cancels uninstalled esimaccess profiles (wholesale
  reclaim); `esimaccess_health` written minutely (pages muted while paused)
  and rendered in `/balance`. Migration `20260810160000`: `ea_order_no` /
  `ea_tran_no` / `iccid` columns, `begin_esim_order` stamps
  `provider='esimaccess'`, SMSPool plan rows made un-resurrectable.
- **08-10** 2.0 resubmitted as **build 39** after the 08-09 human rejection
  (3.1.2(c): the checkout's legal links were labeled bare "Terms"/"Privacy",
  tinted like muted text, and pointed at our own terms while the metadata
  declares Apple's standard EULA — now "Terms of Use (EULA)" → stdeula +
  "Privacy Policy", link-tinted, one per line; Guideline 5: China removed from
  territory availability rather than gating CallKit). Same submission
  resubmitted, never cancelled (it carries both subscriptions); the unlock was
  `reviewSubmissionItems {resolved:true}` — recipe in Release prep. The build
  also carries the owner's new pack ladder (8cr/$3.99 `optional` rung,
  12-pack → $5.49, full strict assert) and the review-prompt-on-foreground fix;
  `credits.8` submitted on its own IAP track with a real screenshot from the
  new `-screenshot credits` DEBUG harness. `iap-verify` redeployed with the
  credits.8 mapping. Backed by the day's data reads: activation recovered
  ~8%→~45%/day after the 08-08 grant restore while purchases stayed flat, 50%
  of first purchases are the $2.99 pack, 82% of active wallets sat at 1–5cr.
- **08-08/09** 2.0 (build 37) bounced twice: an automated metadata check
  (EULA link missing from the App Description — fixed same day, resubmitted),
  then the 08-09 human rejection above. Signup grant restored to **2 credits**
  on 08-08.
- **08-06** 🔴 **`sync-5sim` HAD BEEN SEIZING ROUTES IT CANNOT PRICE — 6,900 of
  them, across 115 services, 14 of which had been emptied out of the catalog
  entirely.** The mapping guard tested only the COUNTRY half
  (`if (!pick && !slug) continue`), while `chosen` is keyed by (service,
  country) and populated only from services carrying a `fivesim_product` — so
  every route in a 5sim-mapped country whose SERVICE was unmapped fell through
  to the write path, was stamped `provider='5sim'` / `status='hidden'` /
  `premium_credits=null`, and was counted as a stockout. It could not heal:
  `sync-herosms` reads `.eq("provider","herosms")` and `sync-prices` skips what
  it does not own, so the only sync that would ever read the row again was the
  one that cannot price it. `g2a` is the control — 60 seized, 9 survivors,
  partitioned exactly by the country mapping, on a service the owner had
  DELIBERATELY kept off 5sim. Repaired in `20260806130000` from per-route
  evidence (`herosms_cost_cents` non-null ⇒ HeroSMS, else SMSPVA), returned as
  `hidden` so the owning sync re-prices from live stock. **Active routes 9,358
  → 15,561; invisible services 18 → 5; g2a 9 → 69 active.** Verified after a
  real hourly run that the guard holds (`re_seized = 0`).
- **08-06** Eight more confirmed defects closed after an 8-agent audit with an
  adversarial verification pass (30 candidates → 21 confirmed, 8 refuted; see
  `docs/audit-2026-08-06.md`, which records the refutations too). **The eighth
  close path** (`cancel_order_claim` — cancel-order and create-order's failOrder
  still split claim-and-refund across two round-trips), **`smspva_health` had no
  writer** so create-order's pre-charge guard was permanently disarmed for 1,035
  routes, **`check-esim-usage` un-expired terminal eSIMs** on every view,
  **`delete-account` released nothing but SMS orders** (leaking the rented
  Telnyx number forever while its FK-less tombstone locked the legitimate owner
  out), **`settle_stale_calls` settled calls that were still connected**,
  **`apply_line_renewal` reset an allowance already being spent**,
  **`mint-line-token` reported `inbound_ready: true` with no push credential**,
  and **`iap-verify`'s unknown-product alert told the owner to do the one thing
  that would pay credits on every renewal forever**. Client side: cold-launching
  offline signed users out, the tab bar shipped English to six locales, and
  inbound calls were never recorded at all.
- **08-06** The rented-line lifecycle made survivable. **The cancellation leak**
  (`reclaim_lapsed_lines()` scheduled nowhere, `release-lines` never written —
  $1/month per cancelled subscriber, forever), **the provisioning lockout** (a
  failed activation barred the user from renting again while still paying), and
  **the unsettleable call** (nothing wrote `provider_call_session_id`, so every
  dial cost its full 120s reservation and nothing capped a long call). Plus
  eleven smaller silent paths — a renewal lost to tombstone ordering, Apple
  retries swallowed as duplicates, `sent.parts` discarded, an outage rendering
  as "no numbers available", a float guard degrading to 50 cents, sub-cent
  costs rounding to zero, a voice attach that never retried, an unpaginated CDR
  walk. Verified by `scripts/verify-line-lifecycle.sql` (12 behavioural checks
  in a rolled-back transaction), not by deploy logs.
- **08-06** The Telnyx CDR adapter was wrong TWICE — `filter[date_range]
  [start_time]` and `record_type: "call"` both 400 — and the probe
  instrumentation caught both on its first two real runs. Every valid record
  type is now queried and merged rather than one being cached, because with
  zero calls on the account the first valid type returns `[]` and locking onto
  it would settle nothing forever while reporting success.
- **08-05** Fourth product line STARTED — rentable second numbers with two-way
  SMS + voice (Telnyx, StoreKit subscription). Schema, the `verifyAppleJWS`
  extraction and the Telnyx signature verifier only; unreachable behind
  `lines_paused`. See "Rentable second numbers".
- **08-05** `MIN_MARGIN` made true (`NET_USD_PER_CREDIT` 0.30 → the measured
  0.40, 5sim divisor 0.03 → 0.04); the country row switched from `rate24` to
  `rate168`; e-mail added to the digest / `/stats`; `dev_hidden` so an
  all-dev-orders window stops reading as no activity. 1.9 build 31 confirmed
  `READY_FOR_SALE`, which resolved the starter-list entry.
- **08-04** 5sim freshness ladder (`rate720` lags — see the 5sim section); signup
  grant 1 → 3; the olx/us cohort diagnosed as our own default funnel.
- **08-03** 5sim cutover; IAP P-384 fix; `MIN_HOLD_SECONDS` 180 → 90; pool-rate
  steering; 1.8 build 28 submitted.
- **08-02** Premium orders on HeroSMS routes were priced against SMSPVA's price
  list and refused **3,064 of 4,080** routes with `margin_too_low` — the carrier
  price is now scoped to the provider that HAS the carrier. `sync-herosms`
  repriced from `activations/offers` after `getPrices` was found to advertise a
  price with ZERO stock behind it. Order ceiling made lenient (3× + headroom,
  capped at half of revenue). Every real carrier pinned, not just one. Daily
  credit disabled. All functions redeployed to clear deploy drift.
- **07-31** Per-provider `CREDIT_DIVISOR`; `real_sim_only` routes sold rather
  than gated; six money-path findings fixed and the ledger reconciled across all
  204 wallets; vendor deliverability collected; 1.6 released, 1.7 submitted.
- **07-30** HeroSMS cutover; temp-EMAIL line; support chat; non-destructive ✕ +
  `ResumeBar`; `PurchaseIntent`.

**⚠️ Per-route delivery figures older than 2026-08-03 describe a DIFFERENT
PROVIDER and must be attributed before use.** leboncoin/ro's 9 codes were SMSPVA
on a route later served by HeroSMS; facebook/ch and /cl were smspool. A route id
is not a provider.

**Apple Search Ads: a dead campaign is probably BILLING, and the API cannot tell
you.** Delivery ran €8–15/day through 07-29 then went to exactly zero for two
days. Ruled out `endTime`, budgets, bids, the kill rule and serving state — all
read healthy. `paymentModel: PAYG` plus a previously observed
`CREDIT_CARD_DECLINED` makes it a billing interruption, and Apple exposes **no
billing endpoint**, so the campaign layer keeps reading fine forever. Check
ads.apple.com → Settings → Billing.


## The 5sim cutover (2026-08-03)


**5sim became the primary SMS provider.** New `_shared/fivesim.ts` + `sync-5sim`
(cron :07), per-service ownership resolved in `providerOrder()`, `CREDIT_DIVISOR
0.03` / `MIN_MARGIN 10.0`, and the published pool rate wired end-to-end into the
country picker. See the 5sim, `sync-5sim` and pool-rate sections above.

Also this day, each verified against live DB state rather than a deploy log:

- **CRITICAL — every IAP purchase was being rejected.** `chain_verify_failed`
  on all of them. Root cause was NOT what it first looked like (I initially and
  wrongly blamed local StoreKit signing on a device Release build): the Supabase
  edge runtime does not implement **ECDSA P-384**, so `WebCrypto.verify` threw
  `NotSupportedError: Not implemented` on the Apple root hop. Fixed by verifying
  that hop in pure JS via `@noble/curves/p384`. The pin is still **ROOT ONLY**.
  ⚠️ **Still unconfirmed end-to-end** — no purchase attempted since the fix.
- **The pool picker preferred a published 0% over an unmeasured pool** (844
  routes). Three-tier fix; zero-rated routes 1,184 → 359.
- **Steering fixes** — the ranker read a different table from the row (1,672
  routes), the country tier outranked the pair-specific rate, and new users at a
  0 balance landed on `whatsapp/us` (hidden) showing a disabled "Unavailable".
- **`MIN_HOLD_SECONDS` 180 → 90**, now equal to `PRE_RESERVATION_GRACE_MS`.
- **Ops**: `/balance` shows only 5sim + HeroSMS; `5sim_health` is written (it was
  missing since cutover, so `create-order`'s pre-charge balance guard had been
  failing OPEN); watchdog heartbeat repointed off `smspva_health`.
- **Instrumentation** that immediately paid off: `sync-5sim.fetch_faults` settled
  the 403-vs-429 question on its first run, and `5sim_health.rating` makes the
  account's second kill-switch observable.


## Retention measurements (2026-07-31)

*The two hard constraints these produced — activation is a single-session
event, and cross-day retention is about five people — are kept in the root
file. The measurements themselves are below.*


Re-measured **2026-07-31**, dev account excluded. Funnel: **203** signups → **44**
ordered (21.7%) → **20** got a code → **14** purchased.

⚠️ **THE HEADLINE CLAIM THIS SECTION USED TO MAKE IS FALSE.** It said "13 got a
code → 12 purchased (92%) … delivery *is* the monetization". That 92% was a
small-sample coincidence read as a causal chain, and it does not survive:

- Of the **20** users who have received a code, only **8** ever purchased (40%),
  while **6 buyers never received a code at all**.
- **0 of 14 buyers purchased after their first code.** Ten of the fourteen bought
  **before their first order ever**; three never placed an SMS order (eSIM-only).
- Median signup → purchase is **3.0 minutes**.

**Purchase is a paywall event in the first three minutes, before the user has any
evidence the product works.** Delivery is the PRODUCT; the paywall is the
monetization. The old bucket table (0 codes → 2.1 lifetime orders, 2+ → 14.8)
reproduces, but it is volume accumulating codes, not codes causing volume — and
the direction reverses under test: users whose first order got a code reordered
**37.5%** of the time against **63.6%** for those whose first order did not. That
is correct behaviour for a verification product. The need is satisfied and they
leave.

Two hard constraints on any lifecycle work — both still hold, one nearly vacuous:
- **Activation is a single-session event.** Median signup → first order **123
  seconds**; 41 of 44 within 24h. Softened slightly: **3** users first ordered
  after day one (this file said exactly one). Corroborated by 132 winback nudges
  producing **4 orders (3.0%)**. Chasing never-ordered users with push is
  near-worthless.
- **Every repeat order happens within ~3 days** (146 gaps, max 3.28d) — but the
  MEDIAN gap is **3 minutes**, 125 of 146 gaps are under an hour, and only **8
  gaps in the product's entire history exceed 24 hours, across 5 users**. So
  "repeat order" almost always means retrying in the same session. **Cross-day
  retention in this product is five people.** Any roadmap built on retaining
  returning users is addressing a population that does not exist yet.

**Where users actually die: 159 of 203 (78%) never placed a single order**, 153
of them past the 24h activation window, and only 21 ever reopened the app more
than an hour after signup. They died on the Home screen in the first session,
holding 448 idle credits. That bucket is not reachable by any lifecycle feature —
it is a pricing and steering problem, which is what the 2026-07-31 repricing and
the deliverability steering both target.

Three cohorts, all in `winback` (cron `relay-winback`, daily):
- `winback_candidates` — never got a code. Requires `balance > 0` (it lost that
  predicate once and told 10 users at zero balance that "your credits are still
  here"), dormancy via **`push_devices.updated_at`** (a real "last opened the
  app" signal the shipped build writes on every cold launch), oldest-first, and
  recurs up to 3× at 14-day spacing. The old one-shot version **exhausted its
  pool at 8 candidates**.
- `stranded_credit_candidates` — last order failed, credits idle. Its old gate
  (`recent_user_delivery_rate >= 25`) counted impatient cancels as delivery
  failures, so with 68% of orders cancelled at ~57s it sat structurally at 13 and
  **could never open**. Replaced with a liveness check (provider balance,
  watchdog fresh **and** clean), and the unprovable "delivery just got a big
  upgrade" copy — which is what forced the gate to exist — was deleted.
  **⚠️ That replacement only ever landed in TypeScript.** The audit on
  2026-07-31 found a SECOND gate still live in the SQL —
  `coalesce(recent_sms_delivery_rate(), 0) >= 40` — so the two ran in series and
  the SQL one was shut: that function scopes to `active_sms_provider()`, which
  returned NULL on a 4-order SMSPVA sample while HeroSMS served the traffic, and
  `0 >= 40` is false forever. The cohort had selected **zero** users since the
  cutover and could not reopen, because SMSPVA's share only shrinks. Deleted in
  `20260731070000`; `claimSafe` in `winback/index.ts` is the intended and
  sufficient guard. **The lesson generalises: when you "replace" a SQL predicate
  with an edge-function check, delete the predicate in the same commit** — this
  is now the second cohort-killing gate found by reading `prosrc` rather than
  the migration that supposedly removed it.
- `reorder_candidates` — **users who succeeded.** They were excluded from every
  nudge in the product by construction, despite being the only cohort with proven
  fit. Fires at 3–14 days, inside the observed repeat window.

**⛔ THE DAILY CREDIT IS DISABLED ENTIRELY (owner decision, 2026-08-02,
migration `20260801150000`) — and the CLIENT code is REMOVED as of the 1.8
branch (2026-08-02):** the claim card, banner, AppState state/methods and the
WalletAPI RPC wrappers are gone, `register-push` no longer calls
`claim_daily_credit_for` (it keeps returning `daily_credits: null`, which
shipped builds decode), and coldStart was 5 steps from then until 2026-09-06,
when the rented-line read joined it as the SIXTH (see the Number tab note
below). The no-op DB
functions survive ONLY for 1.6/1.7 users.** 93 grants / 101 credits lifetime, 92 of them in
the final week. Do not re-enable it casually — read the whole of this note first.

It is a KILL SWITCH, not a DROP, because the SHIPPED app (1.6/1.7) calls
`daily_credit_status` and `claim_daily_credit` directly over PostgREST and
`HomeScreen` renders its claim card on `status.available`. Dropping or revoking
those breaks a live build; returning `available:false` makes the card vanish on
its own with **no client release**. Verified every caller tolerates refusal:
`AppState.refreshDailyCredit` uses `try?`, `claimDailyCredit` branches on
`r.granted`, `register-push` branches on `.granted`.

`app_config.daily_credit_enabled` guards all four paths — `daily_credit_status`,
`claim_daily_credit`, `claim_daily_credit_for`, `daily_credit_candidates` — and
**fails CLOSED**, so losing the row cannot silently resume paying. The
`relay-daily-credit` cron is unscheduled. (This line used to claim "15 jobs now,
not 16"; the live count is **16 active**, verified 2026-08-04 — another job was
added after it was written. Re-query, don't quote.) Re-enable recipe
is at the bottom of the migration.

**If you re-enable it, add a tombstone FIRST.** `daily_bonus` was a credit grant
with no tombstone outside the `auth.users` cascade — `profiles.last_daily_credit_on`
cascades on delete, so delete → re-signin re-granted it indefinitely. Disabling
closes that vector; re-enabling reopens it. Key it on `signup_grants.email_hash`,
as the other three grants are. (The ledger has FIVE positive-delta reasons, not
the three this file used to inventory: `winback_bonus` (51 grants) also has no
tombstone, but has no writer anywhere in the repo — a retired path whose enum
value survives.)

*Historical, kept because it explains the shape:* `claim_daily_credit()` reads
`auth.uid()`, null under the service role, so only the app could grant it — which
produced 95–104 pushes/day and **zero claims ever**. `claim_daily_credit_for(uuid)`
was then called from `register-push` on every cold launch, so opening the app
became the trigger. Both share an advisory-lock key and cannot double-grant.


## Default-landed orders were numbers nobody submitted (2026-08-04)


The section above established that the grant picks the route. This settles what
those cohorts actually *did* with it, and it is the reason the grant is now 0.

**The decisive test was manual and takes two minutes.** A deliveroo/us order was
cancelled with ~15 minutes still on the provider's clock. The number was still
visible on the 5sim dashboard, so it was used by hand to start a real Deliveroo
signup — **and the code arrived.** Corroborated the same hour from the other
side: user `45dd50c8` ordered deliveroo/us on `+13025795171` and received a
code in 324s, while `+13025795294` from the same number block expired codeless.

So the pool was never the problem. Neither olx/us nor deliveroo/us was
"failing". Those orders were **free numbers nobody had a reason to use** — the
app handed a brand-new user a phone number they never pasted anywhere, and the
order then expired or was cancelled at the first instant the hold allowed.

**Do not read those orders as evidence about the route.** They are the
strongest form of the warning already recorded above: an order on a route the
user did not choose is not evidence about that route. Here it is worse — they
are not evidence about *delivery* at all, because no verification was ever
attempted. `pool_rate_pct` correlation work must exclude them.

**It was investigated as sabotage and the specific checks came back negative.**
Recorded because the pattern genuinely looks coordinated and will look that way
again: over 30h, 32 signups clustered on one route with zero codes.

| check | result |
|---|---|
| shared devices | **31 distinct push tokens / 32 accounts**; the one reused token dates to 07-30 |
| accounts that never ordered | **19 of 32**, sitting on untouched credits |
| identities with `grant_count > 1` | **0** |
| emails | 19 Apple relay + real distinct icloud/gmail/usa.com addresses |
| paying customers in the cohort | **1** (`7d5c1844`) |
| reopen rate, exposure-matched | **17.9%** vs 0% and 5.4% for older cohorts — *higher*, not lower |

⚠️ **The reopen comparison is easy to get backwards.** The naive cut (any
reopen, all 48h signups) reads 7.1% against 19–25% and looks like a red flag.
That is censoring — most of the cohort has not had a next day yet. Restrict to
accounts ≥24h old and count reopens inside their first 24h and it inverts.
Also note `push_devices.updated_at` only moves on a **cold** launch, so a user
who signs up, orders, waits 500s and quits records a ~1s gap; it measures
return visits, never session length.

**A contributing cause, now fixed, worth knowing for the shape of it:** in
**1.7** the waiting screen's ✕ was `.disabled(holdRemaining != nil || ...)`
labelled *"Cancel available in 180 seconds"*. A user could not leave the screen
to go and paste the number for three minutes. Fixed in `c0b76fc` and shipped in
1.8, so it does not explain the 08-04 cluster — but the cancel distribution
still shows the wall it left behind (nothing under 89s, then a pile at 179,
180, 183, 189, 194, 200, 202, 210, 220, 221, 225).


## Adding services from 5sim's catalog


**5sim offers 1,276 products. We listed 147.** The other 1,133 were absent
because `services` is a hand-built table, not because of anything 5sim does.
**TWO batches of 100 were added on 2026-08-04** (`20260804200000`,
`20260804220000`) — every one became bookable:

| batch | services | active routes | price range |
|---|---|---|---|
| 1 | 100 | 1,945 | 1–66 cr (avg 7.3) |
| 2 | 100 | 1,148 | 1–68 cr (avg 6.2) |

Catalog went 268 → **468** services and 5,905 → **9,312** active routes.
`scripts/gen-fivesim-services.py` does the next batch; **~930 products remain**.

**Coverage per service is very uneven and that is normal.** Of batch 1, 24
services reached 45+ countries while 27 reached only 1–2. Stock is per (service,
country) and `sync-5sim` re-evaluates hourly, so thin services fill in on their
own. Do not read a 1-country service as broken.

**No app release is needed.** The catalog is fetched from the server and
`ServiceLogo` falls back to the favicon cascade for unbundled domains, so new
services appear on shipped builds immediately. Run
`scripts/fetch-bundled-assets.sh --refresh` before the next release to bundle
the logos.

Four traps, each of which fails SILENTLY:

1. **Seed the routes yourself.** `sync-5sim` builds its write set from routes it
   has READ and never inserts — a service with no route rows is invisible to it
   forever. 100 services × 60 fivesim-mapped countries = 6,000 rows.
2. **`routes.status` defaults to `'active'` and `routes.provider` to
   `'smspva'`** — both wrong. An unpriced active route renders "Unavailable",
   and the default provider hands ownership to one with no code for the service,
   because `providerOrder()` resolves ownership from `routes.provider`. Seed
   `hidden` + `'5sim'` and let the sync decide.
3. **`services.smspva_code` is NOT NULL, and you must NOT drop that
   constraint.** `Service.swift` declares `let smspvaCode: String`,
   non-optional, so a null throws on decode and takes the WHOLE catalog down for
   every shipped build. Use `''` — it decodes, and it is falsy in the router.
   Client first, schema second, as with every other column change.
4. **The "missing" set is keyed on 5SIM PRODUCT SLUGS, so a brand you already
   carry under a different slug does not appear in it.** Four did — g2a,
   hepsiburada, grab, claude — and `on conflict (id) do nothing` would have
   swallowed them without a word. Always diff against `services.id` too.

**A country that FAILS a sync run is skipped, not hidden — and you will see it.**
Batch 2's run reported `countries_failed: 1` (germany, 429s) and
`skipped_failed_country: 468`. Germany kept its 112 active routes instead of
being wiped to zero, because sync-5sim distinguishes "we could not read this
country" from "this country has no stock". That distinction is the difference
between a transient rate-limit and deleting a market from the catalog. The
next hourly run picks it up. Also note `fetch_faults` counted 10–12 `429`s per
run at 60 countries — 5sim rate-limits, so do not add more parallelism.

**Re-homing an existing service: country OVERLAP decides, not "do they carry
it".** Claude/Grab/Hepsiburada moved to 5sim (`20260804210000`) and went 7→21,
6→60 and 5→59 active routes — their routes in the 9 countries with no
`fivesim_country` stayed on HeroSMS, so nothing was lost. **g2a was excluded**:
5sim carries it in exactly ONE of our 60 countries against the 9 it serves on
SMSPVA, so the swap would have cut it to a ninth of its coverage.


## Resolved issues — the former Known-open log

*Kept verbatim. Each was open long enough to be worth a record of how it
was diagnosed; several were also WRONG for days while reading as fact,
which is why the root file now carries a re-verify rule.*


✅ **A SUBSCRIPTION COULD EXIST AT APPLE WITH NO TRACE IN OUR DATABASE — FIXED
2026-09-08, and it cost a real refund first.** Original transaction
`700002748363888` — a $59.99 yearly bought 2026-08-22 — carried four Apple
notifications and **zero** rows in `line_subscriptions` and `phone_lines`. Our
own `verify-line-subscription` call never landed, so nothing said which account
paid: `ensureSubscriptionRow` attributes from a LINE, and there was no line.
The customer received no number, was billed on the billing-recovery retry
seventeen days later, cancelled within 80 minutes and was refunded — correctly.

**Why every recovery this product had was insufficient.** They were all
client-side: `SubscriptionStore.handle` deliberately leaves the StoreKit
transaction unfinished so `IAPStore.restorePurchases()` sweeps it on the next
launch. That is right and it is not enough — **it requires the user to reopen
an app that has given them nothing.** This one never did.

Three halves, all landed together; none works alone:
- **`appAccountToken` on every purchase** (`VirtualSIM/IAP/PurchaseOptions.swift`,
  used by all three stores). Apple echoes it back on every later signed
  transaction, so a notification alone can name the account. ⚠️ It is CLIENT-set,
  so it is a fallback and never an override: a line we actually sold is the
  proven attribution and still wins. A token that is not a UUID present in
  `profiles` attributes NOTHING — a dangling `user_id` is the guessed
  attribution this code has always refused to invent.
- **`ensureSubscriptionRow` / `ensureMailSubscriptionRow` read it** when no line
  exists. The mail one keeps its retry-throw as the last resort, because Apple's
  retry ladder ends after a few days and a permanently failed purchase call
  otherwise leaves a paying subscriber with no row forever.
- **`line_reprovision_target(p_original_tx, p_allow_first)`** (migration
  `20260908150000`, DROP + CREATE — the argument list changed, and an overload
  makes PostgREST refuse the RPC). With `p_allow_first` the renewal path now
  also provisions a subscriber who NEVER held a number. 🔴 **The SQL still
  refuses it for the first 30 minutes**, so it can never race our own client
  call, which owns the first purchase and lets the user pick their own number;
  past that window the client call is not coming. `country_code` is null on a
  first provision and the caller's existing `DEFAULT_LINE_COUNTRY` fallback
  covers it, behind the same fail-closed sellability gate.

✅ **AND IT ALSO FIRES ON A TIMER — `rescue-unprovisioned-lines`, cron
`relay-rescue-unprovisioned-lines` at :08/:23/:38/:53.** The notification path
alone was not enough: a yearly whose only Apple event is INITIAL_BUY would have
waited up to a year. The sweep reads
`line_unprovisioned_subscriptions(p_min_age_minutes, p_limit)` and provisions
through the same `provisionForSubscription` the notification path uses, so a
paid subscriber with no number is fixed within ~15 minutes with no user and no
notification.

🔴 **The provisioning glue lives in `_shared/lineProvision.ts::
provisionForSubscription` and must not be copied again.** It was the FOURTH
instance of "gate the country, pick a number, take the mutex, finish the
sequence", and the third copy of the sequence itself is why five of six sold
lines could not make a call. Callers keep only the alerting, which is the part
that genuinely differs (a notification pages per delivery with a dedupe ref; a
sweep summarises a run). `apple-notifications` imports no catalog code at all
any more.

Every guard is in SQL so it holds however the function is invoked: Production
only, entitlement live now, no live Apple-billed line (the same predicate as
`phone_lines_one_apple_line_per_user`, so a candidate is always one
`begin_line_rental` accepts), older than 30 minutes, and **ONE ATTEMPT PER
DAY** — `failed` sits outside that partial index by design so a retry CAN
succeed, and without the throttle a permanently broken subscription would buy a
$1 number every fifteen minutes. `begin_line_rental` is still the mutex; the
loser is silent.

**Watchdog: `line-rescue-stale` (heartbeat, `app_config.
line_rescue_heartbeat`) and 🔴 `line-paid-no-number` (the STATE — is anyone
paying for a number they do not have).** The second is the load-bearing one and
fires even if the heartbeat is never written, which is exactly the case that
ships broken; `sync-telnyx-cdr` ran green for twenty days matching nothing
because only its heartbeat was checked. Both were proven to FIRE in a
rolled-back transaction, not merely to exist.

⚠️ **The client half ships with the next build**, so purchases made by 2.10 and
earlier remain unattributable if their verify call fails — for those, the sweep
is the only recovery, and it depends on a `line_subscriptions` row existing.
⚠️ **A rescue needs Telnyx float**: below the balance floor an order is refused
outright and the sweep pages `line-paid-no-number` instead of fixing it.
Behavioural checks: `scripts/verify-line-first-provision.sql` (8 groups, rolled
back, including the 30-minute race guard and the one-attempt-per-day
throttle).


⚠️ **THE SECOND-CODE RESEND WINDOW HAS NEVER DELIVERED A SECOND CODE.**
Shipped 2026-09-08 (see the `markSuccess` gotcha). Everything about it is
verified except the thing that matters: 5sim's multi-SMS pool list is their
published claim, and no second code has yet arrived on any of them. **The
first `resend_promoted` line in the `poll-active-orders` logs is the proof.**
Until one appears, treat the ~58%-of-delivered-codes coverage figure as
unverified, and note the cost of the list being wrong is real but bounded —
we hold an already-paid-for number open for five minutes and show the user a
countdown for a code that cannot come. Re-derive coverage rather than quoting
it: `select operator_used, count(*) filter (where otp is not null) as codes
from public.orders where provider='5sim' and smspva_number is not null and
created_at >= now() - interval '30 days' group by 1 order by codes desc;`

⚠️ **HeroSMS can request another code on the same number and NOTHING CALLS
IT.** `_shared/herosms.ts:645` defines `STATUS_RETRY = 3` — commented
"request another code on the SAME number (free)" — with a wrapper at line 677
and no caller anywhere in the repo, the same shape as the six
`line_subscriptions` updaters that shipped with no INSERT. It was left out of
the 2026-09-08 resend work deliberately: it is an explicit *request another*
verb rather than a hold-open, so it needs its own semantics, and HeroSMS
delivered 3 codes in the trailing 30 days. Worth doing when its volume
justifies it.

⚠️ **The e-mail subscription's retroactive lifetime wall would end the app's
highest-volume surface, and shipping it or parking it is an owner decision
still outstanding (2026-08-19).** Measured 2026-08-19 over the trailing 14
days: **178 orders / 54 users / 159 free**
(`select count(*), count(distinct user_id), count(*) filter (where
cost_credits = 0) from public.email_orders where created_at >= now() -
interval '14 days';` — re-run before quoting, this moves daily). Once
`email_subscription_enforced` flips true, every non-subscriber who has
already used their one lifetime free address (`email_free_lifetime_grants`)
is walled immediately, with no grace period — this is not a future cohort, it
is most of the existing one. Two
independent reversal levers exist and are worth keeping straight: the wall's
**size** (`email_free_lifetime_grants`) is live config, reversible with one
UPDATE and no deploy; the **per-day-vs-lifetime rule itself** is a migration
(`20260818160001`), reversible only by shipping another one. The owner has
been advised the line is worth roughly **$1–15/month net** on current volume
(measured: ~56 users/month would hit the wall — i.e. exhaust their one
lifetime free address and see `subscription_required` — which is the pool any
conversion has to come from, not a conversion count itself; the app's own
subscription history elsewhere in this product is 7 sold / 5 cancelled within
minutes — see "Rentable second numbers" — which is the base rate any
mail-subscription conversion estimate should be discounted against). Recorded
as a measurement with its date, not as a recommendation.

⚠️ **A subscriber's "unlimited" free addresses still depend on free-domain
stock that runs dry, and there is now NO paid fallback at all.** The free tier
(`outlook.com`/`hotmail.com`) is the scarcest inventory in the catalog —
measured as low as **two available** for a domain in one sweep (see "There is
no catalog to sync" above) — and that is unrelated to and unfixed by paying
$2.99/month. A subscriber who hits a dry free domain gets exactly the same
`domain_unavailable` refusal a non-subscriber gets. The old open question
("fall back to the 1-credit gmail tier for subscribers?") is moot since
gmail.com was removed from sale on 2026-08-26 for delivering nothing — if a
paid tier ever returns, the fallback question returns with it. As of 2026-08-26
the mail subscription's ENTIRE inventory is the two free domains.

⚠️ **`revenue_snapshot` counts credit packs only, and now omits TWO
subscription revenue streams, not one.** This is pre-existing for the line
(see the "🔴 `/revenue` AND `/profit` REPORT $0 FOR THIS PRODUCT" comment
above `formatLinesMoney` in `_shared/opsFormat.ts`) and this task does not fix
either — recorded here so it is not silently inherited as new scope.
`/revenue` and `/profit` understate by every subscription dollar, mail
included, until both read `line_subscriptions` and `email_subscriptions`
alongside `iap_receipts`.

✅ **OUTBOUND SMS WORKS (NANP→NANP) — PROVEN OFF-NET 2026-09-08**, from the
app on a physical device to the owner's own US mobile on a real carrier, with
no 10DLC brand and no campaign on the account. The on-net probe below came
first and was correctly treated as weak; the off-net send is the evidence.

🔴 **TEXTING OUTSIDE NANP IS GENUINELY BLOCKED — SETTLED BY EXPERIMENT
2026-09-08, and the cause is NEITHER of the two flags this file blamed.**
Two real sends from a US number we own to the owner's own French mobile,
before and after adding FR to the profile whitelist, both returned:

```
40306  Alpha sender not configured
       The messaging profile doesn't have an associated alphanumeric sender ID.
```

- **The whitelist is NOT the blocker.** `whitelisted_destinations` was
  `["CA","GB","US"]`; FR was added, read back as `["CA","FR","GB","US"]`, the
  send was retried, and **the error was byte-identical**. The whitelist was
  then reverted, leaving the account as found. So "our own setting is the
  limit" — which this file asserted for a few minutes on the strength of GB
  being in that list — is **wrong**, and the correction is the point: a
  plausible mechanism that explains the symptom is not the mechanism.
- **`features.sms.international_outbound: false` is not what fires either.**
  The refusal happens at the messaging profile, before the number's own
  capability is consulted.
- **What it actually means:** France (like most of Europe) will not accept a
  foreign long code as an A2P sender, so Telnyx wants an **alphanumeric sender
  ID** for that destination. An alphanumeric sender is **ONE-WAY** — the
  recipient sees a brand name instead of the user's number and **cannot
  reply** — so configuring one would not give this product international
  texting. It would give a different product. It is also pre-registered
  per-country in much of Europe.
- **Conclusion: NANP → NANP is the honest boundary**, and `_shared/nanp.ts`'s
  up-front refusal of non-NANP destinations is correct — not as a guess, but
  because the alternative spends a hard-stop allowance segment to buy a 40306.
  Re-test with `probe-telnyx-connection` mode `send_test` before ever
  widening it.

⚠️ **`daily_spend_limit` on the messaging profile is `$20.00/day`, account-wide
across ALL messaging — raised from $2.00 on 2026-09-08 (owner decision), read
back from Telnyx.** The $2.00 was set while sending was retired, and with
sending live it was a product outage waiting to happen: the cap is shared by
every subscriber, so ONE user in a loop exhausts it and stops everyone's texts
until midnight. $20 is a SAFETY rail, not a budget — at ~$0.004/segment it is
~5,000 messages/day, far above the 17-subscriber allowance total. Read or
change it with `probe-telnyx-connection` mode `messaging_profile` (reads
back); there is no other writer, so this file and Telnyx can drift — re-read
before quoting.

⚠️ Note the cap is not the binding constraint at a low **account balance**:
Telnyx refuses a number order at `20100 Insufficient Funds` and messaging
stops with no money regardless of the limit. Both are worth checking when
"texts stopped working".

**What the 2026-08-17 verdict actually measured.** Lifetime outbound was
called "1 sent / 6 failed"; `line_messages` holds **4 rows** (1 `sent`, 3
`failed`), every one from **`+14377832487`, a CANADIAN number, on one evening,
to US numbers**, every one `40010: The sending number is not 10DLC-registered`.
Canada was then the only country we sold, so "cross-border fails" and "sends
from a Canadian longcode fail" were the SAME observation wearing the more
general name — and it was generalised to "outbound does not work". **No US
number had ever attempted a send.**

**What is now measured.** 2026-09-08, a fresh US number → a CA number we own:
**delivered, no errors**, and the inbound webhook landed it in the recipient's
app. 🔴 **ON-NET — both endpoints are numbers on our own Telnyx account — so
it may never have crossed a carrier's spam or registration filter. It is
strong evidence AGAINST a total block and weak evidence FOR delivery.** One
delivery is not a delivery rate; that exact error produced the original wrong
conclusion (`.claude/rules/providers.md`, the 2026-08-05 CA send).

**The registration state, read live and not inferred** (`app_config.
telnyx_messaging_probe`, written by `probe-telnyx-connection` mode
`messaging`): **`messaging_campaign_id` is NULL on all 12 numbers**, there is
no 10DLC brand and no campaign on the account, `messaging_product` is `A2P`
everywhere, `features.sms.international_outbound` is **false** on all 12, and
the messaging profile's `whitelisted_destinations` is `["CA","GB","US"]`.
Telnyx's error reference defines **`40010` as exactly "the sending number is
not attached to a 10DLC campaign"**, so an off-net US A2P send is refused by
the destination carrier by design.

**The NANP policy in `_shared/nanp.ts`** — NANP is ONE bloc (PR and VI are US
area codes; `isNanpNumber` tests the bloc, `nanpCountry` is only a US/CA
*label* and reports PR/VI as US): NANP→NANP allowed; NANP→anything else
refused `international_sms`; an unknown sender country still fails open.
The international refusal is a **capability** check, not a policy guess —
`international_outbound` is false on every number we own, so attempting one
spends a hard-stop allowance segment to buy a certain failure.

⚠️ **THE DECISIVE TEST IS STILL OUTSTANDING: one send to a REAL HANDSET on a
real carrier, off-net.** Until it passes, treat sending as unproven, and note
the client ships a composer regardless (owner decision) with an honest
per-message failure state rather than a promise. `probe-telnyx-connection`
mode `send_test` performs a send between two numbers we own (both endpoints
are verified against Telnyx's inventory, so it can never text a stranger);
modes `order_test_number` / `release_number` buy and drop a $1 disposable
number, because every number on the account but one belongs to a paying
subscriber and testing into their inbox is not ours to do.

**If it fails off-net, the paths are 10DLC or toll-free, and both need an
approvable use case** — researched against Telnyx's docs 2026-09-08:
Sole Proprietor is **one campaign, one number** (useless for a fleet);
Standard 10DLC wants an EIN and has **no named P2P / "second number" use
case** (nearest is "Mixed"); the documented architecture for our shape is a
**partner/ISV shared campaign**, which Telnyx routes to their team rather than
self-service. Toll-free verification is ~5 business days with a
"Conversational/Alerts" use case. None of these confirm that "consumers rent a
number and text whoever they like" is approvable — that is genuinely
unaddressed by the public docs and needs a conversation with Telnyx.

✅ **INBOUND CALLING WORKS — 2026-09-08, verified on a physical device with
the app OPEN and with the app CLOSED, using a real PSTN call from one of our
own Telnyx numbers to a rented line. The first ringing phone in the product's
history.**

**The architecture, and why it is this shape.** Telnyx refuses to route a DID
to an on-demand telephony credential — *"inbound calls directly to on-demand
generated credential is not currently supported … purely for outbound
calls"* — but explicitly supports **dialing that same credential from Call
Control**. Both sentences are in the same support article
(support.telnyx.com/en/articles/7029684-telephony-credentials-types), and
reconciling them is what four attempts missed. So:

    PSTN → number → Call Control application
         → telnyx-webhook `call.initiated` (direction "incoming")
         → transfer to sip:<registered sip_username>@sip.telnyx.com

Provisioned by `provisionLineVoice`, so a number sold tomorrow rings with
nobody touching Telnyx. All 12 owned numbers are on it, read back.

🔴 **Rules that are load-bearing, each one a bug that shipped today:**
- **TRANSFER, never ANSWER.** Answering bills us and replaces the caller's
  ringback with silence.
- **The transfer's `from` MUST be a number we own.** With the real caller's
  number Telnyx returns 200, raises `call.bridged`, and silently drops the
  leg. The caller travels as `from_display_name`.
- **Dial whichever identity is REGISTERED, never a hardcoded one.** Builds
  ≤ 2.11(54) register as the telephony credential `gencred…`; 2.11(55)+ as
  the credential connection's own user `vsms…`, and the client falls back
  between them. `registeredSipUser` asks Telnyx. **This is why existing App
  Store users need no update.**
- 🔴 **`handleInboundCall` must select `provider_connection_id`.** Omitting it
  made `registeredSipUser` skip the connection user entirely and fall back to
  the wrong credential on every call — the final bug, and it produced exactly
  "a missed call in Recents that never rang".
- **`sip_uri_calling_preference` is TOP-LEVEL** (under `inbound` it 200s and
  sets nothing — the fourth silent no-op in this adapter, after
  `messaging_profile_id`, `outbound_voice_profile_id` and this). **"internal",
  never "unrestricted"** — the latter lets anyone who guesses a username ring
  a paying subscriber.
- **Re-attach on the number's LIVE connection, not on
  `provider_voice_attached`.** That flag predates Call Control, so every line
  sold before today reads "attached" while pointing somewhere that cannot
  ring; comparing the live value is what makes `sync-line-voice` self-healing.
- **Inbound reserves ZERO allowance.** The caller pays their own carrier.
- **A Call Control application needs an outbound voice profile to PLACE a
  call** (403 / D38). That affects only the `ring_number` test probe — real
  inbound transfers go to a SIP URI and need no profile.

✅ **Inbound history closes from Telnyx's own events (2026-09-08).**
`telnyx-webhook`'s `call.answered` / `call.hangup` branches call
`close_inbound_call_claim(p_session, p_event, p_at, p_hangup_cause)`
(migration `20260908210000`). Before this an inbound call sat `ringing` until
the six-hour backstop relabelled it, and a call nobody answered was
indistinguishable from one still in progress.

🔴 **IT MOVES NO MONEY AND MUST NEVER MOVE ANY.** It writes only status /
`answered_at` / `ended_at` / `duration_seconds` / `hangup_cause`, and its
`direction = 'inbound'` predicate is a SAFETY ASSERTION rather than a lookup
aid — the session key is already unique, so the predicate exists purely to make
the function structurally unable to touch an outbound row whose minutes and
credits are real. It also refuses a row carrying any reservation
(`not_free_inbound`).

Two behaviours that are not derivable from the code: **both legs of one call
raise both events and Telnyx redelivers**, so every call reaches this at least
four times — the first event to find a non-terminal row wins and every later
one is a no-op, which is also what makes an out-of-order delivery safe. And **a
hangup with no answer is a MISSED call, never a zero-second answered one**;
"answered for 0s" reads as a fault, and nobody-picked-up is the common inbound
outcome. `unknown_call` is ordinary, not a fault: our own outbound legs share
this event stream and match no inbound row. Checks:
`scripts/verify-inbound-call-close.sql` (rolled back, with a negative control).

⚠️ The `occurred_at` timestamp is read from the ENVELOPE (`data`), not the
payload, and is NOT verified against a live call event — the SQL falls back to
its own `now()` on a null or absurd stamp, which for a webhook arriving seconds
later is accurate either way.

*Historical below — the four failed attempts, kept because three of them are
documented dead ends and the reasoning shows how the wrong layer was blamed
for five weeks.*

🔴 **THE CAUSE OF INBOUND WAS THOUGHT TO BE THE LOGIN CREDENTIAL ON
2026-09-08, AND THAT WAS ONLY HALF RIGHT.** The app logged in with a token minted from an
**on-demand telephony credential**. Telnyx documents that credential type as
outbound-only, verbatim: *"inbound calls directly to on-demand generated
credential is not currently supported. The purpose for on demand generated
credentials is purely for outbound calls."*
(support.telnyx.com/en/articles/7029684-telephony-credentials-types)

**Measured, not reasoned.** `mint-line-token` returned 200 at 19:15:16 and an
inbound call arrived at 19:15:25 — the app was connected. At that moment
`GET /sip_registration_status?username=<u>&credential_type=<t>` read:

| identity | registered |
|---|---|
| `telephony_credential` `gencredz…` (what the app logged in as) | **true**, 19:15:17 |
| `sip_credential_connection` `vsmsvsms…` (what the DID points at) | **false**, `"trying"`, never |

Telnyx then produced **8 sessions in 9 seconds**, every one `sip-trunking`
only, `call_sec 0`, `NORMAL_CLEARING`, **no `webrtc` record at all** — the
call never reached the WebRTC gateway because there was no registered contact
to send it to. A second test at 19:59 produced 18 sessions in 21 seconds,
identical.

**The fix (2.11 build 53, on TestFlight 2026-09-08, UNVERIFIED by a real
call):** `mint-line-token` returns the connection's own
`sip_username`/`sip_password` **alongside** the token — the token stays, because
shipped builds ≤ 2.10(52) read only `token` and dropping it would remove
OUTBOUND from every live user. `VoiceCredential` is the client seam; `.sip`
registers and can be rung, `.token` authenticates and never can.
`VoiceCredentialStore` prefers `.sip` with **no expiry check** (it is a
long-lived connection user, not a JWT) — preferring a still-valid token there
would rebuild the exact bug. `inboundReady` is now the CONJUNCTION of the
server's provisioning and whether the login can register at all.

⚠️ **Rotation was rejected for now**: the client mints more than once per cold
launch (measured 13 s apart), so rotating per mint would invalidate the
registration the previous mint just made. The password is therefore
long-lived and on the device, bounded by the per-line `daily_spend_limit`.

❌ **DISPROVED THE SAME DAY — do not retry:** setting the number's
`translated_number` to the credential username. Applied to a real line, read
back, called: identical 18-session teardown, reverted. Routing follows the
connection's registration, not the header.

*History below, kept because the client defects were real and the reasoning
shows how the wrong layer was blamed for a month.*

🔴 **INBOUND CALLING DOES NOT WORK — verdict 2026-09-07 (three Opus
audits: server provisioning vs Telnyx docs, client vs the resolved TelnyxRTC
4.1.2 source, live Telnyx read-backs; the owner asked for a verdict after
asserting 2.10 "even receives").** The decisive evidence is the new
`inbound_cdr` probe: **155 inbound detail records / 116 sessions in 30
days, EVERY ONE `call_sec 0`, `answered_at null`, no `webrtc` leg** — 98 to
the released probe number `+14153293816` on 08-17 (`NO_USER_RESPONSE`), and
**13 real sessions to sold lines** (`+14375243093` ×8 incl. the owner's own
test calls from `+33…` on 09-06, `+14377825495` ×2, `+19295423486`,
`+19295080350` from the number it had just called, `+14377826026`), all
`NORMAL_CLEARING` at 0 s. `line_calls` holds 0 inbound rows against 152
outbound. So it is NOT "untested": real people, including the owner, have
called sold numbers and nobody's phone connected. Re-derive:
`POST {"probe":"inbound_cdr"}` then `select value->'by_direction',
value->'sessions_unknown_inbound' from app_config where
key='telnyx_inbound_probe'`.

**The server half is CORRECT and is not the cause** (read back, not
inferred): all 9 live numbers carry `connection_id` = their line's credential
connection; all 9 connections read `active: true`,
`ios_push_credential_id = 65804c06-…` top-level (the documented field), the
outbound profile nested; that credential is `type ios`, alias
`com.anthersystems.VirtualSIM`, NOT `is_public`, cert `UID
com.anthersystems.VirtualSIM.voip` valid **2026-08-06 → 2027-09-05**; the two
Telnyx demo credentials are attached nowhere. A credential connection needs
no Call Control app or webhook for inbound. Server defects that remain (none
sufficient to explain the 0): `attachVoiceConnection` records a 200 with no
read-back (`_shared/telnyx.ts` ~958, the same class as the 12-day outbound
outage); **`ensurePushCredential` is NOT run hourly** — `sync-line-voice`
calls `provisionLineVoice` only for rows its "broken" predicate matches,
which is 0 rows today (`repaired: 0`), so the sentence below this section
claiming the hourly heal was FALSE; nothing validates the credential id is
ours or watches the cert expiry; `sync-line-voice` has no watchdog check
(`pg_proc` has no reference to `line_voice_sync`).

**The client half is where it breaks — 2.5 through 2.10 all carry this
code (`VirtualSIM/Calling/TelnyxVoiceClient.swift`, `CallController.swift`):**
1. 🔴 **A push into an app that is not already connected is never handed to
   the SDK.** `TelnyxVoiceClient.handleVoIPPush` does `guard let token =
   _voiceToken else { return }`, and `_voiceToken` is set only by
   `connect(token:)`, in memory, on an instance rebuilt every launch. On a
   VoIP push into a terminated app it is nil, `processVoIPNotification` is
   never called, no socket, no login, no INVITE; CallKit rings, Answer →
   `Fault.noActiveCall` → `action.fail()`. Its own comment admits it. Fix
   shape: report to CallKit synchronously, THEN `await mintVoiceToken()`,
   build `TxConfig`, `processVoIPNotification` — the async part is legal
   after `reportNewIncomingCall`.
2. 🔴 **`CXAnswerCallAction`/`CXEndCallAction` call `currentCall?.answer()` /
   `.hangup()` instead of the SDK's `answerFromCallkit(answerAction:)` /
   `endCallFromCallkit(endAction:)`**, which exist precisely to park the
   action until the push-triggered login delivers the INVITE
   (`TxClient.swift` ~1420: `if answerCallAction != nil { call.answer…;
   fulfill }`). Even with (1) fixed, an answer before the INVITE lands
   (~0.5–2 s) fails, and a decline never sends `decline_push` so the caller
   keeps hearing ringback.
3. 🟠 **The app logs in to Telnyx ONLY from `LineScreen` / `DialerScreen`
   `prepareVoice()`** — never on cold launch. Telnyx docs: "You will need to
   login at least once to send your device token to Telnyx before start
   getting Push notifications." A rotated PushKit token reaches our
   `push_devices` but not Telnyx until the tab is reopened; `disconnect()`
   has NO caller, so sign-out never unregisters.
4. 🟠 **A push-launched call writes no `line_calls` row**:
   `registerInboundCall` needs `apiClient` + a restored access token, both
   of which race process start, and the failure is swallowed — which is why
   the DB shows 0 while Telnyx shows 116.
5. 🟡 `TxConfig` never sets `enableMissedCallNotifications` (default false),
   so Telnyx sends no "Missed call!" push and the dismissal code is dead: a
   caller who hangs up leaves CallKit ringing until iOS times out.
6. 🟡 `InCallOverlay` has no Answer button (in-app you can only hang up a
   ringing call); `processVoIPNotification` throws are swallowed into
   `_lastError`.
Verified correct, do not "fix": `reportNewIncomingCall` IS synchronous
before any await; `PKPushRegistry` + `CXProvider` are created in
`AppDelegate` (AuthGate only adopts); payload keys match the SDK resolver;
built plist carries `audio` + `voip`; `provider(_:didActivate:)` hands the
session to the SDK without `setActive`. The 2.5 list below is what was
fixed then and is still true.

✅ **(1)–(5) ARE FIXED IN BUILD 52 (2.10, submitted 2026-09-07 07:56Z,
`WAITING_FOR_REVIEW`; also in internal TestFlight) — UNVERIFIED ON A DEVICE
at submission.** Nothing below has been proved by a real call; the
build is green and the reasoning is against the resolved 4.1.2 source, which
is exactly the evidence that was not enough last time. What changed:
- **`VirtualSIM/Calling/VoiceCredentialStore.swift` (new)** persists the
  minted credential in the Keychain (`kSecAttrAccessibleAfterFirstUnlock…`,
  readable while locked) with its JWT `exp`, so a terminated app has a
  credential BEFORE it has a session. `CallController.performPushHandoff`
  tries the stored token first, then mints with 3 bounded retries (a cold
  launch restores the session AFTER the push lands), then — if both fail —
  ends the CallKit call `.failed` rather than leaving it ringing mute.
- **`answerFromCallkit` / `endCallFromCallkit`** now carry the CallKit
  actions, but ONLY on the push path (`_fromPush` in `TelnyxVoiceClient`).
  🔴 They must NOT carry the others: `endCallFromCallkit` FAILS an action
  whose UUID it does not hold (`TxClient.swift:927-930`), and an outbound
  call's CallKit UUID is ours alone — routing outbound through it would make
  ending a call impossible. `CallKitHandoff` says who fulfills; fulfilling
  twice and fulfilling never are both real bugs.
- **The app logs in to Telnyx at launch** whenever a line `canReceive`
  (`ContentView.connectVoiceIfLineIsLive`, behind the reveal), re-logs in
  when the PushKit token rotates while connected (Telnyx only learns a token
  from a LOGIN), and `releaseVoice()` disconnects + clears the credential on
  sign-out and when the last receiving line goes. `prepareVoice()` now
  serialises concurrent callers — there are four entry points and two fire in
  the same second of a cold launch.
- `enableMissedCallNotifications: true` on every `TxConfig`, which is what
  makes the existing dismissal code reachable at all; `registerInboundCall`
  retries 3× instead of swallowing the `.notAuthenticated` a push-launched
  app is guaranteed to get; `processVoIPNotification` failures are printed.
- **(6) was deliberately NOT done** (owner/coordinator decision): CallKit is
  the answer surface, `InCallOverlay` is unchanged.

**Device protocol once (1)–(3) are fixed:** Test C first — force-quit, call
the number, Answer; expect `TxClient:: processVoIPNotification` in the
console, a `line_calls` inbound row, and a `webrtc` inbound record at
Telnyx. Test A (foreground on the Number tab) is the only path that can
work TODAY. A simulator cannot receive a PushKit push, so the first real
inbound call on a physical device is the probe. Watch for: the phone rings at
all, the CallKit screen shows the caller's number, a `line_calls` row with
`direction='inbound'` appears, and a missed call dismisses instead of ringing
forever. What was fixed, each matched against the resolved TelnyxRTC 4.1.2
source (not docs):

1. **`onIncomingCall` now reports to CallKit** via a new
   `VoiceClientDelegate.voiceIncomingCall`, using the SDK's own
   `callInfo.callId` as the CallKit UUID; guarded on `phase == .idle` so a
   push that already reported the same call cannot double-report.
2. **The push payload is parsed with the keys Telnyx actually sends** —
   `metadata["caller_number"]` / `caller_name` / `call_id` (old `from`/`uuid`
   kept only as fallbacks; `call_id` lowercased, the `providerSessionId`
   convention), so the caller renders and `registerInboundCall` finally gets a
   non-empty peer.
3. **`PKPushRegistry` + `CXProvider` are created at process start** —
   `CallController.shared` built in `AppDelegate.didFinishLaunchingWithOptions`,
   adopted by `AuthGate`. Consequence handled: the one-shot VoIP token can now
   arrive before sign-in, so it is buffered (`pendingVoIPToken`) and flushed in
   `attach`.
4. **Dismissal pushes ("Missed call!" / "Answered Elsewhere") do
   report-then-immediately-end** — Telnyx's own prescribed workaround, since
   iOS requires every `.voIP` push to report a call. The alert STRING is the
   only signal; there is no structured flag.

`mint-line-token`'s `inbound_ready` is fixed the same day: it now requires
`provisionLineVoice`'s **read-back** proof that the connection genuinely holds
the iOS push credential (`ensurePushCredential` in `_shared/telnyx.ts` — the
verify-and-repair twin of `attachOutboundProfile`). ⚠️ **It is NOT run
hourly** — this said "run on every line every run, so hourly
`sync-line-voice` heals any push-less connection" until 2026-09-07, and that
was false: the sweep reaches `provisionLineVoice` only for rows its broken
predicate matches (0 today). A push-less connection is repaired only when
its owner opens the Number tab. The env var alone no longer counts.


✅ **RESOLVED 2026-08-06 — `TELNYX_IOS_PUSH_CREDENTIAL_ID` EXISTS AND POINTS AT
OUR OWN CERTIFICATE.** Credential `65804c06-85e1-4467-b868-818e9e370ac8`, alias
`com.anthersystems.VirtualSIM`, carrying a VoIP Services Certificate with
`UID=com.anthersystems.VirtualSIM.voip`. Secret set and `mint-line-token`
redeployed (v6). *Original:* the var was unset, and
`createCredentialConnection` spreads `...(opts.pushCredentialId ? {…} : {})`,
so it silently omitted the field rather than failing — every credential
connection was built without VoIP-push capability and no inbound call could
wake the device.

⚠️ **IT EXPIRES 2027-09-05, AND THE FAILURE IS SILENT.** A VoIP certificate
lasts a year; when it lapses, Telnyx keeps accepting the connection and the
phone simply never rings. Nothing in the app or the API reports it. Renew in
the Apple portal against the SAME private key
(`~/Desktop/telnyx-voip/voip.key`, outside the repo — losing it means the
certificate cannot be re-paired).

🔴 **THE ACCOUNT SHIPS WITH TWO DECOY PUSH CREDENTIALS. DO NOT USE THEM.**
`GET /v2/mobile_push_credentials` lists `ios-native-new-march-2025` and
`android-native-new-march-2025`, both `is_public: true` — they are TELNYX'S OWN
DEMO credentials. The iOS one is issued to `com.telnyx.webrtcapp.voip` / "Telnyx
LLC" and **expired 2026-04-12**. Pointing the secret at that id would make
`mint-line-token` report `inbound_ready: true` while every push went to the
wrong topic on an expired certificate — the exact shape of failure this repo
keeps paying for. Ours is the one whose certificate subject names OUR bundle id;
check the subject, never the alias.

⚠️ **Apple's API CANNOT create this certificate — do not go looking.** Probed
2026-08-06: `POST /v1/certificates` with `certificateType: VOIP_SERVICES`
returns 409 enumerating the valid values, and VoIP is not among them
(`APPLE_PAY*`, `DEVELOPER_ID*`, `DEVELOPMENT`, `DISTRIBUTION`, `IOS_*`,
`MAC_*`, `PASS_TYPE_ID*`). The web portal is the only route. The CSR **can** be
generated with `openssl` though, which skips Keychain's Certificate Assistant
and the `.p12` export Telnyx's docs describe:
`openssl req -new -newkey rsa:2048 -nodes -keyout voip.key -out voip.csr -subj …`
Telnyx wants the key as **PKCS#1** (`BEGIN RSA PRIVATE KEY`), so
`openssl rsa -in voip.key -out key.pem` is mandatory — `openssl req` writes
PKCS#8 and the upload fails on it. `scripts/finish-telnyx.py` does the whole
chain including a modulus check that the cert and key are actually a pair.

**Top of the list as of 2026-08-05:**

- ✅ **RESOLVED 2026-08-05 — the starter-list fix IS SHIPPED.** It is in **build
  31 = 1.9, `READY_FOR_SALE`**, so the new-user cohort is now steered by pool
  rate rather than array position. See "The grant size decides which ONE route
  new users land on" for the before/after table.

  **Two corrections worth keeping, because both cost time to unwind.** This
  entry read "FIXED in the repo but NOT SHIPPED" for a day after it went live,
  purely because the App Store line above it was stale — a doc-drift bug that
  turns into a *decision* bug, since "unshipped" is the argument for cutting
  another release. And the commit it named, `804a6dd`, is **unreachable from
  every branch**: it is a duplicate hash left by another worktree, and the
  commit actually on this branch is **`a14fb86`** (identical message and date).
  `git log -S` finds all three copies; `git branch --contains` finds none.

  **Verify a client fix against the BINARY, not the commit graph.** Private
  Swift symbols are stripped from the shipped binary, so `strings` and `nm` on
  `.app/VirtualSIM` return nothing and read as "the fix is absent". The archive's
  **dSYM** keeps them: `nm -a <archive>/dSYMs/*.dSYM/Contents/Resources/DWARF/<binary>
  | grep bestStarter` is what settled it (mangled
  `$s10VirtualSIM8AppStateC11bestStarter…`, plus `routeKey`).
- ✅ **RESOLVED 2026-08-04 — the IAP fix is CONFIRMED working.** A Production
  receipt at 2026-08-03 16:41Z granted credits (`granted_credits > 0`), which is
  the settling evidence this entry asked for. Revenue is proven, not assumed.
  *Original:* every purchase failed `chain_verify_failed` until 2026-08-03
  because the Supabase edge runtime does not implement ECDSA P-384; fixed in
  pure JS via `@noble/curves/p384`.
- 🔴 **Does `pool_rate_pct` predict OUR delivery? Unverified, and the obvious
  query is now KNOWN-CONTAMINATED TWICE OVER — do not run it as one window.**
  Against HeroSMS orders the same vendor's rates correlated **negatively**
  (r = −0.51, n = 16). Stamped per order as `orders.pool_rate_pct` /
  `pool_pinned`. Two independent filters are mandatory before reading anything:

  1. **SPLIT ON 2026-08-05.** Orders before that date stamped **`rate24`**;
     after, **`rate168`**. Measured over 3,320 pools the two windows differ by a
     median 9.6 points and by 30+ points on 16.6% — so the halves are not the
     same measurement and pooling them mixes two variables. See "The pool rate
     is the tie-break".
  2. **EXCLUDE default-landed orders.** 16 of the last 20 5sim orders were the
     app's own pre-selected route, placed by users who had no reason to want
     that service and almost certainly never submitted the number anywhere.
     Scoring those as delivery failures measures our steering, not the pool.

  **If the correlation is not positive, the number must come off the row.**
- ⚠️ **Both provider balances are near the funding floor** — 5sim **$8.89**,
  HeroSMS **$9.41** (08-05 15:05Z), against a $7.50 single-order ceiling.
  HeroSMS funds SMS *and* the whole e-mail line, so it is the one that takes two
  products down. Re-query rather than quoting these:
  `select key, value->>'balance_usd' from app_config where key like '%_health';`
- 🚧 **The fourth product line (rentable second numbers) is BUILT, DEPLOYED and
  REACHABLE (`lines_paused = false`) but has never been sold.** This entry
  described it as "no edge functions, no client, no Telnyx account,
  `lines_paused = true`" for a day after all four were false — read
  "Rentable second numbers" above, not this line. As of 2026-08-06 the whole
  lifecycle is on cron and behaviourally verified
  (`scripts/verify-line-lifecycle.sql`, 12 checks in a rolled-back
  transaction). What genuinely remains:
  - **Telnyx float** — the one hard blocker, and it is money, not code.
  - ⚠️ **`CallController.phase` moves to `.dialing` only AFTER the call is
    committed** — the server authorised it and CallKit accepted it. It used to
    be set on the tap, so the in-call overlay went up for the whole
    `begin-line-call` round trip and came back down on a refusal. Re-entrancy
    over that window is `isStarting`, which is also the dialer's busy state:
    without it a double-tap sends two gating requests and each reserves
    credits. `isCommitted` (live, and not `.ending`) is what the dialer
    dismisses on — a refused call passes through `.ending`, and dismissing
    there would take its error message with it.
  - **Calling is WIRED but UNPROVEN.** `TelnyxRTC 4.1.2` was added and the
    dialer wired on 2026-08-06, so `NullVoiceClient` no longer stands in.
    **No real call has ever been placed**, the voice adapters were written
    from docs, and the media path is device-only — the simulator cannot
    receive a PushKit push. Treat the first call as the probe and read
    `app_config.telnyx_voice_faults` after it.
  - **A client release** for anything client-side. 2.0 IS live (that is how six
    numbers were sold); everything fixed on the client after it — the hero
    header, the readiness notice, the post-call meter refresh, code copy — needs
    2.1 before a user sees it.
  - **10DLC / toll-free verification — for EVERY number, not just US ones.**
    "Canada needs none" is retracted: a Canadian longcode is refused with the
    same `40010` on every send to a US number. See `.claude/rules/providers.md`.
- ✅ **RESOLVED in build 39 (2.0, WAITING_FOR_REVIEW as of 2026-08-10) — the two
  client-blocked fixes both ride in it.** The review prompt now also fires on
  app-foreground within 30 minutes of a delivered code (`loadOrders` diffs for
  newly-appeared codes; `reviewableRecentDelivery` delegates every gate to
  `shouldRequestReview`), so lock-screen readers are finally prompted. And the
  pack ladder gained the 8cr/$3.99 rung — see "The pack ladder gained its
  8-credit rung" in Pricing. Neither does anything for users until 2.0 clears
  review and is adopted; the server halves (`PRODUCT_TO_CREDITS`, `iap-verify`
  redeploy) are already live and harmless to old builds.
- ⚠️ **`sync-5sim` still takes 10× HTTP 429 per run** at `CALL_SPACING_MS = 600`.
  The retry rescues almost all of them, but a country lost for an hour reads as
  "5sim does not serve it". Watch `fetch_faults`; raise spacing on more than one
  sample (a run is ~71s against a ~150s edge kill).
- ⚠️ **Three retired-provider crons still run** — `relay-sync-smspva-operators`,
  `relay-sync-smspva-conversions` and the two `smspva-operators-maint` jobs — plus
  `relay-sync-herosms`. HeroSMS's is legitimate (560 active routes + e-mail
  balance); the SMSPVA ones maintain 928 routes we keep as the rollback target.
  Neither is a bug, but neither is free; decide deliberately rather than by
  inertia.
- ⚠️ **`countries.observed_*` is NOT provider-scoped** and still counts orders
  from retired providers. It is the third element of the steering key now rather
  than the first, so the blast radius is small — but the UK/US demotion it caused
  is exactly the failure mode, and it will recur wherever that column is read.
- ⚠️ **Migration `20260803070000` hardcodes a 0 signup grant** while live config
  says 3, so a from-scratch replay silently disables the grant.
- ✅ **RESOLVED 2026-08-06 — both stranded migrations are applied and recorded.**
  `20260803120000_expire_order_early_claim.sql` and
  `20260803121000_clear_foreign_seeded_rates.sql` had been written and never
  run since 08-03.

  **The first was worse than "unapplied" and that is the lesson.**
  `poll-active-orders:401` has been CALLING `expire_order_early_claim` all
  along, against a function that did not exist — so the HeroSMS fail-fast path
  errored on every order that reached it, silently, for three days. A migration
  that is merely missing is inert; a migration that is missing while something
  calls it is a live bug wearing no symptom. **After writing a migration,
  `select proname from pg_proc` for what it creates, not just
  `schema_migrations`.**

  The second cleared **336 routes** carrying a seeded grade from a provider
  that no longer serves them (now 1 row, the one legitimate SMSPVA case).
  Nothing was mis-stated to users — the client renders seeded as `.notTested` —
  but it was a retired provider's opinion sitting in the steering tables.

**Found by a 5-agent audit on 2026-08-01, still open, in priority order.**
Several were mis-reported by the audit and re-checked by hand — the corrections
are as load-bearing as the findings:

- ✅ **RESOLVED 2026-08-10 — the eSIM provider switch landed (eSIM Access) and
  closed the three landmines this entry named.** PK collisions: new plan ids
  are `'ea:' + packageCode`, collision-proof against SMSPool's numeric ids,
  and old rows are kept hidden with `last_checked_at` nulled so `/esim on`
  can never resurrect them. `esim_orders.provider` has READERS now:
  `check-esim-usage` routes on it (smspool rows take the legacy path
  verbatim; unknown providers are returned untouched) and `create-esim-order`
  refuses non-`ea:` plans — the `refuseRetired()` equivalent. `dataUsedMb`:
  the esimaccess path writes `data_used_mb` whenever usage is reported,
  INCLUDING 0, and stamps `expires_at` from the provider's authoritative
  `expiredTime`, so new orders are always sweepable. Still true: the 10
  legacy SMSPool rows keep `expires_at` NULL (no provider data to backfill
  from), and the 9-item switch checklist above remains SMS-specific.
- ✅ **RESOLVED — the hard crash on Japanese devices is GONE**, verified
  2026-08-03 by a full audit of all 357 strings × 6 locales: **0 non-positional
  reorders**. 1.8's release notes claim this fix and the claim holds. *Original:*
  `"%lld%% of %@ codes in %@ have arrived."` takes `Int, String, String` and the
  `ja` value reordered to `%@, %@, %lld` **non-positionally**, so arg 1 was read
  as a pointer (`WaitingScreen.swift:508`, right after payment).

  **Keep the audit, and write it correctly** — a multiset comparison does NOT
  catch this, because the multiset matches and only the ORDER differs. The check
  must be: same multiset AND (same order OR the translation uses positional
  `%n$` markers). Also beware the naive regex: a first attempt on 2026-08-03
  reported **106** mismatches, all false positives from capturing trailing text
  (`'%@ d'` vs `'%@ f'`). Extract the conversion specifier only, and treat `%%`
  as a literal. The two REAL multiset differences are documented-safe: Italian
  and Japanese legitimately omit the trailing English plural fragment in
  `"You're %lld credit%@ short…"` — omitting a LATER argument is safe;
  reordering or omitting an earlier one is not.
- ✅ **RESOLVED — the shared components all localize (re-audited 2026-08-27).**
  `SheetHeader`, `Metric`, `ChipButton`, `StatusBadge` and `GhostButton` each
  render via `Text(LocalizedStringKey(...))` / `String(localized:)` — this
  entry claimed they did not long after they were fixed (`StockPill` no longer
  exists). The audit's one REAL find was different: the order-history pill's
  `"Received"` key **did not exist in `Localizable.xcstrings` at all**, so
  every non-English locale rendered the raw English key — invisible to a
  file-level "0 untranslated" audit precisely because the key was absent
  rather than untranslated. Added 2026-08-27 with all six translations. The
  standing rule survives: when auditing localization, diff the KEYS the code
  can emit against the catalog, not just the catalog against itself.
- ✅ **RESOLVED — the e-mail waiting screen no longer hangs.**
  `refreshEmailOrder` gained a terminal branch (`fresh.status.isTerminal, !fresh.hasCode`)
  in `0552d53` on 2026-08-02, shipped in **1.8 build 28**, live since 08-03. It
  states whether the credits came back and clears `flow`. *This entry claimed it
  was still open for three days after it shipped — verify against
  `AppState.refreshEmailOrder` before re-opening it.*
- ✅ **RESOLVED — `intent` no longer leaks out of e-mail mode.** The THIRD
  instance of the `PurchaseIntent` bug class: turning e-mail mode off was a
  no-op, so Home → E-mails → pick a domain → back to Numbers → tap the credit
  pill sized the pack for a 1-credit address instead of the SMS route, and on a
  100+ credit route the user bought a pack and was still short.
  `ContentView`'s `.onChange(of: state.emailMode)` now clears `emailDomain` and
  resets `intent` in its `guard on else` branch. **Verify against that closure,
  not this list** — the entry survived here after the fix landed.

  The `.line` intent is cleared the same way, in `.onChange(of: state.tab)`,
  and for the same structural reason both need their own clear: these
  transitions happen at `flow == nil`, so `flow`'s `didSet` — the only other
  place that touches `intent` — never fires. **Any future product line whose
  mode is switched outside a flow needs its own clear in the same commit.**
- ⚠️ **Two ways the catalog can go dark returning HTTP 200.** `sync-esim-plans`
  has no fail-loud path (its `catch` is dead code — `esimPlans()` cannot throw,
  it returns a fault object that is silently dropped) and its hide-sweep floor is
  50 plans against a 1,081 catalog (4.6%, vs `sync-prices`' 40%).
- ✅ **RESOLVED 2026-08-06 — `sync-herosms`' positional cursor now walks a
  SORTED list.** The query has no `order by`, so Postgres could return the
  countries in a different order on any run and the cursor skipped some
  permanently: those routes never got a `herosms_real_count` and were sold as
  VoIP-only forever. `sync-smspva-operators` had it right all along.
- ✅ **RESOLVED (2026-08-18, re-verified in code AND live DB 2026-08-28) —
  Apple refunds revoke credits too, not just the line.** `apple-notifications`
  has a consumables branch (`index.ts` ~line 222) that calls
  `revoke_iap_purchase(transaction_id)` on `REFUND`/`REVOKE` — one transaction
  under the same advisory-lock key as `credit_iap_purchase`, idempotent
  against Apple's 1h/12h/24h/48h/72h retries, capped at the wallet balance
  with the shortfall paged. This entry claimed the credits half was unbuilt
  for ten days after `20260818130000_iap_refund_revocation` shipped it; the
  2026-08-28 check found the function in the live DB and the branch in the
  deployed source, and redeployed `apple-notifications` to rule out a stale
  bundle. Historical case kept: **2026-08-10**, user `ae492f1f` bought three
  packs in 58 seconds ($11.97, 22 credits, zero orders placed), asked support
  for a refund ("it was a mistake"). ⚠️ **This file said they "were pointed at reportaproblem.apple.com";
  the thread (`e36b25ba`) holds ZERO agent messages — verified 2026-08-21 —
  so no in-app reply was ever sent. It sat unanswered for 11 days and was
  closed unanswered on 2026-08-21 during the Telegram overhaul.** Apple is
  still the only refund channel (developers cannot issue Apple refunds); if
  Apple grants one now, the revocation lands automatically.
  Note also: **the bot has no way to CLOSE a support thread** — it can only
  move `open → assigned` — so answered threads sat in `/support` for two
  weeks reading as live work; a `/close` command is the missing piece.
- ✅ **RESOLVED 2026-08-06 — the alert channel no longer fails silently.**
  `telegram-notify` destructures the error on its watchdog read; a failed read
  used to skip the entire paging block and return `200 {sent:0}`, byte-identical
  to a healthy quiet run. That is the one failure mode a monitoring transport
  must not have. ⚠️ `ops_snapshot`'s read is still undestructured, and digest
  silence remains the documented human backstop for telegram-notify's own death.
- ⚠️ **`supabase_admin` default privileges still grant `anon`/`authenticated`
  `arwdDxtm` on every FUTURE table** — a dashboard-created table arrives
  world-**writable** unless RLS is explicitly enabled. Needs role membership we
  do not have. Also `claim_daily_credit()` and `daily_credit_status()` are
  `authenticated`-executable (deliberate — the shipped app calls them — and now
  harmless since both are no-ops).
- ✅ **RESOLVED 2026-08-06 — `routes` has two PARTIAL indexes on the active set**
  (`routes_active_provider_idx`, `routes_active_priced_idx`, migration
  `20260806120000`). It was showing ~111.7M sequential tuple reads against a
  ~9,300-row active set. Partial rather than a plain index on `status`, because
  'active' is the only value anything filters for.

**Two audit claims that were WRONG, re-verified by hand — do not act on them:**
- ❌ *"The evidence pipeline discards 87% of delivered codes."* The exclusion is
  largely **correct behaviour**: of 160 "discarded" orders, 46 are retired
  providers (smspool/virtualsms) and the rest are SMSPVA orders on routes now
  served by HeroSMS. Attributing leboncoin/ro's 9 SMSPVA codes to a HeroSMS route
  would advertise a record HeroSMS never earned. The genuine, narrower defect is
  that **SMSPVA's own 7,757 active routes got just 1 evidence-eligible order in
  30 days**, so the rollback target is unmeasurable. Low urgency.
- ❌ *"physicalCount is falsified."* See the physicalCount note above — that
  compared HeroSMS stock against SMSPVA outcomes. Untested, not falsified.

✅ **RESOLVED 2026-07-31 — all six money-path findings from the red-team audit
are fixed and deployed** (`20260731130000`, plus `iap-verify` / `check-order` /
`poll-active-orders` redeployed). The ledger reconciles exactly:
`sum(wallet_transactions.delta) = wallets.balance` for **all 204 wallets**, zero
double refunds, zero terminal-unrefunded orders on any of the three product
lines. None of these was ever exploited — no account in the DB has been deleted
and recreated, and 0 receipts are orphaned from a deleted user.

**The governing principle, because it will recur with the next grant:**
everything user-scoped cascades from `auth.users`, which is correct for user
data and *wrong for "have we already paid this out?"*. Apple mandates Delete
Account, so a user can always erase our only record of a grant and present the
same evidence again. Any new credit grant needs a tombstone **outside that
cascade** — `signup_grants` was the first, and its reasoning had simply never
been extended to the other two.

- **IAP replay via account deletion** — `iap_receipts` is ON DELETE CASCADE and
  unique(`transaction_id`) *on that table* was the only guard, so delete →
  re-signin → resubmit re-credited the same purchase forever (the JWS
  re-verifies perfectly; it is genuine, just not new). Now
  **`public.iap_grants`**, keyed on `transaction_id`, **with no FK to
  `auth.users`** — a reference there is exactly what would delete the row with
  the account. Backfilled from all 30 credited production receipts, so purchases
  made before today are covered too. `grant_count` above 1 records a **replay
  attempt**, which is the signal that this defence is load-bearing rather than
  theoretical.
- **`iap-verify` could eat a real payment.** The rollback set
  `granted_credits = 0` while the retry guard only checked receipts where
  `granted_credits > 0` — mutually exclusive, so the exact case it was written
  for fell through to `already_credited`, the client called `finish()`, and a
  purchase worth up to $59.99 was retired having granted nothing. Both the fresh
  and duplicate paths now go through **`credit_iap_purchase()`**, which is
  idempotent against the tombstone: calling it again *is* both the duplicate
  check and the recovery. The receipt is inserted at `granted_credits = 0` and
  only that function sets it, so the column can never claim credits that never
  landed, and a failed credit rolls the tombstone back with it — leaving the
  payment recoverable by construction rather than by a TypeScript rollback that
  contradicted its own guard.
- **The referral bonus is tombstoned**, on the same `md5(lower(email))` identity
  as `handle_new_user`, via `signup_grants.referral_redeemed_at`. Fails **open**
  on a null email, matching the documented policy. (Note `profiles.referred_by`
  is currently **0 rows** — the referral feature has never once been used.)
- **`poll-active-orders` reverts the expiry claim** when the refund fails,
  matching `cancel-order` / `check-order` / `create-order`, and pages — a
  terminal row is never revisited, so leaving it `expired` made the charge
  permanently unrefundable, on the highest-traffic close path in the product.
- **The 4-credit debt is paid.** eSIM order
  `916b16a0-ce19-4e3e-9cac-08b9958f4c7c` (2026-07-26) was refunded via
  `wallet_move_esim` and moved `failed` → `refunded`; it was the only such row.
- **Both discarded `{ error }` sites destructured** — `check-order`'s
  `expire_order` and `iap-verify`'s `apply_referral_reward`. The latter's
  `try/catch` caught nothing, because **supabase-js returns errors rather than
  throwing**, so the referrer's 5 credits were lost with no trace.

Verified behaviourally, not just by deploy: a scripted replay inside a
rolled-back transaction returns `granted` → balance +7 → `already_granted` →
balance unchanged, one ledger row, replay attempt counted, and a zero amount
refused.

- 🔴 **Build 19's e-mail waiting screen never exits on a terminal order.**
  `AppState.refreshEmailOrder` transitions on `hasCode` only — there is no branch
  for expired/failed/canceled, and `EmailWaitingScreen`'s poll loop is gated on
  `flow == .emailWaiting`, which nothing else clears. So when an e-mail order
  times out the server does everything right (expires it, refunds the credit) and
  the app renders "Waiting for the code" forever; the only exit is the ✕. This is
  the SMS `apply()` rule — "never write a status switch here without covering all
  cases" — not applied to the e-mail path. **Ships in 1.6**, which was already in
  review when this was found. The new `expire_email_orders` sweep confines the
  damage to that one screen (previously `ResumeBar` re-advertised the dead order
  app-wide, forever), but the screen itself needs 1.7.
- ⚠️ **Build 19 tells users to pick iCloud when the free cap is hit** —
  `APIError.swift:103` and a stale doc comment in `EmailAPI.swift:25`. iCloud was
  removed from both `PRICING` maps on 2026-07-31, so `create-email-order` now
  refuses it with `domain_unavailable`. The instruction is unfollowable. Also
  unmapped: `unknown_order` (emitted by `check-email-order`), while a
  `order_not_found` case that nothing emits sits in the map.
- ⚠️ **`margin_too_low` tells an e-mail buyer to "try another country".** There
  is no country in the e-mail product. Needs its own copy or its own error code.

- ✅ **RESOLVED 2026-09-08 — the wholesale cost book on `routes` and
  `esim_plans` is CLOSED to `anon`/`authenticated`.** See "The cost book is
  column-granted" below; `20260725130000_hide_route_cost_columns` is
  SUPERSEDED and must never be applied (it is a no-op AND its re-grant list
  breaks the shipped client).
- ⚠️ **`supabase_admin` default privileges not revoked** — needs membership in
  that role. Covers objects created via the dashboard rather than migrations.
  Statements in `20260727211000_default_privileges.sql`.
- ⚠️ **Migration drift: a fresh deploy would NOT reproduce production.**
  Re-measured 2026-07-30 and **unchanged**: 110 versions recorded in the DB
  against 97 local files — **43** recorded versions have no local file and **29**
  local files aren't recorded. Two files share version `20260719000000`, five
  migrations were applied twice, and ~10 functions exist only in the live DB
  (`smspool_hot_combos` appears in zero migration files). `db push` remains
  broken. Recover by writing each missing version out of
  `schema_migrations.statements` — do NOT `migration repair --status reverted`.
- ⚠️ **No test suite, and it shows.** Of ~20 changes made on 2026-07-27, **six
  were regressions introduced that same day** — a disabled watchdog check, a
  wholesale forfeit on every cancel, invisible rescued codes, an orphaned cancel
  path, a stale constant copy, and a timer/hold interaction. All were caught by
  post-hoc review, two only by luck. Until something automated covers the order
  lifecycle and the money paths, assume a similar rate on the next batch.
- ⚠️ **PARTIALLY RESOLVED: evidence is gathered for every provider, but the
  2026-07-30 claim that `active_sms_provider()` is "no longer load-bearing" was
  FALSE.** `refresh_evidence_all_providers()` fixed only the three refreshes it
  wraps. The 2026-07-31 audit found two consumers still on the bad vote —
  `refresh_arrival_timing` (a separate maintenance entry, outside the wrapper)
  and `recent_sms_delivery_rate()`. Both are described above; both are fixed or
  defused, and the function itself is still wrong. Grep `pg_proc.prosrc` before
  trusting any statement about who calls it.

- ✅ **RESOLVED 2026-09-08 — see "The cost book is column-granted" below.**
  `20260725130000` was a NO-OP as written and is superseded; the working shape
  is REVOKE the table grant, then GRANT the safe columns back.

- 🟠 **`orders.actual_cost_cents` — the CLIENT half is done, the server revoke
  is still outstanding.** ⚠️ **`routes` and `esim_plans` were closed on
  2026-09-08** (see "The cost book is COLUMN-GRANTED"); the three ORDER tables
  are what remains, and they are the SMALLER exposure — RLS is self-read, so a
  user leaks only their own wholesale, not the book. The adoption gate is NOT
  yet met for them: over 24h to 2026-09-08 the edge logs show `select=*` still
  arriving on `/rest/v1/email_orders` (87 requests, **84** distinct IPs) and
  `/rest/v1/orders` (61 / 34) — revoking today would break those clients.
  Re-run that log query before acting. `orders`, `esim_orders` and `email_orders` all carry
  per-order wholesale, RLS self-read grants the row, and **no Swift model
  decodes it** — a pure leak. As of 2026-08-27 **every PostgREST fetch in the
  iOS client names its columns explicitly; there is no `select=*` left**
  (`grep -rn 'value: "\*"' VirtualSIM/Networking` must return nothing). The
  lists live next to the fetch that uses them — `CatalogAPI.serviceColumns` /
  `.countryColumns` (routes was already explicit), `OrdersAPI.columns`,
  `EsimOrdersAPI.orderColumns`, `EmailAPI.orderColumns` (the inline list in
  `SupportAPI.messages()` went with that file on 2026-09-05). Each is exactly the decoding model's stored
  properties — a column dropped from one of these lists makes an OPTIONAL
  property silently nil and throws on a non-optional one, so re-derive the list
  from the model whenever the model changes. **The server-side revoke must still
  wait until a build carrying this is ADOPTED**, because Postgres needs SELECT
  on every column to answer the `select=*` that shipped builds still send.
  Client first, revoke second — same ordering as `routes` and `esim_plans`.

- ⚠️ **`telegram-setup` is in neither deploy list** in this file, and the claim
  at the top that those lists cover "every directory … (19 functions total)" is
  wrong on both counts — there are 24 directories. It fails closed, so there is
  no exposure, but **rotating `TELEGRAM_WEBHOOK_SECRET` requires re-running it**.

- ⚠️ **Route-level evidence is 3 rows (08-04), for an honest reason.** A route needs 3
  conclusive attempts and HeroSMS has ~24 orders total. Service and country
  evidence rebuild first. Nothing to do but let volume accumulate — it is now
  *capable* of accumulating, which it was not. **This is exactly the gap the
  provider deliverability data fills** (see the steering section): until our own
  measurement exists, the vendor's ranking is the only thing standing between an
  untested route and a price-based tie-break.
- ⚠️ **DO NOT ROLL BACK HeroSMS on the raw rate — the checkpoint metric is
  measuring user impatience, not the provider** (2026-08-01). Raw numbers look
  damning: HeroSMS **5 of 27 (18.5%)** against SMSPVA **45 of 127 (35.4%)**, and
  the pre-registered trigger is *"conclusive delivery over the first 40 orders
  materially below SMSPVA's frozen baseline"*. It would have fired.

  Split out **orders the user did not cancel** and the gap disappears entirely:

  | provider | cancelled | delivery when NOT cancelled |
  |---|---|---|
  | herosms | **74%** (20/27) | **5 of 7 — 71.4%** |
  | smspva  | 56% (67/120)    | 39 of 53 — **73.6%** |

  Within noise of each other. The entire headline gap is *cancellation rate*,
  not delivery. Over 30 days **87 of 147 numbered orders (59%) were cancelled by
  the user and delivered 1.1%**, while `expired` orders (avg 772s) delivered
  **0 of 16** — so a code either lands in the first couple of minutes or never.
  HeroSMS's own n is only 7, so treat 71.4% as "not distinguishable from
  SMSPVA", not as proof it is better.

  **Re-register the checkpoint on non-cancelled delivery**, and only compare
  windows where the same client versions are in the field. `providerOrder()` back
  to `["smspva"]` remains a one-line revert if it is ever justified — but SMSPVA
  is at $5.26, below the single-order ceiling, so a rollback needs a top-up first.

  ✅ **FIXED 2026-08-01 (`20260801110000`): the `delivery-collapse` watchdog
  check had the same flaw** and fired that morning ("14 conclusive orders in
  24h, ZERO codes delivered") while non-cancelled delivery was ~73%. It counted
  a cancel as conclusive whenever the user held 240s+ OR re-ordered the same
  service within 10 minutes, so at a 59% cancel rate it measured impatience.
  Both delivery checks now use `status in ('received','expired')` only.

  **The thresholds were re-derived from measured reachability, not guessed**,
  because this function has already shipped an unreachable gate once. With
  cancels excluded, the max in ANY 24h window over 30 days is **10** — so the
  old `>= 10` gate would have been effectively dead on arrival. Now:
  collapse = **72h, >= 6, zero codes** (72h volume avg 6 / max 12; at a ~73%
  baseline, zero in 6 is p ≈ 0.0004) and degraded = **7d, >= 12, < 30%** (7d
  volume min 3 / avg 13 / max 21). Collapse deliberately uses the SHORT window
  so a real outage is caught in hours; the rate check uses the long one, where
  a rate is meaningful. Regenerated from `pg_get_functiondef` and diffed clause
  by clause — exactly two hunks differ, all **15** checks still present, and it
  returned `[]` immediately after.
- 🔴 **Nothing in the email or support paths has been used by a real person
  through the app.** The client for both ships in build 19 and Apple Sign In does
  not work in the simulator, so every screen is verified by build + screenshot
  only. The email money path is proven at SQL level and one activation was
  bought via the API; the support round trip (send → Accept → reply → push) has
  **never run**, because it needs `TELEGRAM_BOT_TOKEN` / `TELEGRAM_WEBHOOK_SECRET`.
- ⚠️ **Email is in `ops_snapshot` + `_shared/opsFormat.ts` as of 2026-08-05
  (`20260805110000`) but STILL ABSENT from `revenue_snapshot`**, so it is
  visible in the digest / `/stats` / `/today` / `/week` and invisible in
  `/revenue` and `/profit`. Low urgency — the line has earned **1 credit**
  lifetime — but the moment a paid tier matters, `/profit` is understating.

  The digest block mirrors `orders` exactly, including `unprovisioned`
  (`status='failed'`, no mailbox ever issued) being reported OUTSIDE the
  delivery rate — the same rule as `numberless` for SMS. Do not fold them
  together: on 2026-08-05, 7 of 29 lifetime orders were `unprovisioned`, five
  of them one user retrying TikTok in a 7-minute burst, and merging them turns
  "the free tier ran dry" into "email delivers 24%".
- ⚠️ **The HeroSMS API key passed through a chat transcript and should be
  rotated.** It lives only as the `HEROSMS_API_KEY` Supabase secret and appears in
  no commit (verified), but rotate it.
- ⚠️ **Removable code — most of it is now gone.** `virtualsms.ts`,
  `sync-virtualsms/`, `sync-smspool/`, `smspool-catalog/` and `smspool.ts`'s SMS
  surface were all deleted 2026-07-30. A second sweep on 2026-08-18 removed
  `NumberGenerator` (a whole unreferenced file), `FlagBox` and `StockPill` (two
  components with no call site), and `AppState.checkNow` — orphaned when the
  "Check now" button was deliberately taken off `WaitingScreen`.
  ❌ **`AppState.routes` was listed here as "written once, never read" and that
  was FALSE.** It is read at `Sheets/CreditsSheet.swift:655`
  (`for r in state.routes where r.status == "active"`), which is how the credit
  packs know what a balance can actually reach. Deleting it on the strength of
  this line would have broken that. The memory cost is real; the claim that
  nothing reads it was not. Still outstanding: the constants duplicated across
  files above.
- ⚠️ **Supabase project is on the FREE plan (no backups).** Owner action.

**A snake_case property name is a decode FAILURE, not a no-op.**
`JSONDecoder.relay` sets `.convertFromSnakeCase`, so an edge function returning
`{thread_id}` arrives as `threadId`; a struct declaring `let thread_id` matches
nothing and throws. `SupportAPI` did exactly this, so a support message that was
stored AND relayed to Telegram reported **"Couldn't reach the server"** to the
user while the owner's phone buzzed with it. When a caller discards the response
— as every fire-and-forget endpoint does — decode `APIClient.Empty` instead and
give the endpoint no client-side contract to break at all.

**`APIError.decoding` must never render as a connectivity message.** It shared
its copy with `.badResponse` (*"Check your connection and try again"*), which is
actively wrong: a decode failure means the request **succeeded**. It sends the
user to check their wifi and, worse, to retry an action the server already
performed. It now says the action may have gone through.

**`_shared/*` is bundled PER FUNCTION at deploy time.** Fixing a shared file
changes nothing in production until **every consumer is redeployed** — a
downloaded-bundle diff on 2026-07-31 found `check-order`, `cancel-order` and
`poll-active-orders` still running a pre-fix copy of `providers.ts` weeks after
the source was corrected. Harmless there (none of them call `reserve()`), but
the failure mode is invisible: the repo and the deployed code disagree with no
signal anywhere. After touching `_shared/`, redeploy every function that imports
it, not just the one you were working on.

**AND THE SAME TRAP APPLIES TO A FUNCTION'S OWN CODE — this is not theoretical,
it shipped a user-visible bug (2026-08-02).** The owner reported eSIMs turning
back ON every morning despite pausing them. Cause: `sync-esim-plans` was
**deployed at 09:26 UTC on 07-31, and the commit that taught it about pausing
(`41ef51c`) landed at 09:29** — three minutes later. Production ran a bundle
that had never heard of the pause, so the 02:00 cron rewrote all 1,081 plans to
`active` every night. `app_config.esim_paused` read `true` the whole time. The
symptom was "the pause doesn't stick", which points at the pause code — the
actual fault was that the pause code was never running.

**Rule: DEPLOY AFTER COMMITTING, never before.** Every stale-deploy bug this
codebase has had comes from deploying mid-edit and then committing the final
version. The check, when in doubt:

```bash
supabase functions list        # deployed timestamp per function
git log -1 --format=%cd -- supabase/functions/<name>/index.ts
```

⚠️ **That comparison has a high false-positive rate** — a normal
deploy-then-commit shows the commit 1–7 minutes *after* the deploy and is fine.
It is a screen, not proof; only a bundle diff or observed behaviour is proof.
When unsure, just **redeploy everything** (idempotent, ~1 min, two commands —
see the two deploy lists at the top of this file), then assert the JWT flags
landed:

```
telegram-webhook  unauthenticated POST -> 200   (its own silent rejection; 401 = bot dead)
sync-herosms      no x-cron-secret     -> 403   (secret check, not the JWT gate)
create-order      no auth              -> 401   (auth still enforced)
```


## Pricing: the per-provider credit-divisor era (retired 2026-08-28)

*Superseded by the single tapered curve in `_shared/pricing.ts`. Kept because
it explains where `NET_USD_PER_CREDIT = 0.40` came from, and because it is the
clearest worked example of a divisor/inverse mismatch failing silently.*

### Pricing model

`AppState.cost(for:country:) -> Int?` uses an O(1) `routeIndex` dict (keyed `"serviceId|countryId"`) built in `loadCatalog`. Returns `nil` when the pair has no active route with a `retail_credits` price — meaning **unavailable to book**; UI shows "Unavailable" (see ServiceSheet/CountrySheet) and disables the Get-number button. It deliberately does **NOT** fall back to the seed `service.cost`, since undercharging vs the live provider price burns margin per order. **Do not** linear-scan `routes` (~17k rows after sync-prices) — that froze the country picker before the index was added.

🔴 **SMS retail is ONE TAPERED CURVE since 2026-08-28 (owner decision), uniform
across every provider, defined in `_shared/pricing.ts` and NOWHERE else:**

```
retailUsd(cost)   = cost ≤ $0.15 ? 10 × cost
                  : cost ≤ $0.30 ? $1.50            // plateau — the join
                  :                5 × cost         // "tail 5×", 2026-09-01
retail_credits    = clamp(1, 999, ceil(retailUsd / NET_USD_PER_CREDIT))   // NET = 0.40
expectedCostUsd(credits)  — the inverse, used by create-order; on the plateau it
                            returns the UPPER preimage ($0.30) so the ceiling is
                            lenient across it and never refuses an honest route
```

🔴 **TAIL 5× IS A TWO-WEEK EXPERIMENT (owner decision 2026-09-01).** From
08-28 to 09-01 the tail was a MARGINAL 5.5× (`1.50 + 5.5 × (cost − 0.15)`),
which is an EFFECTIVE 6.3–7.2× on the $0.50–$1.00 routes US users actually
want. First day of 2.6 analytics: **4 of 5 paywall purchase attempts on
facebook/telegram/whatsapp were cancelled at Apple's sheet.** The tail 5×
moves each down exactly one pack rung — facebook/us 9 → **7** cr ($3.99 ask →
$2.99), telegram/us 14 → **11** ($5.49 → $3.99), whatsapp/us 16 → **13**
($12.99 → $5.49) — and leaves the ≤15¢ band untouched, because a FLAT 5×
would halve the cheap band (grant-reachable routes 2,618 → 5,858, i.e. the
grant-5 collapse again, via price). Cost at constant volume ≈ $18/month.
**Read it** at ~30 `paywall_shown` events with `needed ≥ 4`:
`purchase_result` success vs cancelled on those, NOT raw revenue (the farm
block and the grant restore landed the same week). Revert = the 08-28
formula, one file, redeploy the five consumers. Verified at deploy with
`$CLAUDE_JOB_DIR/tmp/curve_test.ts`-style sweep: monotone over 3,000 costs,
never under 5×, inverse ≥ cost, never a loss.

The plateau is what keeps the curve **monotone** — a blanket 5× above 15¢
would sell a 16¢ route ($0.80) cheaper than a 15¢ one ($1.50), a price
inversion. Never rewrite it as a flat multiple picked by a threshold.
All four SMS syncs (`sync-5sim`, `sync-herosms`, `sync-prices`,
`sync-smspva-operators`) import `retailCredits()`; `create-order` imports
`expectedCostUsd()` and `NET_USD_PER_CREDIT`. The per-provider
`CREDIT_DIVISOR`s and `MIN_MARGIN_BY_PROVIDER`/`marginFor` are **deleted** —
the old warning that consolidating divisors "would silently reprice a
provider" is retired: uniformity is now the point, and one definition kills
the drift class. **The lockstep rule survives in sharper form:**
`expectedCostUsd` must remain the exact inverse of `retailUsd` — change one
without the other and honestly-priced routes are refused `margin_too_low`,
charged-and-refunded, silently. Both live in the same file so the same commit
can hold both.

Applied effect, measured against the live catalog before deploy (2026-08-28):
3,773 of 7,866 active 5sim routes and 1,207 of 1,260 HeroSMS routes got
CHEAPER, **zero got more expensive**, zero priced below wholesale; HeroSMS
median 8 → 5 credits (its 16× era ended), 5sim ≤15¢ routes unchanged (already
10×), the worst route fell 181 → 101 credits, and the $2.99/5cr pack's reach
went ~47% → ~63% of the catalog. Rationale: the measured delivery-by-price
gradient (≤5¢ 12–18%, >40¢ ~80%) means the expensive band is where the product
actually works, and a flat 10–16× priced exactly that band out of the packs.

**The $0.10 headroom is load-bearing — do not "simplify" it away.** Without it the two formulas are exactly inverse (`credits*0.30/6.0 == credits*0.05`), so a route whose wholesale lands on an exact 5¢ boundary has an order-time cap equal to its cost **to the cent**. Measured 2026-07-27: **12,507 of 16,303 active routes (76.7%) sat at exactly zero headroom.** A one-cent rise at SMSPVA then made every order on that route fail `margin_too_low` — charged and instantly refunded — until the next hourly `sync-prices` repriced it. That produced **11 of 22 orders in 24h closing in under a second with no number**, and because those orders were also counted as delivery failures it auto-hid TikTok/Netherlands (see below). The headroom is flat, not proportional, so exposure is bounded at $0.10/order at any price point; the cost is margin on the cheapest routes (a 2-credit route may now pay up to $0.20 against $0.60 of revenue, 3× not 6×), which is strictly better than refunding the order. **SMS markup went 3× → 6× on 2026-07-25** (divisor 0.10 → 0.05); retail is recomputed from `smoothed_cost_cents` every run, so the whole catalog reprices on the next `sync-prices`.

**⚠️ THE ORDER-TIME CEILING IS NO LONGER THE DIVISOR — it is 3× it, plus the
flat headroom, capped at half of revenue (owner decision, 2026-08-02: "be a bit
lenient on the margin, all orders should succeed").**

```ts
expectedUsd = expectedCostUsd(credits)   // _shared/pricing.ts — exact inverse of the taper
maxCostUsd = min( expectedUsd * CEILING_SLACK_MULTIPLE + CEILING_HEADROOM_USD,
                  credits * NET_USD_PER_CREDIT * MAX_REVENUE_FRACTION )
// CEILING_SLACK_MULTIPLE = 3.0 ; MAX_REVENUE_FRACTION = 0.5
```

**The lockstep rule still holds** — the expected term must be the exact
inverse of the curve the route was priced with; since 2026-08-28 both halves
live in `_shared/pricing.ts` (see the taper block above), so the lockstep can
only break if that one file is edited half-way. `MAX_REVENUE_FRACTION` is the
INVARIANT (no order can ever be sold at a loss, whatever the multiple is set
to or a future curve change does); `CEILING_SLACK_MULTIPLE` is the POLICY.
Note that on the tail the half-revenue cap BINDS (3 × rev/5 = 0.6·rev >
0.5·rev) — correct, since revenue ≥ 5× wholesale everywhere on the tail,
half of revenue is still ≥ 2.5× the route's own cost.

**Why 3×, and it is not about price rises.** We do not choose a pool: we pass
`maxPrice` and the provider fills from the cheapest thing under it, so the
ceiling decides how much inventory we can reach at all. Measured over 1,554
(service,country) pairs — share of a route's TOTAL stock reachable:

| cap | mean | median |
|---|---|---|
| cheapest tier only | 10.6% | **6.2%** |
| 1.1× (the old ceiling) | 19.2% | 13.6% |
| 2.0× | 64.9% | 65.8% |
| **3.0× (shipped)** | **77.0%** | **83.6%** |

23% of routes hold fewer than 100 numbers in the cheapest tier, so capping just
above it meant competing for the thinnest slice while the bulk sat a few cents
higher — a direct cause of "no numbers available" on routes holding hundreds of
thousands of numbers. Verified across all 12,897 active priced routes: routes
that could not absorb a median 1.11× price tick went **3,870 → 0**, p95 2.03×
went 10,285 → 193, and zero routes ended up tighter than before, below their own
cost, or loss-making.

🔴 **PRICE DOES PREDICT DELIVERY, and this file said the opposite for weeks.**
Re-measured 2026-08-20 on the SETTLED cohort (`status in ('received','expired')`,
numbered, excluding app-default routes), July+August pooled:

| wholesale paid | n | delivered |
|---|---|---|
| ≤5¢ | 33 | **12.1%** |
| 6–15¢ | 51 | 47.1% |
| 16–40¢ | 20 | 50.0% |
| >40¢ | 14 | **78.6%** |

The old claim (16/19/17/23%, "drift inside the noise") was computed over ALL
orders — where ~60% are cancelled by the user at a median 57s against codes
arriving at a median 58s. Impatience swamped the signal, and the conclusion
inverted. **Never compute a delivery rate over unsettled orders.**

Consequences that follow, all measured the same day:
- The 5sim "collapse" (75.0% July → 22.4% August) is largely NOT the provider.
  Median wholesale per settled order fell **17¢ → 6¢** at the cutover, and at
  constant price the providers are indistinguishable (6–15¢: 5sim 42.3% n=26,
  SMSPVA 38.5% n=13). Reweighting August's own band rates to July's price mix
  recovers **47.8%** — price mix alone explains ~53% of the gap. HeroSMS fell
  the same way (0/11 in its ≤5¢ band), which is the tell: it is provider-
  independent.
- SMSPVA's headline 78.7% was bought at >40¢, where it went 9 of 9.
- `routes.pool_rate_pct` (5sim's published rate) does NOT predict our outcome
  post-08-05: >60 → 37% (n=19), 30–60 → 41% (n=22), 1–29 → 38% (n=13). The
  monotonicity previously recorded came from the pre-08-05 `rate24` stamp.

⚠️ **Confounded, and honestly so:** 31 of 32 default-landed ≤5¢ orders came
from users who had never paid. Cheap inventory and non-serious users cannot be
separated at this n. Settling it needs a two-arm test — default routes forced
to ≥15¢ for two weeks — at ~60 settled orders per arm. Owner declined that
change on 2026-08-20, betting on the 5-credit signup grant instead, and
**reversed it on 2026-08-22** once pack sales were traced to first orders that
never deliver: **`AppState.minDefaultCredits = 3`** now DEMOTES every route
under 3 credits in the three picks the app makes for the user (starter,
auto-landed country, post-failure retry) — a demotion, never a filter, so the
hero can never go "Unavailable"; the user's own country list is untouched.
Client-side, so it ships with **2.3** and does nothing for older builds.
Measure it with `from_default` (delivery on default-landed orders was 4.0%,
n=50, against 41.2% for user-picked), split on the 2.3 adoption date. The
floor must never exceed the signup grant (3 today) or every first pick
becomes unaffordable — change the two together.

**Changing the pricing curve silently breaks the PREMIUM tier until
`premium_credits` is recomputed — the lesson survives the 2026-08-28 move to
the shared taper** (the divisor-based backfill SQL below is historical; today
the fix is one `sync-herosms` run — it prices its own premium — plus a
`sync-smspva-operators` cycle if SMSPVA is ever un-retired, then assert
`premium_credits >= retail_credits` is violated by zero rows). *Original,
divisor-era text:* This bit us on the 3× → 6× change (2026-07-25).
`retail_credits` is rewritten wholesale by `sync-prices` on the next hourly run,
but `premium_credits` is written **only** by `sync-smspva-operators`, which is
cursor-chunked at 12 countries/run across a nightly window — so it keeps
old-divisor values for *days*. Meanwhile `create-order` computes its ceiling as
`premium_credits * NET / MIN_MARGIN`, which just halved. Result: **15,702 of
16,303 premium routes would have been refused at checkout** with `margin_too_low`
— honestly-priced routes, rejected, invisible unless you query for it. After any
divisor change, backfill immediately (this exact statement repairs it, and
mirrors `toCredits()` + the never-cheaper-than-standard floor):

```sql
update public.routes
set premium_credits = greatest(retail_credits,
      greatest(1, least(999, ceil(smspva_operator_cents/100.0/<NEW_DIVISOR>))))
where premium_credits is not null and smspva_operator_cents is not null
  and retail_credits is not null;
```
Then assert `count(*) where premium_credits * <NEW_DIVISOR> < smspva_operator_cents/100.0` is **0**.

Note the ceiling is *margin-invariant* by design: credits scale up exactly as the
multiplier scales down, so `maxCostUsd` stays ≈ wholesale at any margin. That is
the whole reason the two constants must move together — and why only the derived
columns need a backfill.

**Changing the curve also silently devalues (or inflates) every FIXED credit
grant — still true under the taper; re-check the grants after any curve
change.** *The history below is from the divisor era:*
The premium backfill above is not the only casualty — anything denominated in a
flat number of credits buys proportionally less the moment prices double, and
nothing recomputes it. The 3× → 6× change on 2026-07-25 cut what the 1-credit
signup bonus could reach from **971 routes to 24** (−97.5%, of 16,303 active),
and the 24 survivors are the cheapest, worst inventory: measured over the
following 30 days, the 1-credit band delivered **10.9%** against **42.1%** for
the 2–5 band. Result was a 0%-conversion funnel — 11 signups, 2 orders, 0 codes,
0 purchases in the 24h to 2026-07-26. Fixed by raising the grant to **3 credits**
(migration `20260726140000`, after `20260726130000` briefly set 5).
**Raised to 5 credits on 2026-08-02 as a ONE-WEEK EXPERIMENT** (owner
decision, `20260802130000`): 5 cr reaches 3,721 routes / 247 of 265 services
in the post-repricing catalog (3 cr: 2,299/227). Evaluate ~2026-08-09 —
signup→first-order rate vs 26% (7d to 08-02) and 21.7% (lifetime); revert is
the same migration with `v_bonus := 3`. Note the shipped sign-in copy still
says "3 free credits" — deliberate under-promise for the experiment week;
update the literal + 6 translations only if 5 sticks.

**The cliff is between 1 and 2 credits, not further up** — this is the number to
reason from, measured per exact price over the 30d to 2026-07-26:

| grant | routes reachable | % catalog | delivery at that price |
|---|---|---|---|
| 1 cr | 24 | 0.15% | **10.9%** (46 orders) |
| 2 cr | 971 | 5.96% | 40.0% (15 orders) |
| **3 cr** | **1,636** | **10.03%** | **39.3% (28 orders)** ← current |
| 4 cr | 2,401 | 14.73% | 53.8% (13 orders) |
| 5 cr | 2,851 | 17.49% | — (1 order, noise) |

Delivery roughly **quadruples** from 1 → 2 credits and is then flat through 3;
3 carries the largest order sample in the 2–5 range, so it is the best-evidenced
point. Going past 3 buys catalog breadth, not measured delivery. Delivery is
also **not** monotonic in price overall (the 6–15 band measured 20.7%, 16+ measured
0%), so "grant more" is never the lever — landing users above the 1-credit floor
is. After ANY divisor change, re-check every fixed grant: `handle_new_user()`
(signup), `claim_daily_credit()` (the 1/2/3 daily ladder), and `redeem_referral`
(2 to the joiner, 5 to the referrer).

**The cost smoothing is a RATCHET, not a symmetric EWMA.** A cost RISE applies immediately; only falls are smoothed:
```ts
const smoothed = prev == null || cents > prev ? cents : Math.round(A*cents + (1-A)*prev);
```
A plain `0.5*new + 0.5*prev` averages a rise against yesterday's cheaper price and sets retail BELOW what you're about to pay. That shipped once and put **4,384 routes under wholesale** in a single run. Both retail-setting syncs (`sync-prices`, `sync-esim-plans`) have the ratchet — if you add another pricing path, give it one too. `sync-herosms` deliberately has none: it records the **raw** observed cost and never derives retail, so smoothing there would only blur the number the margin gate reads.

**eSIM** plans (`sync-esim-plans`) are priced **separately** at 4× wholesale (raised 3× → 4× on 2026-07-25) — `ESIM_MARGIN = 4`, `CREDIT_VALUE_USD = 0.48`, `retail_credits = ceil(usd * 4 / 0.48)` — NOT via `CREDIT_DIVISOR`, so the two product lines never collide. Inverted, the order-time ceiling in `create-esim-order` is `credits * 0.12`, enforced twice since the eSIM Access switch (2026-08-10): a fresh `package/list` quote blocks above the ceiling BEFORE charging (fails **closed** on a bad price, **open** on a failed lookup — an unreachable provider must not make eSIMs unbuyable), and the order call **echoes the price**, which the provider verifies (200005/200006 → refund + `margin_too_low`) — their order response reports no cost and takes no cap, so the echo is the only order-time price guard. The real figure lands in `actual_cost_cents` (before 2026-07-30 it echoed the cached catalog price, so margin analysis over it was circular). The eSIM path also gained the same **pre-charge provider-balance guard** as SMS (reads `app_config.esimaccess_health`, fails open on stale/missing).

**⚠️ SUPERSEDED 2026-08-28 — the per-provider divisor era is OVER; all SMS
pricing is the shared taper in `_shared/pricing.ts` (see the top of this
section).** The history below is kept because it explains `NET_USD_PER_CREDIT`
= 0.40 (still live, now exported from `pricing.ts`) and the class of silent
failure a divisor/inverse mismatch produces. The table it documents was, at
retirement:

| provider | priced by | divisor (RETIRED) | `MIN_MARGIN` (RETIRED) | `MAX_WHOLESALE_CENTS` |
|---|---|---|---|---|
| **5sim** | `sync-5sim` | 0.04 | 10.0 | 100_000 |
| herosms | `sync-herosms` | 0.025 | 16.0 | 100_000 |
| smspva | `sync-prices` | 0.05 | 8.0 | 100_000 |

🔴 **THE TRAP THIS FIXED, because the lockstep ✓ cannot catch it.** The divisor
is `NET_USD_PER_CREDIT / MIN_MARGIN`, so it is a true 10× only if a credit
really nets what `NET_USD_PER_CREDIT` says. It said **0.30**, and measured over
all 37 Production purchases (586 credits, $273.63) a credit grosses **$0.467**
and nets **$0.397** after Apple's 15%. So every provider ran ~32% above its
stated multiple — 5sim's "10×" was **13.2×**, HeroSMS's "12×" **15.9×**,
SMSPVA's "6×" **7.9×** — while the arithmetic stayed perfectly self-consistent
against the wrong input.

`NET_USD_PER_CREDIT` was doing two opposite-signed jobs: understating revenue is
**conservative for the order ceiling** (we spend less) and **backwards for
pricing** (we charge more). It is now the measured 0.40. **Re-derive it from
receipts if the pack mix shifts — never guess it**, and never reason about a
margin from anything else.

⚠️ **HeroSMS 12 → 16 and SMSPVA 6 → 8 are RESTATEMENTS, not repricings.** Their
divisors are unchanged (0.40/16 = the same 0.025; 0.40/8 = the same 0.05), so
their prices are byte-identical across the change. Only 5sim's divisor moved.

*History: the owner was shown this correction on 2026-08-05 and first chose to
keep 13.2×, then reversed the same day and asked for the true 10×. Both
decisions are recorded because the file briefly documented "keep it at 13.2×"
as settled.*

**Applied effect, measured after the resync** (9,281 priced active routes):
median route **7 → 6 credits**, share reachable with the $2.99 entry pack
**36.5% → 48.3%**, $5.99 covers 81.1%. tinder/co (18¢) went **6 → 5 credits**,
which is the whole point — it now fits the smallest pack a new user can buy.
Asserted zero rows for each of: priced below wholesale, order-time ceiling below
the route's own cost, and `premium_credits < retail_credits`.

**The pack ladder gained its 8-credit rung on 2026-08-10** (owner decision; in
build 39 = 2.0, WAITING_FOR_REVIEW). The case: 51.7% of routes cost more than
the $2.99/5cr pack, the median route is 6 credits, **50% of first purchases are
the $2.99 pack**, and 82% of recently-active wallets held 1–5 credits — users
bought the entry pack and still couldn't afford the route they came for. The
ladder is now 5/$2.99 · **8/$3.99** · 12/**$5.49** (was $5.99 — repriced so the
chain stays strictly cheaper per credit; $3.99/8 = $0.499 would have tied the
12-pack exactly) · 30/$12.99 · 60/$24.99 · 150/$59.99, asserted by the restored
full-chain `assertLadderImproves()`.

Three things that will bite if forgotten:
- **`credits.8` is marked `optional` in `CreditPack.swift`**: until its own IAP
  review clears, `CreditsSheet.visiblePacks` OMITS the row (never renders it
  "Unavailable"); the moment StoreKit returns it, it appears on every 2.0(39)
  install with no release. Non-optional packs keep the "Unavailable" treatment —
  that state means a load failure and must stay visible.
- **ASC consumable price equalization is a ladder-inverting trap.** FRA €5.49
  equalizes to USA **$4.99**, which would have priced 12cr under the 30-pack per
  credit — the same FRA-anchor drift as 2026-07-31. Every pack therefore carries
  MANUAL prices in both USD and EUR (same numeral); never set only the base and
  trust equalization. Bases remain mixed per product (5/12/30 FRA; 8/60/150 USA)
  — change a price on the product's own base, don't rebase.
  🔴 **This rule was NOT true for credits.60/150 until 2026-08-22.** Both had a
  manual price in the USA ONLY, so every euro storefront showed Apple's
  equalized **€29.99 / €69.99** — and in euros the 30-pack (€0.43/cr) beat the
  60 (€0.50) and the 150 (€0.47). Caught from the owner's own phone; the
  client's `assertLadderImproves()` cannot see it (it runs against one
  storefront). Fixed with `scripts/asc-fix-eur-pack-prices.py` (dry-run by
  default): manual **€24.99 / €59.99 in all 25 EUR territories**, read back
  from ASC. An IAP price schedule can only be REPLACED (POST carries base +
  the full manual list), never patched. Re-run the dry run after any pack
  price change; "manual: USA=…" alone on a pack is the inversion waiting to
  happen.
- **`PRODUCT_TO_CREDITS` has credits.8 and `iap-verify` was redeployed
  2026-08-10 13:24Z** — before that the deployed bundle predated the mapping and
  a credits.8 purchase would have 400'd `unknown_product`. `credits.5` stays in
  the map and the ladder (impulse anchor; owner kept both rungs).

After the new ladder sells, **re-derive `NET_USD_PER_CREDIT` from receipts**
(the standing rule above): the 8-pack nets $0.424/cr and the repriced 12-pack
$0.389/cr against the measured 0.40 — a mix shift moves the margin constants.

`MIN_MARGIN_FALLBACK`, `MIN_MARGIN_BY_PROVIDER` and `marginFor()` are
**DELETED as of 2026-08-28** — with one uniform curve there is no per-provider
inverse to resolve, so an unknown provider is priced and ceiled identically to
a known one. All four `MAX_WHOLESALE_CENTS` remain **100_000** (non-binding
since the 2026-08-04 ceiling removal) and are still per-file copies — that
duplication warning survives for THEM, just no longer for the divisors, which
have exactly one definition now.

*Why not the uniform 0.025 originally agreed.* It was modelled against the live
catalog first, and it doubles **SMSPVA** too — 7,757 of 12,564 active routes,
and the better-delivering provider (34% vs HeroSMS 21% on orders that got a
number). Its 3-credit reach would have gone **729 → 16 routes**, the same shape
as the 2026-07-25 divisor change that cut 1-credit reach from 971 to 24 and
produced a 24h funnel of 11 signups → 2 orders → 0 codes → 0 purchases:

| option | reach @3 cr | routes in the 2–8 cr band |
|---|---|---|
| hero 12× / smspva 6× (**shipped**) | 1,235 → **2,267** | 3,692 → **5,037** |
| uniform 12× | 1,235 → 1,546 | 3,692 → 3,848 |
| status quo | 1,235 | 3,692 |

(2–8 cr is where measured delivery is 46–59%; 9+ cr is 19%, 1 cr is 18%.)

Measured after the run: HeroSMS median retail **15 → 6 credits**, mean realised
margin **97× → 14×**, SMSPVA untouched at a median of 17. Asserted zero rows for
each of: priced below wholesale, `premium_credits < retail_credits`, and
order-time ceiling below the route's own cost.

Two hazards this file warns about did **not** apply, because SMSPVA's divisor
never moved — but re-read them before touching it: `sync-smspva-operators` still
uses 0.05, so `premium_credits` needed **no backfill**, and every FIXED grant now
buys *more*, not less (1 cr reaches 461 routes, up from 24; the 3-credit signup
grant reaches **2,267 routes across 225 of 265 services**).

**`sync-herosms` is now a retail-setting sync and carries the RATCHET**, into its
own `herosms_smoothed_cost_cents` column. `herosms_cost_cents` stays **raw**,
because that is what the order-time margin gate reads and smoothing it would
only hide drift. Its `MAX_WHOLESALE_CENTS` is **375**, not sync-prices' 750 —
same "hide only what a user literally cannot buy" rule, recomputed for this
divisor (150 credits × $0.025).


## The line store, redesigned three times (2026-08-23 → 2026-09-09)

*The price on the first screen has now been added and removed twice, and the
number list moved behind a sheet. If cancellations inside the first minutes
climb again, the argument for putting the price back is here.*

### The store leads with the PRODUCT, not the inventory (2026-09-09)

🔴 **Owner decision: the store's first screen carries NO numbers and NO
price.** It is the app's launch surface now (see the tab note at the top of
this file), so it reads: headline → four capability rows → one button,
**"Choose your number"**, which opens the picker as a SHEET. The numbers, the
country chips and the city list are all pages of that one sheet — the same
shape `LineSwapSheet` already uses, sharing every row through
`LinePickerRows.swift`. Tapping a number goes to `LineCheckoutScreen`, which
is where the price is stated, in full, immediately before Apple's sheet
(3.1.2(a) is satisfied there and was never satisfied by the store line).

- 🔴 **THE CALLING ROW STATES THE ALLOWANCE, AND IT IS NANP-ONLY.**
  `voice_rates` has exactly ONE row with `covered_by_allowance` — the +1
  "United States & Canada" row. UK/FR/DE/ES/IT/NL and 43 others are
  **0.75 credits/min charged to the wallet**, and `begin_intl_call_claim`
  refuses anything not `enabled`. The copy is therefore "Call the US and
  Canada — 100 minutes included, plus 50 more countries at low per-minute
  rates". **"Free calls to the UK" was proposed and is FALSE** — it is a
  promise the server declines at the moment of use, i.e. a refund and a
  3.1.2 problem. Re-derive before touching it:
  `select iso2, credits_per_min, covered_by_allowance from public.voice_rates
   where enabled;`
- **`usSoon` no longer mentions calling** (the capability row owns it) and is
  now only the inbound-SMS limit, which is the one thing on the screen a
  reader can be wrong about in a way that costs them money.
- **The number search moved out of the screen's `.task` into `openPicker()`.**
  Prefetching would fire `line_numbers_shown` for every visitor and silently
  turn it into a second `line_store_view`. New event
  `line_choose_number_tapped` sits between them. ⚠️ **`line_numbers_shown` is
  not comparable across this release** — split the funnel on the ship date.
- **`priceNote` is kept in the file, referenced by nothing.** This decision has
  now reversed three times (no price 2026-08-06 → price 2026-08-23 → no price
  2026-09-09); if cancellations inside the first minutes climb again, putting
  it back is one line.
- ⚠️ **The `-screenshot lineStore` frame no longer shows numbers**, so the ASC
  screenshot taken from it describes a screen that no longer exists. Re-take
  before the next submission.
- ⚠️ **The picker sheet is BUILD-verified only** — the store screen itself was
  screenshotted on the simulator, but tap automation was unavailable, so
  nobody has actually walked country → city → number → checkout. Do that on a
  device before shipping.

**2.8 (2026-09-03, owner decision): the store is ONE screen, not four.**
2.7's flow (pitch → country → city → number → checkout) measured 162
`line_store_view` / 106 viewers / **0 subscriptions** in its first days
(⚠️ **confounded — found 2026-09-05: the store was refusing EVERY country as
`country_not_sellable` for most of that window; see "THE STORE WAS DARK" in
the line country catalog section. Re-measure before drawing conclusions from
the 2.7 numbers.**), and
the line was the only product with NO funnel event between "opened the tab"
and "subscribed". ⚠️ **SUPERSEDED 2026-09-09 — see the section above: the
numbers and the price are no longer on the store screen at all.** What
survives from 2.8 is everything about WHERE the numbers come from and how
they render, which now applies to the picker sheet instead. *2.8 text:*
`LineStoreScreen` renders pitch + three real numbers +
the price on one scroll (default place = **the US for everyone, owner
decision 2026-09-06**, when the catalogue says US is sellable, else the
server default CA/Toronto — 2.8/2.9 used the device storefront country when
sellable, which showed every EU reader a Toronto number; the alpha-3
`Storefront` mapping is deleted). **The sellable countries are a row of
flag CHIPS on the store itself** (`LineCountryChip`, same 2026-09-06
decision — the owner landed on the US default and "couldn't choose"
Canada or Puerto Rico because the country list lived one tap behind
"Change"); the "Change" button now opens the sheet on the CITIES of the
chosen country only (the country list survives in the sheet for the
`country_not_sellable` escape). The server curates cities for all three:
US 12 (New York first — so the live default label reads "New York", not
"United States"), CA 7, PR 1; re-query `line_localities`. **Every number row leads
with the country's flag** (`LineOfferRow` → `CodeFlag`, same 2026-09-06
decision; the flag code is the offer's `country_code`, else the search
country, and only an offer with neither falls back to `PeerAvatar`);
`BundledFlags/pr.png` was added so all three sellable countries render
offline. **The headline reads "A real American or Canadian number…"**
("American", not "US" — same day; the owner read the old wording as
leading with Canada). **`coldStart` loads the rented line BEFORE the
reveal and `AppState.linesLoaded` gates the Number tab** (same day): a
subscriber opening the tab saw the store for one frame before their own
number replaced it, because `lines` was only fetched by the tab's own
`.task`. `LineScreen` now renders the store only when the first read has
ANSWERED (success or failure); until then, bare background. Screenshot
frames set the flag through `loadLine`'s early return. **The same fix, one
collection down, for the flash that survived it:** the edge logs showed
the new build opening the tab with `my_line` + `line_threads` and NO
`line_country_menu` (so the store was gone), yet the owner still saw "the
initial page" — the Messages segment's "Your number is live" instruction
card, rendered on an empty thread list until the first `line_threads`
read answered. `coldStart` now loads the threads too when a line exists
(same step) and `AppState.lineThreadsLoaded` gates the card. Diagnose
this class from the edge logs, not the code: which REST paths fire, in
what order, on the tab open. **The "Rent another number" cover
(`flow == .lineStoreMore`) had NO way out** — a cover has no tab bar and
no swipe; `LineStoreScreen` now takes `onClose` (rendered as the ✕ the
Orders cover uses) and the cover passes `{ state.flow = nil }`;
tap a number → `LineCheckoutScreen` unchanged except the three "Not yet" rows
moved into a collapsed "Good to know" BELOW the price. The pitch names the
limit plainly — "Might not work on every service — … switch to a new number
for N credits" — with N from `appStatus.lineSwapCredits` and a figure-free
variant when nil; never a literal. **Seven line events now exist**
(`line_numbers_shown`, `line_place_changed`, `line_number_picked`,
`line_checkout_view`, `line_plan_selected`, `line_purchase_result{outcome,
plan}`, `line_provisioned`); `line_purchase_result` is emitted ONLY from
`SubscriptionStore.purchase`, never from `handle()`, which renewals and
restores also reach. Read the funnel at ~100 `line_numbers_shown` before the
next redesign. `ScreenshotPricing` reads $5.99/$59.99 (it said $9.99/$99.99
for two days after the reprice); the `-screenshot lineStore` frame is now the
numbers screen, so the ASC screenshot must be re-taken. Ops: `opsFormat.ts`
`LINE_PRICE_USD` is 5.99 (the MRR line over-counts yearly subscribers; exact
figures wait on subscriptions entering `revenue_snapshot`). ⚠️ Margin: $5.99
nets ~$5.09 against $1/mo rent + $1 upfront; a heavy CALLER (100 domestic
minutes ≈ $1–2 wholesale) still clears, but the headroom that justified
"hard-stop billing holds even on the heaviest user" is now ~$2, not ~$4.

⚠️ **`subscriptionAvailability` MUST EXIST BEFORE PRICING.** Setting a price
first returns a useless **409 `ENTITY_ERROR.RELATIONSHIP.INVALID`** pointing at
`/data/relationships/subscriptionPricePoint/id` — which reads as a bad price
point, and the price point is fine. Create `subscriptionAvailabilities`, then
price. Nothing in the error says so.

🔴 **A `MISSING_METADATA` PRODUCT IS NOT RETURNED BY StoreKit — NOT EVEN IN
SANDBOX.** From the phone this looks like a bug in your own app:
`Product.products(for:)` returns an empty array, so the app renders whatever
its "no product" branch says. Ours said *"Second numbers are temporarily
unavailable"* and the CTA still looked live, so tapping it ran the whole
reserve-then-purchase path just to surface an error. **Check the ASC state
before debugging the client.**

⚠️ **CREATING A BASE PRICE OVER THE API DOES NOT PROPAGATE TO OTHER
TERRITORIES.** The ASC web UI fills every territory from the base automatically;
the API does not. Measured 2026-08-06: `subscriptionAvailability` listed **32**
territories while `GET /v1/subscriptions/{id}/prices` returned **one** record
(USA), i.e. 31 territories with no price at all. Confirm with
`?filter[territory]=FRA` — it returns `total: 0`, not an error.

The fix replicates what the UI does — take the base territory's price point,
ask Apple for its equivalent everywhere else, and create each price:

```
GET  /v1/subscriptionPricePoints/{basePointId}/equalizations?include=territory&limit=200
POST /v1/subscriptionPrices   { subscription, subscriptionPricePoint }
```

Script: `scripts/asc-equalize-subscription-prices.py` (supports `--dry`).

🔴 **A SUBSCRIPTION'S TERRITORY SET IS IMMUTABLE — THE ONLY WAY TO WIDEN IT IS
TO POST A WHOLE NEW `subscriptionAvailability`.** Learned the hard way
2026-08-19 while creating the mail products. `subscriptionAvailabilities`
allows **only CREATE and GET_INSTANCE** ("The resource
'subscriptionAvailabilities' does not allow 'UPDATE'"), and the
`availableTerritories` relationship allows only GET ("does not allow 'CREATE'.
Allowed operations are: GET_RELATED, GET_RELATIONSHIP"). So there is no PATCH,
no DELETE and no add-a-territory call. A fresh `POST /v1/subscriptionAvailabilities`
carrying the FULL list silently **replaces** the old record — verified by
reading the count back, 1 → 175.

The consequence for any new product: creating availability with the base
territory only, as `asc-create-mail-subscriptions.py` does so that a price can
exist at all, leaves the product sellable in ONE country until you re-POST the
full set. Always read the territory count back; the failure is silent.

⚠️ **When re-POSTing, guard against an empty list.** ASC read calls fail
intermittently under load, and a POST built from an empty read returns a bare
500 `UNEXPECTED_ERROR`. `scripts/asc-mail-territories-and-prices.py` refuses to
proceed when the target list looks wrong for exactly that reason — it fired on
the first real run.

🔴 **EQUALIZATION IS APPLE'S FX CONVERSION, NOT "the same price elsewhere", AND
IT BREAKS LADDERS.** Measured 2026-08-19 on the mail products: a $29.99 yearly
equalized to **€34.99** against a monthly that equalized to €2.99 — so the
Eurozone yearly saved **2.5%** against 12× monthly where the USD pair saves
16%. Nobody would ever choose it. Same class as the credit ladder drifting to
$4.99-vs-€5.99.

The fix generalises the repo's "manual USD and EUR, same numeral" rule without
hardcoding which territories use EUR: a price point id is base64 of
`{"s": subscription, "t": territory, "p": tier}`, and the SAME TIER INDEX
carries the same numeral in every currency that can express it. So build the
same-tier point id per territory, read it back, and use it **only if
`customerPrice` equals the base numeral exactly**; a currency that cannot
express it (JPY has no 29.99) fails the check and keeps Apple's equalized
price. Live result: 135 of 174 territories took the same numeral, JPY stayed
¥5000.

⚠️ **ASC's IAP `state` RECOMPUTES LAZILY — but not THAT lazily.** A 20-minute
poll after the screenshot landed, and a further 9 minutes after the 31 prices
landed, both stayed `MISSING_METADATA`. So treat "no change after ~5 minutes"
as a real missing field, not propagation. **The API will not name which field**
— there is no reasons array anywhere on the resource. The web page flags it in
red; that is the fastest diagnosis by a wide margin.

**Do NOT use `POST /v1/subscriptionSubmissions` as a diagnostic.** It would name
the missing field in its error — but if the read is wrong and the metadata is
in fact complete, it SUBMITS, and cancelling an IAP submission leaves the
version `DEVELOPER_REJECTED` and needs the web UI to recover (see Release prep).

**THREE HYPOTHESES TESTED AND DISPROVED (2026-08-06) — do not re-run them:**

1. **Missing review screenshot.** Uploaded, attached, `assetDeliveryState: COMPLETE`
   with no errors. State did not move in 20 minutes.
2. **Territories priced only in the base.** Genuinely true and genuinely a gap —
   1 of 32 priced — and fixing it (all 32 now) did not move the state in 9 minutes.
3. **No editable app version to attach a first subscription to.** Every version
   was `READY_FOR_SALE`; created draft **2.0** (`007bfea8-…`,
   `PREPARE_FOR_SUBMISSION`). State did not move in 12 minutes.

Keep version 2.0 — it is needed to ship anyway. Fixes 1 and 2 were real defects
worth having regardless; neither was THE blocker.

**The API does not expose a reasons array anywhere on the resource, and every
field it does expose is present.** Stop probing: open the subscription in the
App Store Connect **web UI**, which flags the missing item in red. That is the
only remaining diagnosis and it takes seconds.

**Verified present on `6798378879` as of 2026-08-06, so do not re-check these:**
en-US subscription localization (name + description), subscription **group**
localization, review notes, `subscriptionPeriod`, `familySharable`, 32-territory
availability, an `appStoreReviewScreenshot` attached and `COMPLETE` with no
errors, and prices in all 32 territories. The app's `primaryLocale` is `en-US`,
so the localization matches. The remaining untested hypothesis is that a
**first** subscription must be attached to an app version before ASC will call
it ready.

⚠️ **Base territory is USA, deliberately.** The credit-pack ladder mixed FRA and
USA bases and silently drifted to $4.99-vs-€5.99 on the top revenue product.
One base per ladder.

**`sandboxOptIn` on the grace period is not optional for us** — without it the
`DID_FAIL_TO_RENEW`/`GRACE_PERIOD` branch of the line state machine cannot be
exercised in Sandbox at all.

**Two things still block the product, and both are genuinely blocked:**
- **App Store review screenshot** — needs the in-app subscription UI to exist,
  so it waits on the client. This is the whole of the remaining
  `MISSING_METADATA`.
- **ASSN V2 URL** (`subscriptionStatusUrl`, and the sandbox twin) — currently
  `null`. Set both once `apple-notifications` is deployed; Apple validates
  reachability, so pointing at a function that does not exist yet will fail.

`VirtualSIM/Products.storekit` carries a matching local subscription group —
local StoreKit testing does not read ASC, so the two must be kept in step by
hand.

**Landed so far (all verified against live DB state, not deploy logs):**
- `20260805170000_phone_lines.sql` — 6 enums, 7 tables, the `my_line` view,
  19 SECURITY DEFINER RPCs, `set_lines_paused`, the `app_config_read`
  whitelist widened to a **fourth** key, `telegram_events` kinds widened.
  Verified by 14 structural + 18 behavioural assertions (the latter inside a
  transaction that rolls back).
- `_shared/iap.ts` — `verifyAppleJWS<T>()` extracted so ASSN V2 reuses the
  root pin and the P-384 workaround instead of growing a second verifier;
  plus `verifyNotificationJWS`, `verifyRenewalInfoJWS`, and
  `isSubscriptionProduct`. ⚠️ **`PRODUCT_TO_CREDITS` must NEVER gain the
  subscription id** — one entry pays credits on every renewal forever.
  ✅ **`iap-verify` WAS redeployed on 2026-08-06**, so it now runs the same
  `_shared/iap.ts` as `apple-notifications`. (This entry said "NOT redeployed"
  for a day after it was — check `supabase functions list` rather than this
  line.) `iap-verify:121` still returns 400 `unknown_product` and PAGES, but a
  renewal cannot reach it: `IAPStore.handle` dispatches subscriptions by
  productID and returns before the credits path.
- `_shared/telnyx.ts` — the full adapter now: Ed25519 webhook verification,
  numbers (search/order/reserve/release), messaging, voice credentials, and
  detail records. (This entry said "signature verifier and fault vocabulary
  ONLY" long after the wrappers landed.)

  ⚠️ **Which parts were PROBED and which were written from the docs is the
  distinction that matters, and the file marks it.** Numbers and messaging were
  probed against a real account; the VOICE block and `classifyTelnyxFault` were
  not. The detail-records block was written from the docs and was **wrong
  twice** — both `filter[date_range][start_time]` and `record_type: "call"`
  returned 400 — which is exactly why unprobed adapters record their faults
  instead of assuming. `mint-line-token` writes `app_config.telnyx_voice_faults`
  and `sync-telnyx-cdr` writes `telnyx_cdr_faults` / `telnyx_cdr_probe` for the
  same reason: **the first real use IS the probe.**
- `scripts/verify-telnyx-signature.ts` (21 assertions, self-contained),
  `scripts/verify-apple-jws.ts` (12, against REAL receipts), and
  `scripts/verify-line-lifecycle.sql` (12 BEHAVIOURAL checks inside a
  rolled-back transaction — renewal ordering, segment correction, call session
  ownership, the reclaim sweep, the stale-call and stale-message backstops).
  Run the JWS one after ANY change to `iap.ts`; a local pass is necessary but
  **not sufficient**, which is exactly how the P-384 outage hid for weeks.
  ⚠️ Run the SQL one after any change to the line RPCs — a structural check
  proves a function exists, and only a behavioural one catches an index that is
  present, correct and unreachable from the code that needs it.

**Pricing (owner decision 2026-08-05): $9.99/month, 200 SMS + 100 minutes,
hard stop.** Nets $8.49 after Apple's 15% against a worst case of ~$4.30, so
margin holds even on the heaviest user. ⚠️ **You cannot apply the 10× credit
rule here — the market sets this price** (Burner/Hushed $4.99, Sideline $9.99,
Google Voice free). At $4.99 with the same allowance the line LOSES money on a
heavy user, and hard-stop billing means there is no overage to recover it.
The schema defaults already encode this (`sms_allowance 200`,
`voice_allowance_seconds 6000`).


## Pausing the eSIM line (line since permanently parked)

### Pausing the eSIM line (backend only, no build) — 2026-07-31

**eSIMs are PAUSED as of 2026-07-31** while the owner switches eSIM providers.

🔴 **THE eSIM LINE IS PERMANENTLY PARKED IN vSMS (owner decision 2026-08-29):
the owner moved the eSIM business to a SEPARATE app.** Do not propose the
top-up, do not resume the line, do not build on it here. The infrastructure
below stays as-is deliberately — kill switches already hold it off, the
nightly sync is harmless, `check-esim-usage` still serves the 12 legacy
eSIMs, and the balance alert is muted while paused.

*Historical — the state this section was written for:* the switch happened
2026-08-10: eSIM Access is implemented end to end and the line stayed paused
pending an account top-up (~$50 minimum).
Resume checklist: top up → confirm `/balance` shows eSIM Access fresh → re-run
`sync-esim-plans` once → `/esim on` (must report `plans_changed > 0`) → assert
`select count(*) from esim_plans where status='active' and id not like 'ea:%'`
is **0** — only `ea:` plans may ever come back on sale. The migration
`20260810160000` nulled `last_checked_at` on every SMSPool row precisely so
`set_esim_paused(false)`'s 3-day freshness predicate can never resurrect them.
API behaviour lives in `@.claude/rules/providers.md` ("eSIM Access API").

```sql
select public.set_esim_paused(true);   -- off the shelf
select public.set_esim_paused(false);  -- back on
```

Both return `{paused, plans_changed, plans_active}` — **read it**. Resuming a
catalog whose provider is gone re-activates **0** plans, and that has to be
visible rather than looking like success.

The lever is `esim_plans.status`, chosen because both halves already key on it
and therefore needed **no app change** — which was the requirement, since the
released build 18 cannot be modified:
- the client fetches `esim_plans?status=eq.active` (true of build 18 **and** 19),
- `create-esim-order` already refuses a non-`active` plan with
  `plan_unavailable`, so a client holding a **cached** catalog still cannot buy.
  That guard predates the pause; it is reused rather than duplicated.

Three things that keep working, verified before building this:
- **The 12 live eSIMs.** `check-esim-usage` looks plans up by id with **no**
  status filter, so usage, expiry stamping and the QR are unaffected. All 12
  also carry their own `data_total_mb`, so the gauges read from the ORDER row.
- `expire-esim-orders` — untouched.
- `sync-esim-plans` keeps RUNNING while paused, writing `status: 'hidden'`. That
  is deliberate: it refreshes `last_checked_at`, which is the signal resume uses
  to decide what may come back. Blanket-activating every hidden row would
  resurrect exactly the plans the sync retires as delisted.

**The watchdog's eSIM-catalog freshness check is skipped while paused.** Pausing
means the old provider stops being synced by design, so without this the owner
is paged every 6h about a staleness they chose — and alert fatigue on the only
monitoring channel is how a real outage later gets missed. The function was
regenerated from `pg_get_functiondef` and diffed clause by clause: **exactly one
hunk differs**, every other check byte-identical (see the "one-line refactor is
a monitoring outage" gotcha — this is the procedure it demands).

Accepted cosmetic cost: the client resolves an order's plan out of the fetched
catalog (`EsimOrder(server:plan:)`), so while paused a live eSIM shows the
fallback name **"eSIM"** instead of its plan name. Usage and data totals are
unaffected. 12 users, for the length of the switch.

**Build 18 shows a near-blank eSIM tab while paused** — its store renders an
empty `Card` with no empty state, and blankness reads as "broken". Nothing can
fix that without shipping. **1.6 adds a real empty state** (`emptyCatalog` in
`EsimStoreScreen`) which deliberately does **not** name a cause: the catalog is
equally empty when the line is paused and when the fetch merely failed, and
asserting a provider switch in the second case would be a guess dressed as fact.


## Support chat — the in-app/Telegram design, replaced by WhatsApp in 2.9

*The server half is still deployed and still serves builds ≤ 2.8.*

### Support chat — user types in-app, owner answers from Telegram (2026-07-30)

🔴 **THE IN-APP CHAT IS GONE FROM THE CLIENT AS OF 2.9 (owner decision
2026-09-05). Support is a `wa.me` deep link to the owner's WhatsApp Business
(`LegalLinks.supportWhatsAppE164` = `+14375243093` — the owner's OWN rented
vSMS line, verified with WhatsApp Business).** Two entry points, both
client-only: Account → Support → "Message us on WhatsApp", and a "Have any
questions? Contact support on WhatsApp" card at the bottom of Home. The
prefilled first message carries the build and the first 8 chars of the user
id so the account can be found without asking. `SupportChatScreen.swift` and
`SupportAPI.swift` are DELETED. **Everything below — the tables,
`support-send`, the Telegram relay, `/support`, the Accept button — stays
deployed** because 2.8 and older still send through it; do not tear it down
until 2.9 is adopted. Why: the Telegram path was answered late or not at all
(a refund request sat 11 days unanswered; the 09-05 swap complaint was
answered 2h25m later), and WhatsApp is where the owner actually is.
*Historical below.*

`support_threads` + `support_messages`, `support-send`, and a widened
`telegram-webhook`. Built at this size because the measured failure is
impatience: cancels land at a median of 57s while codes land at 58s, and a human
saying "give it thirty more seconds" converts into the one event that drives
retention.

**The owner answers by REPLYING to the relayed Telegram message.** That is what
`support_messages.tg_message_id` is for — every relayed message records the id
Telegram assigned it, so an inbound `reply_to_message.message_id` resolves back
to a thread. Matching on a thread's LATEST id instead misroutes the moment the
owner scrolls up to answer the older of two open conversations.

Three security points, since this widens the one public endpoint:
- **A `callback_query` carries its chat under `callback_query.message.chat.id`,
  NOT `message.chat.id`.** Reusing the existing owner check would have left the
  [Accept] button completely ungated. It gets its own comparison.
- The reply branch runs **before** command parsing, so an answer beginning with
  "/" reaches the user instead of being eaten as an unknown command — and falls
  through to commands when the reply is not ours.
- Both tables are **read-only to clients**. RLS is row-level and cannot stop a
  client inserting `sender='agent'` and impersonating support, so every write
  goes through `post_support_message` on the service role.

**Telegram only delivers the update types named in `allowed_updates`, and the
webhook was registered with `["message"]`.** So every `callback_query` — i.e.
every press of the [✅ Accept] button — was dropped by Telegram *before* it
reached our function. Nothing logged, no error, no trace: the thread simply
stayed `open` while the owner tapped a button that did nothing. Verified
2026-07-30 via `getWebhookInfo`, which reported `allowed_updates: ['message']`.

Registration now lives in the repo as **`telegram-setup`** (cron-gated, deploy
`--no-verify-jwt`) rather than in someone's shell history. It names
`["message", "callback_query"]` explicitly — relying on Telegram's default set
means a future default change silently disables a feature — and returns
`getWebhookInfo` from **before and after**, so "did this actually change
anything" is answerable. Trigger it the same way as any cron-gated function
(`net.http_post` + `private_cron_secret()`), which is also why the bot token
never has to leave the platform. **Re-run it after changing the webhook URL, the
webhook secret, or adding any new update type.**

**Plain text from the owner is an ANSWER, not a mistyped command.** Replying to
the relayed message is still the way to target a specific conversation, but
typing a bare message while a thread is `assigned` now routes to that thread —
which is the obvious thing to do after pressing Accept, and previously got
swallowed by the command parser and answered with the help text while the user
waited. The confirmation **names the recipient**, because picking "most recently
active assigned thread" is a guess the owner has to be able to catch.

`post_support_message` serialises per user with the same advisory lock as
`begin_order`; without it a double-tap creates two open threads and the partial
unique index turns the second into a raw 23505 the client cannot interpret.
Storage happens **before** the relay, so a Telegram outage cannot lose a message
the user was told we sent. Replies push with `kind=support` and deliberately **no
`orderId`** — `PushManager` routes on that key and would deep-link to the wrong
screen.


## Badge confidence, and the labels that no longer render

### Badge confidence — demote fast, promote slow

`success_rate` starts as SMSPVA's own per-country grade (`sync-smspva-conversions`:
3→90, 2→70, 1→40) with `rate_source='seeded'` — a vendor number about a route we
may never have sold. `refresh_route_observed_success` is **asymmetric** since
`20260725120000`: promoting still needs `p_min_sample` (3) conclusive attempts,
but a route with **zero** codes loses its seeded rate at **2**. Hiding still
requires the full 3, so a 0-of-2 route goes honest without leaving the shelf, and
a single unlucky miss changes nothing. Verified live: leboncoin/pt went seeded-90
→ measured-0 (sample 2, still active); betano/bg (0/7) hidden; facebook/dk (4/5)
untouched at 80.

**Only orders that actually got a number are evidence** (`and o.smspva_number is
not null`, migration `20260727120000`). Orders that die inside `create-order` —
`margin_too_low`, stockout, provider fault — close in under a second with a null
number and used to count as delivery failures. That was self-reinforcing, because
one `is_conclusive` clause counts a cancel when the same user reorders the same
service within 10 minutes, which is exactly what a user does when the button keeps
failing: price ticks above the ceiling → every attempt refused before a number is
reserved → the user retries → each retry marks the previous one conclusive → the
route auto-hides at 0%. Live on 2026-07-26 one user tapped TikTok/Netherlands 8
times in 90s and **deleted the route from the catalog**; it had zero orders in the
lookback that ever held a number.

**Four more evidence rules, all learned the hard way on 2026-07-27:**

1. **`is_code` is `otp is not null`, NOT `status = 'received'`** — a rescued code
   lives on a `canceled` row (see the late-code rescue above). Applied to
   `refresh_route_observed_success`, `refresh_service_delivery`,
   `recent_sms_delivery_rate` and `run_watchdog`.
2. **The numberless filter has to be back-ported to every consumer.** It was
   added to two functions and missed on `recent_sms_delivery_rate`, which gates
   `stranded_credit_candidates` at ≥40 — so a run of price-ceiling rejections
   could silently suppress the winback cohort. If you add a fifth consumer of
   order outcomes, it needs the same predicate.
3. **The lookback is 30 days, and the wipe is CONDITIONAL.** It defaulted to 3
   days with an unconditional wipe, which at ~10 orders/day left **exactly one
   measured route in a catalog of 17,807** — `facebook/dk` was measured at 80%
   and deleted three days later. A measured rate is now cleared only when the
   new window genuinely has nothing to say about that route.
4. **Auto-hide for poor delivery is GONE (2026-07-28, `20260728120000`) — label,
   don't hide.** `refresh_route_observed_success` no longer sets `status =
   'hidden'` for delivering zero; it only measures, and only ever *un*-hides
   (recovery, and evidence ageing out) so routes hidden by the old rule can come
   back. Hiding for **price** (`sync-prices`, over `MAX_WHOLESALE_CENTS`) and for
   **`blocked_routes`** is untouched — those mean "you cannot buy this", not
   "this performed badly". The change was small in the catalog (**only 4 routes**
   were evidence-hidden; 472 of the 688 hidden are the price kind) and large in
   the UI: see the label rule below. Note the un-hide statement **must** exclude
   `blocked_routes` — without that clause it resurrects `whatsapp|us`, which was
   blocked because those numbers don't work at all.

`refresh_service_delivery`'s wipe is scoped the same way, for the same reason:
unconditional, it left any quiet service with NULL evidence, and
`apply_measured_service_ranking` needs `observed_attempts >= 8` — so a service
that went quiet was frozen at its last `sort_order`, unable to be re-evaluated.

🔴 **OUR OWN RECORD IS NO LONGER RENDERED ANYWHERE — owner decision
2026-08-22, in 2.3.** "Ours: 0 of 4", "Worked X of Y times", "Not tested",
"Rarely works for <service>" and the `DeliveryNotice` odds sentences are
gone from Home, Checkout, ServiceSheet, CountrySheet, Waiting and Recovery.
The vendor's NETWORK rate (`NetworkRateMeter`) is the only delivery figure a
user sees. Everything below about the record is now about DATA and
STEERING only: `DeliveryRecord`, `routes.success_codes`, `routeKey`,
`bestCountry`, `retryKey`, `Country.deliversPoorly` are unchanged and still
decide where the app points a user — they just say nothing on screen. The
history of why the labels existed is kept because the reasoning still
governs the steering, and because the case for them (below) is real: a
route with no label reads as *fine*, not *unknown*. That trade was made
knowingly; do not reintroduce a record label without the owner.

*Historical (1.6–2.2):* every route carried one of exactly two labels —
"Not tested" or "Worked X of Y times" — rendered unconditionally, because a
route we had never sold used to render **no badge at all**, and an absent
badge reads as *fine* for what was then **17,471 of 17,804 active routes**.

Two rules that still govern the DATA (and would govern any future label):
- **A seeded rate is `.notTested`.** SMSPVA's per-country grade (323 routes) is a
  vendor's number about a route we may never have sold once. The old muted
  "~40% estimate" was still a *number*, and users read numbers as evidence.
- **"2 of 7", never "29%".** A percentage off a 7-order sample wears the
  confidence of a 700-order one; the raw pair carries its own uncertainty.

`routes.success_codes` is the numerator (backfilled + written by
`refresh_route_observed_success`) — deliberately stored rather than derived from
the rounded `success_rate`, because an off-by-one in "worked N times" would
discredit any label built on it. (The colour-carries-confidence rule for
`.notTested` vs measured records applied to the labels and is moot while
none render.)


## The vendor-deliverability ranking that preceded `pool_rate_pct`

### The provider's deliverability finally replaces price (1.7, 2026-07-31)

⚠️ **SUPERSEDED IN 1.8 by `routes.pool_rate_pct`.** The reasoning below is why
a vendor rate beats price and is all still true, but the SOURCE and the SORT KEY
both changed on 2026-08-03 — read the next section, "The pool rate is the
tie-break (1.8)". `service_country_ranks` still exists (1,043 rows, repointed to
5sim in `20260803160000`) but it covers **1,043 routes against `pool_rate_pct`'s
2,715**, and `rankedUntestedKey` no longer reads it.

Route-level evidence covers **0 of ~5,980 active routes** as of 2026-08-03 — the
5sim cutover reset it again, exactly as the "evidence must describe the provider
that serves the NEXT order" rule requires. So essentially every route falls
through to the tie-break, and until 1.7 that tie-break was price.

The case in one line: for `google` the cheapest bookable route was **Kenya at 1
credit, which has delivered 0 of 9**, while **Cameroon costs 2 credits and the
provider reports 59.3%**. Price picked Kenya every time.

- **A MISSING rank scores 0 — neutral, never a penalty.** This applied to
  `service_country_ranks`, whose source is a top-10 gated at 50+ activations, so
  absence means "did not rank or lacked traffic", never "bad". leboncoin returned
  **2** countries against **33** active routes; treating absence as a low score
  would have wrongly demoted 31 good routes. **The rule does NOT carry over to
  `pool_rate_pct` unchanged** — see the next section, where absence and a
  published zero are deliberately ranked differently.
- **Our own measurement always outranks theirs.** A measured route wins outright,
  and `RecoveryScreen` only offers a ranked country when we have measured nothing
  — and never the country that just failed.
- **It is NEVER a badge.** `SuccessBadge`/`DeliveryRecord` state what happened to
  orders WE placed ("Worked 3 of 7 times"). This is a third party reporting on
  its own inventory across all its customers. Collapsing the two is precisely
  what made SMSPVA's seeded grade rank never-sold routes as "proven" until it had
  to be demoted to `.notTested`. **The separation still holds in 1.8, but the
  mechanism changed**: the captioned "Top success rates" card and the "reports
  36%" wording are **GONE** (owner decision — see the next section); the number
  now sits on the country row as a bare colour-banded percentage, with an
  advisory line above the list instead of per-row attribution.
- **Exposure, accepted knowingly:** rendering these figures publishes the
  provider's quality data to anyone holding the publishable key. Inherent to
  showing a number. `service_country_ranks` is `authenticated`-only with no anon
  policy; `routes.pool_rate_pct`, which is what 1.8 actually renders, sits on
  `routes` — which has a **`public read`** policy, so that column reads with no
  account at all. Accepted, but it is a wider exposure than the old table.
- **NEVER name or allude to a supplier in user-facing copy** (owner decision,
  2026-07-31). The app must not advertise that it resells someone else's
  inventory. The caption shipped as *"Reported by our supplier across all their
  customers"* and was changed to **"Network-wide rates from the last 24h — not
  our own delivery record"**; `RecoveryScreen` lost *"Our provider ranks…"* the
  same way, and the maintenance and eSIM-pause screens lost "all providers" and
  "moving to a new provider".

  The two rules interact and both must hold: this data still has to be visibly
  **not our own measurement**, so the wording carries "network-wide" plus an
  explicit "not our own delivery record" / "We haven't tested it ourselves yet".
  Dropping the attribution entirely to solve the naming problem would turn a
  third party's aggregate into an implied claim of our own — the exact error
  that demoted SMSPVA's seeded grade to `.notTested`.

  **"Carrier" is fine and is not the same thing** — the Real SIM tier's "named
  mobile carrier" means Verizon/T-Mobile, which is the product, not our
  wholesaler. Grep before assuming a hit: `provider` appears legitimately in
  `providerOrder()`, error codes and internal comments.


## Inventory snapshots and grant history (2026-08 → 2026-09)

*Every figure here was already flagged as moving hourly. Kept for the grant
history, which reversed four times and whose reasoning is still argued.*

### Inventory — these move hourly. RE-QUERY, don't quote this block.

Every number below has been wrong within a day of being written at least once.
It is a starting point for "is this roughly right", never a citation.

- **iOS**: `MARKETING_VERSION 2.12`, `CURRENT_PROJECT_VERSION 59`.
  **2.11 (build 58) is `READY_FOR_SALE` — approved and live, read from ASC
  2026-09-09**, which closes its train to new builds and is why the tab
  repositioning is 2.12.
  **2.12 (build 59) SUBMITTED 2026-09-09 18:28Z — `WAITING_FOR_REVIEW`**,
  version `614dfb01-…`, submission `8651eae6-…`, build uploaded via altool
  with `BuildMachineOSBuild` patched to 25F84 (verified inside the IPA, along
  with `UIBackgroundModes` still carrying audio + voip). Carries: the rented
  line as the FIRST and landing tab with temp SMS/e-mail second as "Temp";
  the product-first line store (no numbers and no price on the first screen,
  picker behind "Choose your number", calling row leading, swap sold as a
  feature); the `OtpScreen` upsell that sells a rented number at the moment a
  temporary code lands; and `/tabs number|temp`, the owner switch for the tab
  order. Release notes rewritten on all 13 locales and read back matching;
  descriptions carried over from 2.11 verbatim, since no capability changed.
  ⚠️ **The picker sheet and the upsell card were never walked on a device** —
  tap automation was unavailable, so both are build-and-screenshot verified
  only. ⚠️ **The ASC screenshots still show the OLD store** (numbers + price
  on the first screen); they were not re-taken for this submission.
  *Historical:* **2.11 (build 58) submitted 2026-09-08 15:44Z**,
  version `894db3da-…`, submission `88b0a10b-…`. Build 58 = build 57's
  inbound-calling work + the second-code resend window's client half (the
  countdown and the earlier-codes list). Release notes gained a second-code
  bullet on all 13 locales, read back matching.
  *Earlier the same day:* build 57 was submitted 10:43Z and **dev-rejected by
  the owner**; the cancel was safe because that submission carried exactly ONE
  item and it was the appStoreVersion — an IAP item would have made it a
  one-way door, so **check `GET /v1/reviewSubmissions/<id>/items` before
  cancelling anything**. 🔴 **Attaching build 58 flipped the version
  `DEVELOPER_REJECTED` → `PREPARE_FOR_SUBMISSION` on its own — NO
  `resolved:true` step was needed.** That gate applies only after a HUMAN App
  Review rejection; after a developer's own cancel the plain attach-then-submit
  path works. Sixth exercise of this recovery.
  ⚠️ Read ASC rather than this bullet — `python3 scripts/asc-release.py status
  2.11`. It has been wrong about the review state five versions running, and
  the version of it written at 12:30Z today was stale by 15:44Z.
  **2.10 is now BUILD 52, SUBMITTED 2026-09-07 07:56Z — `WAITING_FOR_REVIEW`,
  submission `9377bdbc-…` on the SAME version `61c4b4d0-…`** (build 51's
  submission `7d060143-…` was cancelled by owner instruction the same
  morning — the version went `DEVELOPER_REJECTED`, kept every localization
  and both screenshot sets, and took build 52 + a fresh reviewSubmission;
  4th exercise of that recovery path). Build 52 = build 51 + the inbound-
  calling client fixes (see Known-open → INBOUND CALLING; unverified on a
  device at submission). Build 52 is also in the INTERNAL TestFlight group
  "Friends" (`f35b99cf-…`, owner added as its first tester, state INVITED) —
  the owner's iPhone could not be reached from the Mac over USB or Wi-Fi
  (CoreDevice `unavailable`, error 4016), so TestFlight is the install path
  for the device test. Release notes were NOT changed (no calling claim).
  *(Older text below, kept for history:)* 2.10 (build 51) SUBMITTED
  2026-09-06 17:06Z — `WAITING_FOR_REVIEW`,
  version `61c4b4d0-…`, submission `7d060143-…`, build uploaded via altool
  with `BuildMachineOSBuild` patched to 25F84 (verified inside the IPA),
  release notes on all 13 locales (read back matching).** Carries: US-default
  store with country chips and flag rows, the thread preload, the cover
  close button, "American or Canadian" headline. The version also carries
  the new SUBTITLE in all 13 locales (`USA Phone Line &
  Verification`; es "Linea USA y SMS temporal", pt-BR "Numero USA e SMS
  temporario", it "Linea USA e SMS temporanei", fr "Ligne USA & SMS
  temporaire", de "USA-Nummer & SMS-Code", ja "米国の電話番号・認証コード受信")
  and NEW SCREENSHOT SETS** (en-US only — the other 12 locales fall back to
  it): **5 slides per size, as submitted** — the OWNER's own "Get a real USA
  number" slide (made in Claude Design from the raw `lineStore` frame;
  1284×2778 native, upscaled 3% to 1320×2868 for the 6.9" set, so a native
  6.9" export is a worthwhile follow-up) then the four temp-SMS / code /
  e-mail / checkout slides from 2.9. The owner rejected the three slides
  composited by `scripts/screenshots/` (capture-frames.sh → make-set.py →
  asc-upload-screenshots.py); the pipeline stays for raw captures and
  uploads. ⚠️ Two traps in that pipeline: (1) a file downloaded from ASC's
  `templateUrl` with `{f}=png` is PNG whatever its `fileName` says, and
  re-uploading it under a `.jpg` name reads `assetDeliveryState: FAILED` —
  re-encode through PIL first; (2) ASC's web UI shows "6.9-inch" and
  "6.5-inch" as SEPARATE sets, and the owner's upload landed only in 6.5"
  — the 6.9" set (what every current iPhone shows) is `APP_IPHONE_67`; check
  both sizes after any manual upload. The owner's slide carries a "Texts and
  calls" badge — receives texts and calls OUT is the honest reading; if
  Review objects, it is that badge. 🔴 The 2.9 number slides
  it replaced claimed "Send and receive texts", "Make and take calls", showed
  OUTGOING bubbles and said "US numbers are coming soon" — every one a
  claim the product does not honour; they were live until 2.10 ships. The
  sample line fixture is now a US number (`+12125550128`). Nothing else on
  the version was touched (keywords still lack `american`; promotional
  text still empty). ⚠️ ASC showed a notice on 2026-09-06: **new age-rating
  questions about social-networking capabilities, due 2026-09-07**, not
  mandatory for this submission but answerable only in the web UI (App
  Information → Age Rating) — owner action.
  **2.8 (build 49) is `READY_FOR_SALE` (approved by 2026-09-04; users
  were on it that day); 2.9 (build 50 — "Change number" picker with the
  paywall last, chosen-number swap, WhatsApp support link on Home + Account,
  in-app chat deleted, "Great for WhatsApp" pitch) SUBMITTED 2026-09-05
  06:38Z, version `05a960ec-…`, submission `b4dc7f3a-…`, and
  **`READY_FOR_SALE` by 2026-09-06 (read from ASC that day).** The next
  release (the US-default store, country chips, flag rows, thread preload,
  cover close button — all on this branch) needs a NEW version and build
  51.** ⚠️ Neither the swap sheet nor the WhatsApp link was
  run on a device before submission (owner chose review; XcodeBuildMCP was
  down). The 2.8 dialer `+0` fix is also still unconfirmed on a phone. Read
  the live state with `python3 scripts/asc-release.py status 2.9`.
  *(Older text below, kept for history:)* `MARKETING_VERSION 2.6`, `CURRENT_PROJECT_VERSION 47`, iOS min
  **18.0**, **3** SwiftPM dependencies (TelnyxRTC 4.1.2 → WebRTC 139.0.0,
  Starscream 4.0.8). Re-count sources with
  `find VirtualSIM -name '*.swift' | wc -l` rather than quoting a number.
  **2.5 (build 46) is `READY_FOR_SALE`; 2.6 (build 47 — the analytics client
  + `service_search_empty`) SUBMITTED 2026-08-30 19:46Z, version
  `826494f3-…`, submission `40e632e8-…`, all 13 `whatsNew` locales written
  and read back.** See the App Privacy warning in the analytics section —
  the label is web-UI only and was NOT updated by this submission.
  **2.4 (build 45, the line country catalog + country picker) is
  `READY_FOR_SALE` (approved 2026-08-27); 2.5 (build 46 — the phone-app
  Number-tab redesign, the four inbound-calling client fixes, app-wide glow
  removal, named-column fetches, High/Medium/Low rate bands) SUBMITTED
  2026-08-27 20:38Z — `WAITING_FOR_REVIEW`, submission `2410abc6-…`, version
  `ec832ce4-…`.** ⚠️ 2.5 ships the inbound-calling code path with NO device
  verification of ringing or call audio — the listing still keeps incoming
  calls in the "not yet" block, deliberately.
  All 13 localizations carry the corrected listing (no "in and out", no
  trial, inbound calls in the "not yet" block). Read the live state with
  `python3 scripts/asc-release.py status 2.5` — never this line.
  ⚠️ **This line has been wrong about the review state FOUR versions running**,
  each time by describing a submitted build as still in review after it shipped.
  It is a decision error, not a typo: "still in review" is the argument for
  cutting another release. Read ASC — `GET /v1/apps/6774768570/appStoreVersions`
  answers it in one call — and never trust this bullet.
- **Backend**: **49** edge function dirs besides `_shared`, **226** migration
  files, **26** files in `_shared`. (Counted 2026-09-08 with
  `ls supabase/functions | grep -v _shared | wc -l`,
  `ls supabase/migrations/*.sql | wc -l` and
  `ls supabase/functions/_shared | wc -l`. The previous figures — 45 / 193 —
  were stale by 4 and 33; run the commands rather than trusting this line,
  which has never once been correct when checked.)
  ⚠️ **`rescue-unprovisioned-lines` was in NEITHER deploy list until
  2026-09-08** — cron-gated, with its `config.toml` entry, and importing
  `_shared/lineProvision.ts`, so a `_shared` fix would have shipped to every
  function except that one. It is now in the `--no-verify-jwt` list. Re-run the
  check rather than trusting a sum: a function named in neither list is a
  function nobody redeploys, which is exactly how a stale bundle survives a
  fix. `probe-5sim` is still deliberately outside both lists.
  ✅ **The two deploy lists at the top of this file are EXHAUSTIVE**, asserted
  against that 41 programmatically on 08-17 — `rent-line-credits` and
  `sync-line-voice` were in NEITHER list until then, which is exactly how a
  `_shared` fix ships to every function except the two nobody redeploys.
  `config.toml` carries a `verify_jwt = false` entry for all **19** members of
  the cron/webhook group.
- **Catalog** (08-06, AFTER the sync-5sim repair): **15,561** active routes —
  up from 9,358, because 6,900 routes had been seized from the providers that
  own them and hidden (see the changelog entry for that date; the 9,358 figure
  was the DAMAGED state, not a baseline). **468 services**, 5 invisible (was
  18). 69 countries, **60** of them mapped to 5sim. Active by owner: SMSPVA
  7,248, HeroSMS 574, rest 5sim. eSIM (08-11, after the eSIM Access switch):
  **1,633 `ea:` plans across 197 countries + 33 regions**, plus 1,081 legacy
  SMSPool rows kept hidden forever; **0 active — line PAUSED** pending the
  ~$50 top-up (`esimaccess_health` reads $0.00).
- **Evidence**: `rate_source='measured'` = **6 routes**, rebuilding from 0 after
  the cutover. That reset is CORRECT — see "Evidence must describe the provider
  that serves the NEXT order". `rate_source='seeded'` is now **1** row (was
  338): `20260803121000` was finally applied on 08-06 and cleared every seeded
  grade inherited from a provider that no longer serves the route.
- **Balances** move hourly — re-query, never quote:
  `select key, value->>'balance_usd' from app_config where key like '%_health';`
  The PAGE fires at one level per provider (owner decision 2026-09-08): **5sim
  < $5.00 · HeroSMS < $5.00 · Telnyx < $10.00**. Reading 2026-09-08 09:40Z:
  5sim $10.02, HeroSMS $14.94, Telnyx $6.00 (**under its floor — `telnyx-float`
  is firing**), eSIM Access $88.62.
- **App Store**: live version is **1.9 (build 31) `READY_FOR_SALE`**; **2.0
  (build 39) is `WAITING_FOR_REVIEW`** as of 2026-08-10, resubmitted after the
  08-09 human rejection (3.1.2(c) subscription EULA/privacy links + Guideline 5
  CallKit-in-China; see the 08-10 changelog entry). **`credits.8` (8cr/$3.99) is
  `WAITING_FOR_REVIEW` on its own IAP track**; the other five packs `APPROVED`.
  Builds 37 (rejected) and 38 (superseded before submission) are dead; the
  UNRESOLVED_ISSUES resubmission recipe — including the mandatory
  `reviewSubmissionItems {resolved:true}` step — lives under Release prep.
  This file has claimed stale review states for two versions running:
  **read ASC, not this line.**
- **China is REMOVED from the app's territory availability** (owner decision
  2026-08-10; 174 of 175 territories live). Apple/MIIT forbids CallKit in apps
  sold on the China App Store, and 2.0 ships CallKit. Re-adding China requires
  gating CallKit off by storefront first — do not re-tick it casually.
- **Signup grant: 3 credits — RESTORED 2026-08-30 (owner decision), verified by
  read-back (`effective_grant: 3` through `grant_signup_bonus`'s own regex +
  clamp, not just the raw key).** Why: at 2 it VIOLATED this file's own
  invariant — `AppState.minDefaultCredits` is **3**, and the rule is *"the
  floor must never exceed the signup grant … change the two together."* The
  grant was cut 3 → 2 on 08-25 and the floor was left at 3, so for five days
  the starter pick, the auto-landed country and the post-failure retry all
  DEMOTED everything the new user could afford. It is a demotion not a filter,
  so nothing ever read "Unavailable" — the user simply landed on a price they
  could not pay. Two credits reached **1,118 of 9,185 active priced routes
  (12%)** against a median route of **5**. Measured cohorts (dev excluded,
  30d): pre-08-19 **26.6%** of signups ordered SMS / 16 buyers → 08-19–24 at
  grant 3 **15.7%** / 1 buyer → 08-25+ at grant 2 **10.7%** / 2 buyers.
  ⚠️ Grant and floor are now EQUAL at 3; moving either alone re-opens this.
  *History (do not re-litigate, the tension is real):* at grant 5, 49 of 52
  first orders cost ≤5 so nobody met a paywall and pack sales went to ~0.
- **Signup grant history: 2 credits — SET 2026-08-25 (owner decision), verified by
  read-back of `app_config.signup_bonus_credits`.** It was 3 from 08-22 16:58Z.
  Reason for the 08-22 cut from 5, measured that day: at 5 credits, **49 of 52 first orders
  (Aug 20–22) cost ≤ 5**, so new users never met a paywall and pack sales
  went to ~0 while orders recovered; 27 of 28 buyers ever bought BEFORE
  their first order, so the grant must sit below the median route (6 cr).
  The same analysis found the real Aug 15–19 collapse was 2.0's
  number-first onboarding (`create-order` calls 30/day → 1, zero first-day
  orders from 45 signups) followed by the grant-0 days. Re-query rather
  than quoting this line — `/config` reads it live; it was 5 from 08-20
  to 08-22 and this file said 0 the whole time. *History:* set to 0 on
  2026-08-18 (owner decision, after the
  first-session audit). It was 2 from 08-08 to 08-18, and 5 → 0 → 1 → 3 → 0
  in the two days before that. The 08-18 case for 0: **27 of 28 buyers ever bought
  BEFORE placing an order** (median 3.0 min after signup); 112 users ordered
  free and never paid, and 106 of them still hold credits — nobody is refused
  a paywall, they take a free order that fails (first-order delivery 12.8%,
  and ≤2cr routes deliver 10.4% vs 26.7% at 5+cr) and leave. A 2cr grant
  pinned every new user to the worst inventory. Grant 0 puts the paywall in
  front of a GOOD route. ⚠️ Known cost, measured on the 08-04→08 zero era:
  activation fell to ~8%/day; purchases stayed flat. Watch signup→purchase
  over the next 14 days, not signup→order. `handle_new_user()` reads
  `app_config.signup_bonus_credits` live, clamped 0–50, tombstoned via
  `signup_grants`. Rollback is one UPDATE, no deploy. Note `telegram-notify`
  already renders 0 correctly ("no signup credit (grant is 0)").
- **Free e-mail cap: 1/user/day — CUT from 3 on 2026-08-17.** Free email had
  been outselling paid SMS ~5:1 (Aug 15: 3 SMS orders vs 22 free emails) and
  has earned one credit in its lifetime. `app_config.email_free_daily_cap = 1`.

