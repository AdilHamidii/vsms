# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Where things live (split 2026-08-06)

This file was **302 KB / ~75k tokens loaded into every session** — 7.6× the size
at which Claude Code warns about a memory file. Four blocks were moved to
surfaces that load only when they are relevant. **Nothing was summarised or
deleted in the move**; the text is byte-identical, just relocated.

| Surface | Loads when | Holds |
|---|---|---|
| **this file** | always | product shape, money paths, the gotchas list, open issues, provider split, commands |
| `@.claude/rules/providers.md` | editing `supabase/functions/**` | 5sim / HeroSMS / Telnyx API behaviour, both pricing syncs, the sellable-number catalogue |
| `@.claude/rules/ios-client.md` | editing `VirtualSIM/**` | source layout, palette + Liquid Glass, cold launch, the map's per-frame trap, localization, eSIM store ranking, order-state invariants |
| `release-prep` skill | invoked when cutting a release | archive → patch → export → upload → ASC submission, IAP review track |
| `aso-listing` skill | invoked when touching the listing | keywords, screenshots, storefront metrics |

⚠️ **What did NOT move, deliberately.** Everything safety-critical stays here,
because a scoped file is not in context when it is not matched: the money paths,
`Non-obvious gotchas`, `Known-open`, the pricing model and margin gates, and the
provider-switch checklist. **Do not move a "never do X" rule into a scoped or
lazy surface** — it has to be loaded at the moment it matters, which is exactly
when nobody has the relevant file open.

## What this is

**vSMS** (App Store display name; formerly "vSIM OTP" — the Xcode target/scheme is still `VirtualSIM`) — iOS app selling three products, all paid with in-app **credits**: (1) **temporary phone numbers** for SMS verification codes, (2) **temporary e-mail addresses**, and (3) **eSIM data plans** priced at 4× wholesale (line currently PAUSED). A
**fourth** line — rentable second numbers, billed by **StoreKit subscription
rather than credits** — is LIVE ON THE APP STORE in 2.0. ⚠️ **PIVOTED
2026-08-18 (owner decision): the product is now "RECEIVE texts + codes from
US/Canadian senders, and CALL OUT worldwide". OUTBOUND SMS IS DROPPED** — it is
the one capability needing carrier approval (10DLC), which the owner will not
pursue. In 2.1 every send affordance is gone (`ComposeScreen` deleted,
`ThreadScreen` is read-only, `.compose` flow removed) and `send-line-message`
refuses everything with `outbound_sms_retired`. The tab is the SECOND tab (Home
is first — reverted 2026-08-08; this line said "first tab" for ten days after).
**Six numbers rented, five subscriptions, and all five cancelled auto-renew —
median 3.9 minutes after paying.**

Half the product works, and the halves are not the ones this file claimed:
**calling connected for the first time on 2026-08-18** — 3 completed calls to
France (6s / 2s / 23s), each carrying a `provider_call_session_id`, after 7
earlier attempts that never reached the provider at all. Verified against
`line_calls`, not inferred. ⚠️ **That is OUTBOUND calling only. INBOUND has
never once worked** and carries four open client bugs, so "take calls from
anywhere" is not a claim this product can make yet — see Known-open. Meanwhile
**outbound SMS is 1 sent against 6 failed** (`40010`, 10DLC).
Inbound SMS works, 3 of 3. See "Rentable second numbers". iOS frontend in SwiftUI + Supabase backend (Postgres + Auth + Edge Functions + pg_cron).

**Provider split as of 2026-08-10 — 5sim is the PRIMARY SMS provider; HeroSMS
and SMSPVA still serve the services 5sim does not map; HeroSMS also serves the
whole temp-EMAIL line; eSIM Access (esimaccess.com) is the eSIM provider
(line still paused pending a ~$50 account top-up); SMSPool survives ONLY as
the usage/QR path for the 12 eSIMs sold before the switch —
`check-esim-usage` routes on `esim_orders.provider`.**

⚠️ **"5sim for SMS, HeroSMS for e-mail" is the SHORTHAND, and it is wrong as a
description of the catalog.** SMS is a THREE-way split by service ownership,
measured live 2026-08-03:

| provider | active routes | services |
|---|---|---|
| **5sim** | **~4,400** | 146 |
| smspva | ~930 | 115 |
| herosms | ~560 | 102 |

Route counts move on every hourly sync — the service counts are the stable part.
Re-query before quoting a figure:
`select provider, count(*) from routes where status='active' group by 1;`

HeroSMS is therefore *not* e-mail-only — it still fills real SMS orders. Do not
"clean up" its SMS surface on the assumption that it is dormant.

**Why 5sim.** Every provider before it kept its per-(service, country) delivery
rates behind a dashboard session — we searched exhaustively and the answer was
settled as unreachable (see the HeroSMS section). 5sim publishes them **free and
unauthenticated**: `GET /v1/guest/prices` returns, per (country, product,
operator), `{cost, count, rate720}` — a 30-day delivery rate **per pool**. That
turns "buy from the best pool" and "show the user that pool's number" from
guesswork into arithmetic. It is the first time we can steer on delivery before
placing an order rather than after failing one.

**Two 5sim behaviours settled by PAID PROBE on 2026-08-18 (`probe-5sim`,
balance read before/after every step — do not re-run, the answers are
arithmetic, not opinion):**
- **Cancel REFUNDS, fully.** `3.6239 → 3.6109 → 3.6239` on a $0.013 buy.
  Second confirmation (the first was $0.008 on 08-03). `cancel-order`'s core
  assumption holds; with ~60% of numbered orders cancelled, this is the one
  that would bleed float on every order if it were ever false.
- **`user/reuse/{product}/{number}` after a CANCEL returns 400 `"reuse not
  possible"`**, balance untouched, even when the order was bought with
  `?reuse=1`. So reuse CANNOT rescue the "cancelled just before the code" case
  — cancelling releases reuse eligibility with the number. Do not build on it
  for retries. (It may still work after a COMPLETED order, i.e. re-verifying
  the same service on the same number — a much smaller case, not pursued.)
- Incidental: both fresh buys read `status: RECEIVED` with `sms: null` at
  t=0. RECEIVED means "number received", never "code received" — live proof
  that `sms[].code` must stay the only authority. `?reuse=1` is accepted
  silently; nothing in the response says whether it took.
- Also from the docs re-read the same day: **`maxPrice` EXISTS but only when
  `operator=any`** — now passed on the unpinned fallback buy. Pinned pools
  still take no cap.

⚠️ **"Ownership is per SERVICE, never per route" WAS the design rule and the
live catalog does NOT satisfy it.** Measured 2026-08-04: **109 of 254 visible
services have active routes on two providers**, carrying ~80% of all active
routes (instagram is 57 routes on 5sim + 5 on HeroSMS; whatsapp 44 + 4).
Ownership is really per **(service, country)** — per ROUTE.

That is safe for ROUTING — `routes.provider` is a column on each row and
`providerOrder()` resolves it first, so every route deterministically goes to
exactly one provider. It was NOT safe for service-level EVIDENCE, which
assumed disjointness and silently overwrote itself; fixed 2026-08-04, see
"Evidence must describe the provider that serves the NEXT order".

**The split is entirely COUNTRY-driven, not service-driven.** Every non-5sim
active route is in one of **9 countries 5sim does not serve** — Ukraine, Japan,
New Zealand, Singapore, Bosnia, Gibraltar, Malta, Switzerland, Turkey (1,490
routes). There is no service 5sim carries that we merely failed to re-home:
`sync-5sim` re-homes those automatically every hour. Owner decision 2026-08-04:
**keep them.** Seven have never taken an order, but Switzerland is the best
delivery record in the app's history (5 codes / 14 orders) and dropping the set
would remove nine countries from a 100%-search-driven catalog.

**There is no fallback between providers**: `providerOrder()` returns exactly
one, so a stockout fails as a stockout rather than silently re-reserving
elsewhere under a different price and delivery profile.

`providerOrder()` in `_shared/providers.ts` is the single source of truth for SMS
routing; order/poll functions call the router, never a provider. It resolves
**`routes.provider` (ownership) FIRST**, and only falls back to code-presence
when no owner is recorded — a route can now carry codes for two providers at
once, and the one that PRICED it must be the one that BUYS it.

The provider has now changed four times, and every switch broke something that
threw no error, because **`routes` is ONE row per (service_id, country_id) with
`provider` as a column** — re-homing rows strands any combo the new provider
can't serve. If you switch again, re-read the "provider switch checklist" below.

*History, kept because it is the evidence base:* SMSPool served 43 SMS orders in
3 days and delivered 3 (5%, vs SMSPVA 43% on the same catalog); the decisive test
was leboncoin/NL — 8 of 13 on SMSPVA — going 0 of 1 on SMSPool with every
mechanism working. SMSPool keeps eSIMs, where it is 9 of 9.

Bundle ID: `com.anthersystems.VirtualSIM` · Supabase ref: `enugzltysdmjzavisloy` · Project root holds `Appidea.md` (original product brief).

## Common commands

```bash
# ⛔ `swiftc -typecheck` IS RETIRED as of 2026-08-06 — do NOT use it, and do
# not "fix" it. Adding the `TelnyxRTC` SwiftPM package retired it exactly as
# planned: swiftc cannot resolve a package graph, so it now fails with
# `no such module 'TelnyxRTC'` on TelnyxVoiceClient.swift and reports NOTHING
# about the other 115 sources. Verified failing 2026-08-06.
#
# **`xcodebuild` is now the ONLY check.** It was already the better one — a
# missing `import StoreKit` type-checked fine and failed the real build.

# iOS build (verify compilation; no simulator launch)
# NOTE: this FAILS on this machine until the iOS platform is installed —
# "iOS 26.5 is not installed" (see the destination gotcha below).
xcodebuild -project VirtualSIM.xcodeproj -scheme VirtualSIM \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' build 2>&1 \
  | grep -E "(error:|warning: |BUILD)" | grep -v "Metadata extraction" | tail -10

# Push DB migrations to the linked Supabase project
supabase db push

# Deploy edge functions (each runs independently)
supabase functions deploy create-order check-order cancel-order register-push iap-verify delete-account \
  create-esim-order check-esim-usage redeem-referral \
  create-email-order check-email-order email-domains support-send \
  search-line-numbers reserve-line-number verify-line-subscription rent-line-credits \
  send-line-message line-thread-action mint-line-token begin-line-call report-line-call \
  record-attribution verify-email-subscription swap-line-number
# Cron-gated functions MUST ship --no-verify-jwt: their pg_cron relays send
# only x-cron-secret, no Authorization header. winback lived in the JWT group
# until 2026-07-21 and silently 401'd on every daily run — zero nudges ever
# sent, invisible because pg_net purges response history within hours.
supabase functions deploy poll-active-orders sync-prices sync-5sim sync-herosms \
  sync-esim-plans sync-smspva-operators sync-smspva-conversions winback \
  telegram-notify telegram-webhook daily-credit telegram-setup goodwill-credit \
  broadcast-push telnyx-webhook apple-notifications release-lines sync-telnyx-cdr \
  sync-line-voice probe-telnyx-connection sync-line-countries \
  --no-verify-jwt
# ✅ The two lists above are now EXHAUSTIVE, and `supabase/config.toml` carries
# a `[functions.<name>] verify_jwt = false` entry for every member of the second
# group — the flag used to live only in shell history, and a redeploy that
# forgets it 401s every caller silently. Assert with `ls supabase/functions |
# grep -v _shared | wc -l` against the two lists; they must sum to it.
# daily-credit: the cron relay-daily-credit is UNSCHEDULED as of 2026-08-02 and
# the grant itself is disabled behind app_config.daily_credit_enabled. The
# function is still deployed (harmless, returns 0 candidates); keep it in this
# --no-verify-jwt group if it is ever re-enabled.
# sync-5sim (cron relay-sync-5sim, 7 * * * *) is the PRIMARY pricing sync: it
# prices 5sim routes, picks the pool each route buys from, and writes the
# published rate the picker renders. See "Why sync-5sim exists" below.
# sync-herosms (cron relay-sync-herosms, 37 * * * *) still runs — HeroSMS still
# owns 560 active SMS routes AND the e-mail line's balance.
# DELETED 2026-07-30: sync-virtualsms/, sync-smspool/, smspool-catalog/ — all
# three are gone from disk AND undeployed.
# ✅ Re-asserted 2026-08-18: the two lists are exhaustive — 23 + 20 = **43** (probe-telnyx-connection added the same day),
# against `ls supabase/functions | grep -v _shared | wc -l`. record-attribution
# (Apple Search Ads) joined the JWT group that day.
# ⚠️ Re-asserted 2026-08-19, and it is NOT exhaustive right now: the two lists
# are 24 + 20 = **44** (verify-email-subscription — the mail-subscription
# entitlement grant, JWT-verified, no config.toml entry — added this day) but
# `ls supabase/functions | grep -v _shared | wc -l` reads **45**. The gap is
# `probe-5sim`, a one-off diagnostic (see "Two 5sim behaviours settled by PAID
# PROBE" above — "do not re-run") that was never added to either list and is
# not meant to be redeployed on a normal cadence. Re-assert the sum before
# trusting either number; do not assume this note stays current.
# ✅ Re-asserted 2026-08-27: 25 + 21 = **46** (sync-line-countries — the line
# country catalog sync — joined the --no-verify-jwt group this day, with its
# config.toml entry) against `ls … | wc -l` = **47**; the gap is still
# `probe-5sim`. Re-run the count rather than trusting this line.
# ✅ As of 2026-08-06 the two lists ARE exhaustive — 21 + 18 = **39**, asserted
# against `ls supabase/functions | grep -v _shared | wc -l`. They were not
# before: this comment claimed 19, then 25, then 26 while two functions
# (`telegram-setup`, `goodwill-credit`) appeared in NEITHER list, and by 08-06
# twelve did. RE-ASSERT the sum rather than trusting this line — a function in
# no list is a function nobody redeploys after a `_shared` change, which is
# exactly how a stale bundle survives a fix.
# ⚠️ `telegram-setup` still fails closed, and rotating TELEGRAM_WEBHOOK_SECRET
# requires re-running it.
# ⚠️ `_shared/*` is bundled PER FUNCTION at deploy time. After touching
# _shared/fivesim.ts, redeploy sync-5sim AND poll-active-orders AND every
# consumer of providers.ts (create-order, check-order, cancel-order,
# delete-account) — a stale bundle keeps the OLD copy with no signal anywhere.

# Query the remote DB
supabase db query --linked "select count(*) from public.routes;"

# Trigger any cron-gated function WITHOUT handling the secret yourself. pg_net
# calls it server-side and private_cron_secret() never leaves the database.
# Live pg_cron schedule (20 jobs, all active — re-verified 2026-08-06):
#   relay-poll-active-orders  * * * * *     relay-telegram-notify  * * * * *
#   watchdog                  */10 * * * *  relay-sync-prices      17 * * * *
#   relay-sync-5sim            7 * * * *    (PRIMARY pricing sync, ~71s/run)
#   relay-sync-herosms        37 * * * *    (offset from sync-prices on purpose)
#   relay-sync-smspva-conversions 49 * * * *  relay-sync-esim-plans 0 2 * * *
#   relay-sync-smspva-operators 30,32,34,36,38,40 4 * * *  (6 chunked slots)
#   relay-winback             0 15 * * *    (relay-daily-credit: REMOVED 08-02)
#   expire-esim-orders        */15 * * * *  expire-email-orders    */5 * * * *
#   relay-smspva-operators-maint-up 29 4  / -down 43 4  (maintenance screen)
#   purge-job-run-details 7 3 * * *       telegram-events-prune 30 4 * * *
#   ── rented lines, added 2026-08-06 (see "the cancellation leak") ──
#   reclaim-lapsed-lines      */15 * * * *  (PURE SQL, no HTTP hop — the claim
#                                            must survive the edge layer dying)
#   relay-release-lines       3,18,33,48 * * * *  (the provider DELETE)
#   relay-sync-telnyx-cdr     */10 * * * *  (settles call minutes)
#   relay-sync-line-countries 40 3 * * *    (line country catalog: coverage +
#                                            ordering requirements + samples)
#   settle-stale-line-calls   23 * * * *    (PURE SQL; the 6h no-CDR backstop)
supabase db query --linked "
  select net.http_post(
    url := 'https://enugzltysdmjzavisloy.supabase.co/functions/v1/sync-prices',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'x-cron-secret', private_cron_secret()),
    body := '{}'::jsonb, timeout_milliseconds := 180000);"
```

There is no test suite. Verify iOS with **`xcodebuild`** — `swiftc -typecheck`
was retired on 2026-08-06 when the `TelnyxRTC` package landed (see above). The
project now has **three** SwiftPM dependencies (TelnyxRTC 4.1.2, WebRTC 139.0.0,
Starscream 4.0.8) and **116** Swift sources — re-count before trusting either;
this said 96 for three days after the Number tab landed.

⚠️ **A green build does NOT cover the two things calling can get wrong.** Both
are runtime-only and silent: the `UIBackgroundModes` Info.plist key (see the
gotcha below) and whether a real call actually carries audio. Assert the first
with `plutil`, and the second only on a physical device.

Verify backend changes by re-deploying, then
**checking the resulting DB state** — not by assuming the deploy worked. Several
bugs this session looked identical to success until a row was queried: an
SMSPVA balance read that silently wrote nothing, and maintenance jobs that ran
against a retired provider.

If the CLI errors with `too many authentication failures ... (ECIRCUITBREAKER)`,
`supabase db query --linked` mints a temp login role per call and parallel
agents exhaust it. Use the Supabase MCP `execute_sql`/`apply_migration` tools
instead — different auth path, unaffected.

## Architecture

The ASCII system diagram that lived here was **deleted 2026-08-06**: every part
of it was derivable (`ls supabase/functions`, the migrations, the tab enum) and
all of it had gone stale — it showed *four* tabs when there are five, listed
none of the eight rented-line functions, and asserted "Ownership per SERVICE"
which this file's own header contradicts. A diagram nobody regenerates is worse
than no diagram, because it is read as current. Derive the shape from the code;
what follows is the part the code cannot tell you.

**iOS minimum is 18.0**, lowered from 26.2 in `a9b92c0` (shipped as 1.5 build 16)
— the 26.2 floor excluded almost every device in the install base. Anything
guarded by an `if #available(iOS 26, *)` must keep a working 18.0 path.

### iOS client details — moved to `.claude/rules/ios-client.md`

Source layout, the palette and Liquid Glass rules, cold launch, the map's
per-frame camera trap, the localization `Text("literal")` rule, the eSIM
store's Pareto filter, the service picker, the order-state reconcile
invariant and the p90 quoting rule now live in
`@.claude/rules/ios-client.md`, which loads automatically when working
under `VirtualSIM/`. ~6.7k tokens.

### Backend layout

- `supabase/migrations/` — chronological SQL, each phase ships its own file
- `supabase/functions/_shared/` — `providers.ts` (unified router; per-SERVICE ownership across 5sim/SMSPVA/HeroSMS with NO cross-provider fallback — order/poll functions call this, NOT a specific provider), `fivesim.ts` (5sim REST wrapper — the PRIMARY SMS adapter), `herosms.ts` (SMS-Activate `handler_api` wrapper), `heromail.ts` (HeroSMS `/api/v1`, the temp-EMAIL line), `emailStatus.ts`, `smspva.ts` (v2 REST wrapper), `smspool.ts` (eSIM + balance ONLY — the SMS surface was deleted 2026-07-30), `apns.ts` (HTTP/2 + JWT), `cors.ts`, `iap.ts` (Apple receipt chain verification), `telegram.ts`, `opsFormat.ts`, `supabaseAdmin.ts`, `telnyx.ts` (the rented-line adapter: Ed25519 webhook verification, numbers, messaging, voice credentials and detail records), `lineCatalog.ts` (the fail-closed sellability gate every line seller calls — see "Line country catalog" below). This list is INCOMPLETE and has been for weeks (`ls supabase/functions/_shared | wc -l` read **24** on 2026-08-27) — count, don't trust it.
- `supabase/functions/<name>/index.ts` — one per endpoint, all Deno.serve
- `supabase/README.md` — deployment + secret setup walkthrough

**Key SQL functions** (all `SECURITY DEFINER`, all revoked from `anon`/`authenticated` — clients reach them only through edge functions on the service role):
- `begin_order(user, service, country, credits)` — dedupe + insert order + charge, in ONE transaction under `pg_advisory_xact_lock(user)`. See the gotcha below; do not go back to charging before the row exists.
- `wallet_spend` / `wallet_credit` — atomic single-statement balance moves. Always pass `p_order` so the ledger reconciles.
- `credit_iap_purchase(user, receipt, amount, transaction_id, original_transaction_id)` — **the only way to credit an Apple purchase.** Tombstones `transaction_id` in `iap_grants` and credits in ONE transaction under an advisory lock, returning `granted` / `already_granted` / `invalid_amount`. Idempotent, so a caller that is unsure whether a previous attempt landed simply calls it again — that is both the duplicate check and the recovery. Never call `wallet_credit` directly for an IAP; it has no replay guard.
- `active_sms_provider()` — returns whichever provider owns the most `active` routes. Maintenance functions default to it so a provider switch can't silently orphan them again. **As of 2026-08-03 it returns `5sim`, which is CORRECT — but only by luck, and it is still the wrong metric.** 5sim owns 4,493 active routes against SMSPVA's 928 and HeroSMS's 560, so the vote lands right; it landed *wrong* for the whole of the HeroSMS era (SMSPVA 7,757 vs HeroSMS 5,198), silently pointing every evidence refresh at a retired provider. A vote by route count is not a statement about who serves demand. Do not wire anything new to it, and re-assert it after any catalog change. **This file claimed on 2026-07-30 that it was "no longer load-bearing". That was FALSE, and the audit on 2026-07-31 found two live consumers it had missed** — `refresh_evidence_all_providers()` fixed only the three refreshes it wraps:
  - **`refresh_arrival_timing`** is a SEPARATE entry in `sync-prices`' maintenance list, outside the wrapper. It measured SMSPVA only (38 of 46 arrivals) and stamped that band onto all 268 services, so every "most codes arrive within N" quote in the app described the retired provider. Fixed in `20260731070000`/`20260731080000`.
  - **`recent_sms_delivery_rate()`** still scopes to the vote, returned NULL on a 4-order SMSPVA sample, and through it `stranded_credit_candidates` was permanently empty. Fixed by deleting that cohort's gate; **the rate function itself still uses the vote and is still wrong** — it is only no longer load-bearing because nothing gates on it now. If you add a consumer, scope it per-provider.

  Before assuming a consumer is safe, grep for it: `select proname from pg_proc where prosrc like '%active_sms_provider%'`. Do not wire anything new to it.
- `refresh_evidence_all_providers()` — **the only evidence entry point `sync-prices` calls.** Runs the route + service refreshes once per provider that owns active routes, then country evidence once. See "Evidence must describe the provider that serves the NEXT order" below.
- `refresh_route_observed_success` / `refresh_service_delivery` / `refresh_country_delivery` / `sync_service_visibility` / `apply_measured_service_ranking` — catalog self-correction. The first three are now called **through the wrapper**, not directly.
- `ops_snapshot(interval)` — one JSONB blob powering both the Telegram digest and `/stats`.

### Provider APIs — moved to `.claude/rules/providers.md`

5sim, HeroSMS and Telnyx API behaviour, the two pricing syncs, and the
sellable-number catalogue now live in `@.claude/rules/providers.md`, which
loads automatically when working under `supabase/functions/`. ~10k tokens
that only matter while editing an adapter.

### Retention — the numbers that decide what's worth building

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
shipped builds decode), and coldStart is 5 steps, not 6. The no-op DB
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

### Telegram ops bot

`telegram-notify` (cron, every minute) sweeps new signups / credit purchases /
eSIM purchases / line rentals, pages the watchdog verdict, emits a 6-hourly
digest and a 09:00-Paris morning brief; `telegram-webhook` answers 21 commands
(see "Overhaul 2026-08-21" just below). Exactly-once is a claim row in `telegram_events`
(`kind`,`ref` PK) written *before* sending, so the instant path in `iap-verify`
and the sweep can never double-send. Secrets: `TELEGRAM_BOT_TOKEN`,
`TELEGRAM_CHAT_ID`, `TELEGRAM_WEBHOOK_SECRET`. The webhook is public and gated
twice — matching `X-Telegram-Bot-Api-Secret-Token` **and** owner chat id — and
returns a silent 200 on every rejection so it isn't an oracle.

#### Overhaul 2026-08-21 — registry, Paris time, autocomplete, new screens

**Commands are a REGISTRY, not an if/else.** `_shared/tgCommands.ts` is the
single source of truth: it generates `/help` AND the Telegram `/` popup menu
(`setMyCommands`, plus the ≡ button via `setChatMenuButton`). `_shared/
tgHandlers.ts` holds the handlers and a pure `runCommand(text)`; `telegram-
webhook/index.ts` is transport only (auth, support routing, send). **Adding a
command = one entry in the registry + one handler; then RE-RUN `telegram-setup`
or the popup menu keeps the old list** — the menu is bot-level state held on
Telegram's side, exactly like the webhook URL.

The set: `/now` (one screen: balances + runway, watchdog, paused flags, today
since midnight Paris, lines + next conversion, support, active alerts),
`/today` `/week` `/stats`, `/trials` (every subscription by `expires_at`, Paris
time, auto-renew on/off, what will bill), `/failures [24h|7d]` (no-number and
no-code orders by route, e-mail/eSIM/call failures, blocked routes),
`/orders`, `/delivery`, `/route <service> [country]` (why something is
unavailable — status, price, pool rate, stock, 7d orders/codes), `/balance`,
`/revenue` `/profit`, `/subs`, `/lines` (no arg now LISTS live lines with usage
and real rent; `on|off` unchanged), `/support` (threads waiting, oldest first),
`/alerts` (what is firing + ladder/cooldown states), `/funnel`, `/config`
(read-only: grant, e-mail caps, pause switches, swap price), `/announce`,
`/esim`, `/help`.

**Every timestamp the bot prints is Europe/Paris**, through
`_shared/tgFormat.ts` (`parisFull`, `ago`, `until`, `duration`, `usd`,
`ratio`, `stamp`). Before this every command printed raw UTC ISO strings to an
owner in France. Every command reply ends with a `🕒 … Paris` stamp. Never
format a time any other way in bot code.

**House style, enforced by the formatter tests** (`.claude/tmp/fmt-test.ts`
while the worktree lives; re-create from the renderings if lost): line 1 is
the answer, caveats last in italics, percentages only when n ≥ 5 (`ratio()`
prints "3 of 4" below that), lists capped with "… and N more", never
`undefined`/`NaN`/raw ISO.

**Six new RPCs** (`20260821120000_ops_bot_rpcs.sql`, all service-role only —
asserted `has_function_privilege('anon', …)` = 0 rows): `ops_now()`,
`ops_trials()`, `ops_failures(p_window)`, `ops_support()`, `ops_lines()`,
`ops_route(p_service, p_country)`. Three facts they encode that the code
cannot tell you:
- **`orders` has NO close-reason column.** A numberless order is
  `status='canceled'`, `actual_cost_cents is null`, and that is all — stockout,
  `margin_too_low` and provider fault are indistinguishable at row level. So
  `/failures` says "got no number", never why; the function logs hold the why.
- 🔴 **`orders.provider` DEFAULTS TO `'smspva'` AND IS ONLY OVERWRITTEN WHEN A
  NUMBER IS RESERVED** (`create-order` stamps `provider: used` after a
  successful reservation). So every numberless order — today's entire
  `/failures` "no number" cohort — reads `smspva` whatever provider actually
  refused it, and a grouped-by-provider view would "prove" a retired provider
  is taking orders. Found 2026-08-21 when `/failures` said telegram/co was
  smspva while `/route` said 5sim: the route was 5sim, the orders had never
  been stamped. `ops_failures` and the `route_fill` alert take the provider
  from `routes`, never from a numberless order row. If you ever need the
  truth per order, it is in the function logs, not the column.
- **A trial is `price_milli = 0` on a `.yearly` product in state active/grace.**
  There is no offer-type column; a yearly is the only kind of product with a
  trial, so this heuristic is exact today and wrong the day a $0 promo ships on
  a monthly. `/trials`, `trial_soon` and `trial_off` all share it.
  **`mail.yearly` carries a 3-day trial again (REINSTATED 2026-08-27, owner
  decision); the LINE products carry none.** History: both trials were
  removed by 2026-08-25 because every billing attempt across them failed
  (6/6 line, 1/1 mail, all `DID_FAIL_TO_RENEW` with auto-renew still on).
  The mail one was brought back two days later — the mail sample was n=1
  and $29.99 is a softer conversion than the line's $99.99 — and this time
  it covers **all 175 priced territories** (the 2026-08-19 original was
  base-territory only). Created and read back by
  `scripts/asc-mail-yearly-trial.py` (dry-run by default; idempotent).
  Verified: line 6798759539 offers = empty; mail 6803258736 offers = 175.
  So a `price_milli = 0` row on `mail.yearly` is a real trial; on any LINE
  product it means an offer came back or something is wrong. The paywalls
  need no release — trial copy reads the live intro offer and appears or
  disappears on its own.
- **"Today" is since midnight Paris**, not UTC — `ops_now` does
  `date_trunc('day', now() at time zone 'Europe/Paris') at time zone 'Europe/Paris'`.
- **Every count a formatter prints must be computed in SQL, not over the rows
  it was handed.** `ops_route` caps its `routes` array at 25, so `routes_active`
  (active AND, where the provider publishes a stock figure, non-zero) and
  `routes_total` are BOTH returned; counting the array made the headline an
  artifact of the LIMIT — telegram read "25 of 69 bookable" against 54.
- **The watchdog's "last ran" is `value->>'checked_at'`, NEVER the row's
  `updated_at`.** `telegram-notify` writes `alerted`/`last_alert_at` back onto
  the same `app_config` row on every page, which fires `app_config_touch` — so
  `updated_at` moves without `run_watchdog` having run, and a dead watchdog plus
  one 6-hourly re-page reads as "ran just now". `/now`, `/balance`, `/alerts`
  and `telegram-notify` all treat a verdict older than **30 minutes** as
  `watchdog_stale`, and in `/now` that is the HEADLINE — `/now` is also the
  morning brief, i.e. the one message read daily.

**`telegram-setup` gained a cron-gated preview:** POST `{"preview":"/trials"}`
(same `x-cron-secret` gate, trigger via `net.http_post` + `private_cron_secret()`)
returns the rendered HTML WITHOUT sending it — this is how every command is
verified without the owner's phone. Commands whose registry entry carries
`mutates` (`/announce`, `/esim`, `/lines`) are REFUSED in preview with
`preview_refused_mutating` — without that, the cron secret alone could post a
banner to every user, where from the chat it takes the bot token AND the owner
chat id. `/lines` with no argument is read-only and is refused anyway; the
simplicity is worth more than that one preview.

**Alerts share one shape** — `_shared/tgAlert.ts` `alertHtml({sev, title,
what, why, action, at})`: 🔴 money leaking / product down, 🟠 becomes 🔴
without action, 🟡 degraded, 🟢 recovered or good news, ℹ️ business event. The
watchdog page groups checks into Money / Delivery / Lines / Jobs with a plain-
English line and an action per check (`WATCHDOG_COPY`, one entry per check name
— an unknown check falls back to Jobs + raw detail, so adding a watchdog check
without a copy entry degrades, it does not break). Down-time per check lives in
a NEW key **`app_config.watchdog_since`**, because `run_watchdog()` rebuilds the
`watchdog` row every 10 minutes and drops anything extra written there.

**New alert kinds** (constraint `telegram_events_kind_check` widened in
`20260821130000_ops_bot_alerts.sql`, every pre-existing value repeated):
`trial_soon` (🟠 converts within 24h, ref = original tx), `trial_off` (ℹ️ once
when auto-renew flips off), `route_fill` (🟠 ≥3 no-number orders on one
(service,country) in 60 min, ref = `service|country|UTC-hour` so at most
hourly), `line_consumption` (split from `line_refund` — the two shared
`(kind, originalTx)` and whichever Apple sent first silently ate the other; refs
now carry the notification UUID). Without a kind: `support_waiting` (🟠 a
thread with `last_sender='user'` unanswered > 2h, re-nag every 6h via
`app_config.support_nag`) and the **morning brief** (☀️ `/now` rendering, first
run at/after 09:00 Paris, once per Paris day via `telegram_bot.last_brief_on`
— the `telegram_bot` write now MERGES so it cannot drop `last_digest_at`).

**New service-role-only `app_config` keys — never add them to the RLS
whitelist:** `watchdog_since`, `support_nag`, `esim_alert_low_balance`,
`esim_alert_purchase_failed`, `esim_alert_persist_failed` (the eSIM purchase
alerts were the last unthrottled pagers; now 6h cooldown, stamped only after a
confirmed send, same shape as `alertLowBalanceBlock`).

**`{provider}-float` no longer disarms on zero burn.** `watchdog_money_checks`
used to `continue` when 7-day burn ≤ 0 — the exact state of a dead route. Now
burn = 0 with ≥ 1 numbered order in the prior 7–14 days pages "no spend in 7
days against N orders the week before — route may be dead"; burn = 0 with no
prior orders stays silent. Regenerated from `pg_get_functiondef` and diffed:
exactly one hunk.

**`_shared/telegram.ts` SPLITS instead of truncating** (`splitForTelegram`, cut
at the last newline under 4000 chars, `(i/n)` suffixes, `ok` only if every part
landed). ⚠️ It is bundled per function: **every function that sends to
Telegram must be redeployed** or it keeps the old silent truncation. The two
deploy lists at the top of this file are the redeploy set.

🔴 **A part must be well-formed HTML ON ITS OWN, and the hard-cut path is where
that is easy to lose.** A single line over the budget has no newline to cut at,
so it is cut mid-string: the cut is backed up to before an unclosed `<` (never
through a tag), and any `<b>/<i>/<code>/<pre>` still open at the end of a part
is closed there and REOPENED at the start of the next. Without both, Telegram
answers `400 can't parse entities`, `sendMessage` fails on the FIRST part, and
`claimAndSend` releases the claim — so the same doomed message is rebuilt and
re-fails every minute, forever. `<a>` is deliberately not repaired: reopening
it would have to invent an `href`, which Telegram rejects outright. Covered by
`.claude/tmp/alert-test.ts`.

**`/revenue [24h|7d|30d|90d|all]`** (default `all`) answers exactly one question —
**how much money customers actually paid, in USD** — and derives nothing else.
**`/profit`** is the separate command that nets off Apple's cut and wholesale.
Both read `revenue_snapshot(interval)`; the split is in the formatter
(`formatGross` vs `formatRevenue` in `_shared/opsFormat.ts`). Keep them apart:
`/revenue` answering with a P&L was the thing that made the number hard to trust
at a glance, because a single figure was silently three assumptions deep.

**It does NOT use a hardcoded price table, and must not be "simplified" into
one.** `iap_receipts` stores no price, so the obvious implementation is a
product→USD map next to `PRODUCT_TO_CREDITS`. That is wrong: the store charges
by **storefront**, and ours is not one price — `credits.12` bills **$4.99 in the
USA but €5.99 in France**, `credits.30` **$11.99 vs €12.99**. Sales so far span
USA/FRA/ESP/SVK/BGR in two currencies, so a USD ladder would overstate US
revenue ~17% and misprice every EUR sale. Instead `jws_payload()` base64url-
decodes the Apple JWS we already persist in `raw_jws`, which carries signed
`price` (**milliunits** — 4990 = 4.99), `currency` and `storefront`. It is the
amount actually billed and it self-corrects when ASC prices change.

Three deliberate honesty properties, all load-bearing:
- **Mixed currencies are never silently totalled.** The function returns
  per-currency subtotals; the formatter converts with a hand-set `FX_TO_USD`,
  **prints the rate**, and lists any currency missing from the map as
  unconverted rather than folding it in at 1.0.
- **`APPLE_COMMISSION = 0.15`** assumes the Small Business Program. If vSMS is
  not enrolled it is 0.30 — worth ~$24 of the profit line. The rate is printed
  next to the figure so it can't be read without its assumption.
- **Profit is flagged an upper bound** whenever orders held a number but have no
  `actual_cost_cents` (48 of them, all before 2026-07-13 when cost recording
  started). Orders that never got a number are correctly excluded — nothing was
  reserved, so nothing was paid.

`environment = 'Production'` is filtered and the dev account is excluded from
revenue but its **provider spend is subtracted on its own line** ($4.01 lifetime)
— real cash out, not a cost of serving customers. Note `ops_snapshot`'s `buys`
does **not** filter environment, so the digest counts the one Sandbox receipt
(12 credits, $0 paid) as a purchase; `revenue_snapshot` does not repeat that.

**`/orders [24h|7d|30d|90d|all]`** (default **24h**, not lifetime — it prints one
line per order) answers "what happened to each order", which `/stats` cannot:
route, provider, tier, credits charged, wholesale actually paid, and **how long
the number was held**. Backed by `orders_recent(interval)`; rendered by
`formatOrders` in `_shared/opsFormat.ts`.

Four details that are load-bearing:
- **The dev account is INCLUDED and flagged `dev`**, unlike every analytics
  surface, which excludes it. This is an operational view — "did my test order
  work" is precisely the question, and hiding it would look like the order
  vanished.
- **Outcome reads `otp is not null`, never `status = 'received'`.** A rescued
  code lives on a `canceled` row, so status would report a delivered code as a
  failure — the same rule as every other consumer of order outcomes.
- **`held_s` is on every line** because it is the most diagnostic number here:
  seeing `✖ … 8s` beside `✅ … 58s` makes cancel-before-arrival legible at a
  glance. It is what exposed one user firing 13 google orders at Kenya and
  Indonesia in seven minutes, every one cancelled inside 73 seconds.
- **Orders that never held a number get their own count**, not a place in the
  delivery rate — they died inside `create-order` (stockout, `margin_too_low`)
  and never reserved anything. ⚠️ **The rate is over `settled`, NOT `numbered`
  — corrected 2026-08-08** (see the three commands below).
- Rows are capped at 35 with an explicit *"… and N older, not shown"*. A
  silently truncated list reads as "that was everything".

### `/funnel`, `/delivery`, `/subs`, `/help` (2026-08-08)

Three read-only snapshot functions — `ops_funnel(interval)`,
`ops_delivery(interval)`, `ops_subs()` — plus formatters in `_shared/opsFormat.ts`.
**`/funnel [7d|14d|30d]`** is per-day signups → orders → numbered → codes →
Production purchases, with **cohort** activation and buyer rates over the
signups in the window and the signup grant read live from
`app_config.signup_bonus_credits`. **`/delivery [24h|7d|30d]`** is per provider
with the watchdog verdict, the SMSPVA hidden-route count and one balance line
per provider. **`/subs`** is subscriptions by state against lines by status, and
it *warns when the two disagree* — a live line with no subscription is rent we
pay for nothing. `/help` lists everything and the unknown-command fallback now
points at it rather than dumping the whole list.

⚠️ **The same commit fixed three measurement defects in `ops_snapshot` /
`orders_recent`, and all three made the bot flatter revenue or delivery:**
`buys` did not filter `environment = 'Production'` (a $0 Sandbox receipt counted
as a sale), and both delivery rates ran over EVERY numbered order — so they were
mostly measuring **user impatience** (~60% of numbered orders are cancelled at a
median 57s and deliver ~1%) and our own **default-landed** pre-selection. The
cohort is now `status in ('received','expired') and not from_default`, identical
to `run_watchdog`'s, which is why `/delivery` and the watchdog now agree exactly
(11/44). Cancels, refusals, rescued codes and default-landed orders each get
their own line instead. Live effect on the 7d digest: **15% → 25%**.

### Announcement banner + `/announce`, `/esim` (2026-07-31)

A small owner-written banner on **Home**, posted from Telegram. Ships in 1.6.

```
/announce Your message          → live, info (accent)
/announce warn Your message     → live, amber
/announce off                   → clears it
/announce                       → shows what is currently live
/esim on | /esim off            → set_esim_paused() from the phone
/esim                           → reports which way it is set
/lines on | /lines off          → set_lines_paused() from the phone
/lines                          → reports which way it is set + live line count
```

⚠️ **`/lines` was added 2026-08-06 because `set_lines_paused` had NO CALLER
ANYWHERE.** The kill switch for the one product that bills monthly and costs us
rent per subscriber existed only as a function you had to open a SQL console to
reach — which is exactly the moment you cannot. It mirrors `/esim` including
reporting the live count, so "pausing did nothing" is visible rather than
looking like success.

**Pausing lines stops NEW rentals only**, and the reply says so: existing lines
keep sending, receiving and calling — and keep costing us rent until they lapse
through the normal suspend → hold → release path.

**`app_config` is RLS-restricted to an explicit key WHITELIST, and that is the
only safe way to widen it.** The table also holds `herosms_health` /
`smspva_health` (balances), `watchdog`, `blocked_routes` and sync cursors. The
policy is now:

```sql
app_config_read: SELECT to authenticated
  using (key = any (array['maintenance','announcement','esim_paused',
                          'lines_paused','line_swap_credits']))
```

⚠️ **FIVE keys as of 2026-08-21, not three** — `lines_paused` and
`line_swap_credits` were added later and this block claimed three for weeks.
Re-read the live policy (`select qual from pg_policies where
tablename='app_config'`) rather than quoting this list. Widening it by one
named key is the ONLY safe way to publish a value; `line_swap_credits` is
published because the swap confirmation dialog must quote a price the owner
can change without a release.

**Never** replace that with `using (true)` — it would publish the balances and
the watchdog verdict to anyone holding the publishable key. Verified after the
change: `anon` reads `herosms_health` → `[]`. `anon` has a table SELECT grant
but **no policy**, so it reads nothing; the app is past `AuthGate` and reads as
`authenticated`.

Three details that are load-bearing:

- **`/announce` reads the RAW message text, not the parsed one.** The webhook
  does `const text = raw.toLowerCase()` before dispatch, so building the
  announcement from `text` would deliver *"esims are back"* to every user.
- **Dismissal is keyed on the announcement's `id`, which changes on every
  post.** Storing a bare "dismissed" Bool would mean the next thing the owner
  writes is invisible to everyone who waved the previous one away — a broadcast
  channel that silently stops broadcasting to exactly the people who have used
  it before.
- **The text is never localized.** It is a human's words rendered verbatim;
  machine-translating it would put words in the owner's mouth. Only the chrome
  around it (dismiss label) is localized. It is also styled distinctly from the
  app's own measured statements — `kind` picks a colour and asserts nothing.

`MAX_ANNOUNCE = 280`, and over-length is **refused rather than truncated**:
truncating would let the owner send a message whose ending nobody reads.

**`telegram-webhook` MUST be deployed `--no-verify-jwt`** (Telegram sends no
Authorization header; `config.toml` now carries `verify_jwt = false` for it,
`telegram-notify` and `telegram-setup`, but the flag on the command line is
still the habit to keep). Deploying it without the flag 401s every update and kills the bot
silently. Assert with an unauthenticated POST: it must return **200** (the
function's own silent rejection), never 401.

### Pricing model

`AppState.cost(for:country:) -> Int?` uses an O(1) `routeIndex` dict (keyed `"serviceId|countryId"`) built in `loadCatalog`. Returns `nil` when the pair has no active route with a `retail_credits` price — meaning **unavailable to book**; UI shows "Unavailable" (see ServiceSheet/CountrySheet) and disables the Get-number button. It deliberately does **NOT** fall back to the seed `service.cost`, since undercharging vs the live provider price burns margin per order. **Do not** linear-scan `routes` (~17k rows after sync-prices) — that froze the country picker before the index was added.

`sync-prices` formula: `credits = max(1, ceil(price / 0.05))` — 1 credit per started 5¢ of wholesale (`CREDIT_DIVISOR = 0.05`, duplicated in **two** files — `sync-prices` and `sync-smspva-operators`, which prices the premium tier — while `sync-herosms` defines its own, deliberately DIFFERENT `0.025`; see the per-provider table below. "Tuning the divisor" is a per-provider decision now, and the 0.05 pair must move together). Order-time enforcement matches: `create-order` has `MIN_MARGIN = 6.0` / `NET_USD_PER_CREDIT = 0.30`, so the max we pay a provider is `credits × $0.05` **plus `CEILING_HEADROOM_USD` ($0.10)**, enforced on the actual charged cost with cancel-and-fallback. Keep the divisor and the margin pair in lockstep; raising one alone either blocks honest routes or leaks margin.

**The $0.10 headroom is load-bearing — do not "simplify" it away.** Without it the two formulas are exactly inverse (`credits*0.30/6.0 == credits*0.05`), so a route whose wholesale lands on an exact 5¢ boundary has an order-time cap equal to its cost **to the cent**. Measured 2026-07-27: **12,507 of 16,303 active routes (76.7%) sat at exactly zero headroom.** A one-cent rise at SMSPVA then made every order on that route fail `margin_too_low` — charged and instantly refunded — until the next hourly `sync-prices` repriced it. That produced **11 of 22 orders in 24h closing in under a second with no number**, and because those orders were also counted as delivery failures it auto-hid TikTok/Netherlands (see below). The headroom is flat, not proportional, so exposure is bounded at $0.10/order at any price point; the cost is margin on the cheapest routes (a 2-credit route may now pay up to $0.20 against $0.60 of revenue, 3× not 6×), which is strictly better than refunding the order. **SMS markup went 3× → 6× on 2026-07-25** (divisor 0.10 → 0.05); retail is recomputed from `smoothed_cost_cents` every run, so the whole catalog reprices on the next `sync-prices`.

**⚠️ THE ORDER-TIME CEILING IS NO LONGER THE DIVISOR — it is 3× it, plus the
flat headroom, capped at half of revenue (owner decision, 2026-08-02: "be a bit
lenient on the margin, all orders should succeed").**

```ts
expectedCostUsd = credits * NET_USD_PER_CREDIT / minMargin      // = the divisor
maxCostUsd = min( expectedCostUsd * CEILING_SLACK_MULTIPLE + CEILING_HEADROOM_USD,
                  credits * NET_USD_PER_CREDIT * MAX_REVENUE_FRACTION )
// CEILING_SLACK_MULTIPLE = 3.0 ; MAX_REVENUE_FRACTION = 0.5
```

**The lockstep rule still holds and is unchanged** — `expectedCostUsd` must
equal the divisor the route was priced with, exactly. The multiple sits on top
of it. `MAX_REVENUE_FRACTION` is the INVARIANT (no order can ever be sold at a
loss, whatever the multiple is set to or a future divisor change does);
`CEILING_SLACK_MULTIPLE` is the POLICY.

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

**Changing `CREDIT_DIVISOR` silently breaks the PREMIUM tier until you backfill
`routes.premium_credits`.** This bit us on the 3× → 6× change (2026-07-25).
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

**Changing `CREDIT_DIVISOR` also silently devalues every FIXED credit grant.**
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

**The divisor is PER PROVIDER, and since 2026-08-05 `MIN_MARGIN` finally MEANS
the margin we earn.** Each provider's sync sets its own `retail_credits`.

| provider | priced by | divisor | `MIN_MARGIN` | `0.40 / MARGIN` | `MAX_WHOLESALE_CENTS` |
|---|---|---|---|---|---|
| **5sim** | `sync-5sim` | **0.04** | **10.0** | 0.04 ✓ | 100_000 |
| herosms | `sync-herosms` | 0.025 | 16.0 | 0.025 ✓ | 100_000 |
| smspva | `sync-prices` | 0.05 | 8.0 | 0.05 ✓ | 100_000 |

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

`MIN_MARGIN_FALLBACK` is **16.0** — the strictest, never the loosest. Strictest
means the LARGEST margin, i.e. the smallest divisor (HeroSMS's 0.025), so an
unknown provider under-spends rather than overpaying on a route nobody priced.
All four `MAX_WHOLESALE_CENTS` are **100_000** since the 2026-08-04 ceiling
removal, i.e. non-binding — they are no longer `150 credits × divisor` and do
not need to move when a divisor does. **There are FIVE copies of a divisor and
FOUR of `MAX_WHOLESALE_CENTS` across four sync functions** — the divisors are
deliberately different values, so "consolidating them into `_shared/`" would
silently reprice a whole provider. Change them in one commit, never one at a
time, and assert the lockstep mechanically rather than by eye: it fails silently
as `margin_too_low` on every honestly-priced route.

`create-order` resolves it via `marginFor(route.provider)`
(`MIN_MARGIN_BY_PROVIDER`), falling back to the **strictest** value so an
unknown provider under-spends rather than overpaying on a route nobody priced.
The lockstep rule is unchanged and absolute: the order-time ceiling
`credits × NET / MIN_MARGIN` must equal the divisor the route was priced with,
exactly.

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

### Temporary EMAIL addresses — the third product line (2026-07-30)

Temp mailboxes on TWO real consumer domains, from HeroSMS — **outlook.com and
hotmail.com, both FREE**. There is no paid tier on sale as of 2026-08-26.

**gmail.com was REMOVED 2026-08-26 (owner decision)** — its HeroSMS pool
stopped delivering ~2026-08-10: 1 code in its last 36 orders, 0 of the last 23,
while the free pair delivered normally in the same window (outlook 53%, hotmail
57%), so it was the pool, not the users. It was the only paid tier (1 credit at
7.5× margin) and every failure charge-and-refunded, so users paid, failed and
retried. Re-add the key only when the `email-domain-gmail.com` watchdog
evidence says the pool delivers again. (2.3's `MailPaywallScreen` copy still
named gmail's 1-credit price — purged from the repo 2026-08-27 along with the
`free_limit_reached` "pick Gmail" advice in `APIError`; shipped builds up to
2.4 still show the old copy until 2.5.)

**icloud.com was REMOVED 2026-07-31 (owner decision)** — handing out throwaway
addresses on Apple's own consumer domain, from an app distributed on Apple's
store, is an avoidable review risk for a tier that earned nothing. It had **zero
orders ever**, so nothing was stranded. Both removals are enforced the same
way: deleting the key from `PRICING` — `create-email-order` rejects any domain
absent from that map with `domain_unavailable`, so no separate blocklist
exists. **`PRICING` is duplicated in `create-email-order` and `email-domains` —
change both together** (this file's own standing warning about duplicated
constants).

**Render order is FREE first**, reversing the original "paid first" rule. That
rule existed because the free pair is the scarcest inventory and leading with it
risks a picker whose top row reads "Out of stock" — but the client defaults to
`first(where: { $0.inStock })`, so an empty outlook.com already falls through to
hotmail.com. (Since the 2026-08-26 gmail removal both remaining domains are
free, so "free first" is vacuously true; the rule matters again the day a paid
tier returns.) E-mail exists to **acquire users, not to earn** — the mail
subscription, not a per-address price, is its monetization.

**It is a SECOND protocol on the same HeroSMS account**, sharing only the key and
the balance — see `_shared/heromail.ts`:

| | SMS (`herosms.ts`) | EMAIL (`heromail.ts`) |
|---|---|---|
| base | `/stubs/handler_api.php` | `/api/v1` |
| shape | query params + actions | REST resources |
| auth | `?api_key=` | **`Authorization: ApiKey <key>`** |
| errors | bare text (`BAD_KEY`) | `{"title","details"[,"errors"]}` |

**The auth scheme costs an hour if you guess.** It is not Bearer, not
`X-Api-Key`, not the query param the SMS side uses. Every wrong scheme returns
`{"title":"Unauthenticated."}` — the SAME body an unknown route returns *after*
auth — so a wrong header reads exactly like "this API does not exist". It does
exist. (`/api/v1/activations` and `/api/v1/webhooks` genuinely DO reject the API
key: they are dashboard-session endpoints.)

Verified live with real purchases:
- `GET /emails/domains?site=<site>` → `{"data":[{name,cost,count}]}`. **`site` is
  REQUIRED** (422 without) and BOTH price and stock vary by it.
- `POST /emails {site,domain}` → 201, address usable immediately, `status: WAIT`.
- `GET /emails/{id}` → same shape. `DELETE /emails/{id}` → cancel.

**Three provider behaviours you cannot guess:**
1. **A hard 2-minute cancel floor.** `DELETE` inside 120s returns 400
   `EARLY_CANCEL_DENIED`. Provider-enforced; we cannot opt out, so a cancel
   affordance that is live before then is a guaranteed failure. Exported as
   `EMAIL_MIN_HOLD_SECONDS`.
2. **The window is ~20–21 minutes and it AUTO-REFUNDS.** Measured by holding one
   to its natural end: still `WAIT` at 20m22s, `CANCEL` at 21m22s, and the
   account balance returned to exactly its pre-purchase figure with no action
   from us. Our own `EMAIL_WINDOW_SECONDS` is **22 min**, deliberately LONGER, so
   their terminal state is what we normally observe and ours only fires when
   they are unreachable. Shorter would race a provider still holding a live
   mailbox, and closing early discards a code that was about to land.
3. **`CANCEL` is OVERLOADED.** The same value means a user-initiated DELETE *and*
   their own timeout, with nothing in the payload separating them. Only the
   caller knows which, so `mapProviderStatus` takes `weCancelled` and merely
   observing `CANCEL` means **expired**. Mapping it to "canceled" told users they
   cancelled an order that simply timed out.

**`email_orders.status` is OUR enum, never the vendor's.** Their vocabulary is
undocumented and undiscoverable — no OpenAPI at any conventional path, absent
from all 50 JS chunks of their docs SPA — and probing only ever produced `WAIT`
and `CANCEL`. The value meaning "a code arrived" has never been seen. Encoding a
guess is exactly what broke eSIM refunds. So `_shared/emailStatus.ts` maps
vendor → ours, logs loudly on anything new, and falls back to `waiting` (safe:
keeps polling). **`code is not null` is the authority for "a code arrived"**,
never `status = 'received'` — same rule as the SMS side's `otp is not null`,
which means we never needed their success status at all.

**`expire_email_orders()` (pg_cron `*/5`) sweeps the window, and two traps in it
would make a copied `expire_esim_orders()` look like a working deploy while
matching nothing:** `email_orders.expires_at` is a **DEAD COLUMN** — nothing has
ever written it, so keying on it matches zero rows (it keys on `created_at + 22
minutes` instead) — and the terminal status must be **cast** (`::email_status`),
because a CASE yields `text` and the UPDATE raises 42804 without it. Both were
hit for real. It promotes `code is not null` to `received` and never refunds
those, refunds only paid codeless rows, calls no provider (HeroSMS auto-refunds
us at ~21 min), and writes `app_config.email_expiry_heartbeat` for the watchdog.

**There is no catalog to sync.** `site` is required and stock is per (site,
domain) and genuinely runs dry — hotmail.com measured **1,028 available for
google.com and TWO for discord.com** in one sweep. `email-domains` quotes live at
checkout; `create-email-order` refuses when `count` is 0. Never cache it.

### Per-domain e-mail delivery IS monitored (2026-08-26)

🔴 **THE PAID gmail.com TIER DELIVERED NOTHING FROM ~2026-08-10 AND NOTHING
PAGED — which is why the tier was removed from sale on 2026-08-26** (see the
removal note above). Measured 2026-08-26 over the trailing 14 days: gmail.com
**30 orders / 0 codes**, against outlook.com **58 of 110** and hotmail.com
**16 of 28** in the same window. The free tiers delivering normally is what
made it the domain pool rather than the users or a HeroSMS outage.

Nothing watched this: `app_config.email_expiry_heartbeat` proves only that the
sweep is alive, and there had never been a delivery check on this line at all.
`email-domain-<domain>` (migration `20260826140000`, amended `20260826150000`,
in the companion `watchdog_delivery_checks()`) pages when a domain has **≥ 8
orders in 14 days with ZERO codes while at least one other domain delivered in
the same window, AND its most recent order is within 72 hours** — the last
condition (the `20260826150000` amendment) makes the check go quiet on its own
within three days of a domain being pulled from `PRICING`, instead of paging
6-hourly about a decision already taken until the old orders age out of the
window. Details that are load-bearing:
- **The cross-domain condition is the whole design.** Without it a total
  HeroSMS failure would page here three more times on top of the checks that
  already cover it, and alert fatigue on the one channel is how the next real
  outage gets missed.
- **`code is not null` is the authority**, never `status = 'received'` — the
  same rule as the SMS side's `otp is not null`. Verified 2026-08-26: the two
  predicates agree on every e-mail order in the window, so this is correctness
  insurance rather than a behavioural difference today.
- **One check name per domain** (`email-domain-gmail.com`), so each alerts and
  recovers on its own; its Telegram copy comes from the `email-domain-` prefix
  branch in `copyFor()` in `_shared/tgAlert.ts`, next to the `-float` one, and
  a fixed `WATCHDOG_COPY` key could never match it.
- Orders younger than **1 hour** are excluded: the provider window is ~21
  minutes, so a fresh order has not failed, it is waiting.

**The free tier is the SCARCEST inventory**, two to three orders of magnitude
below gmail/icloud. It is also the only thing with no credit gate, so
`begin_email_order` enforces **N free per user per UTC day**, live in
`app_config.email_free_daily_cap` — **currently 1, cut from 3 on 2026-08-17**
(see "Free e-mail cap" under Current state; re-query before quoting, this is
a lever the owner turns without a deploy) under the same advisory lock.
**This is the pre-2.2 rule only** — once
`email_subscription_enforced` flips true it is replaced entirely by the
lifetime-and-subscription rule in the "Temp-e-mail subscription" section
below. And `cost_credits >= 0` is deliberate: `wallet_spend` RAISES on a non-positive
amount, so the free path skips the spend entirely rather than calling it with 0.

`site` comes from `services.domain`, populated for **254 of 265** visible
services — the other 11 cannot offer email at all and are filtered out of the
picker rather than failing at checkout.

**First real activation delivered 2026-07-30**: leboncoin, free tier,
`status = received`.

### Temp-e-mail subscription (2026-08-19)

✅ **ENFORCED SINCE 2026-08-22 (owner decision).**
`app_config.email_subscription_enforced` is **true**, flipped by the owner
after 2.2 went `READY_FOR_SALE` and both mail products read `APPROVED` in
ASC. Verified behaviourally the same minute, inside a rolled-back
transaction: a user who had already used a free address got
`subscription_required` (`used 1 / grants 1`), a user with no e-mail history
got an order, and the gmail path was gated by credits only. Consequences to
keep in mind: the wall is RETROACTIVE — 41 of the 42 users who ordered
e-mail in the prior 7 days were walled at once; **2.1 and older builds
cannot render `subscription_required`** and show a generic error (the owner
declined a Home banner for them, so the 2.2 push is the only notice);
rollback is the same UPDATE with `'false'`, no deploy. Before the flip the
function applied the old per-UTC-day free rule (`email_free_daily_cap`),
which is now dead code behind the flag.

Two Apple products, in a **SECOND, SEPARATE subscription group from the line**.
**They EXIST in App Store Connect as of 2026-08-19** (`Products.storekit` still
carries the deliberately-fake `99999999` group id — that file is local test
config and its ids are placeholders on purpose, so do not "correct" them to
these):

| | id | price | trial |
|---|---|---|---|
| group | **22320947** "vSMS Mail" | — | — |
| `com.anthersystems.VirtualSIM.mail.monthly` | **6803258564** | $2.99/mo | none |
| `com.anthersystems.VirtualSIM.mail.yearly` | **6803258736** | $29.99/yr | **3 days — removed 2026-08-25, REINSTATED 2026-08-27 in all 175 territories** |

Both are available in the same **175 territories** the line sells in and priced
in all 175 (verified 2026-08-19: USA/FRA/DEU/GBR $2.99·€2.99·£2.99 monthly and
$29.99·€29.99·£29.99 yearly, JPY ¥500/¥5000), with en-US localizations and the
trial on yearly only. Created by `scripts/asc-create-mail-subscriptions.py`
then `scripts/asc-mail-territories-and-prices.py`; both are idempotent and
support `--dry`.

⚠️ **Both sit at `MISSING_METADATA`, and that is the correct state for now.**
The only missing piece is the App Store review screenshot, which cannot be
taken until a build renders the paywall — and the paywall is unreachable while
`email_subscription_enforced` is false. Submit these products with the release
that actually switches the feature on, not before. Remember a
`MISSING_METADATA` product is **not returned by StoreKit even in Sandbox**, so
until the screenshot lands, `Product.products(for:)` returns an empty array for
them and the paywall renders its store-unavailable state — that is expected,
not a client bug. **A**
second group is mandatory, not a preference** — Apple allows one active
subscription per group with no quantity on iOS, so a mail product living in
the LINE group would make a $2.99 mail purchase REPLACE a subscriber's $9.99
phone number. Because the groups are separate, a user may legitimately hold a
line AND a mail subscription at once, and nothing in the codebase may assume
otherwise.

**The free rule changes shape entirely once enforced — from a per-day
allowance to a lifetime-and-retroactive one.** Today (shipped, 2.1): N free
addresses per UTC day (`app_config.email_free_daily_cap`). Once
`email_subscription_enforced` flips true, `begin_email_order` in
`20260818160001` switches every non-subscriber to **`app_config.
email_free_lifetime_grants`** (default **1**) counted over ALL history,
retroactively — an account that has already used its one free address before
the flip is immediately walled, with no grace period. A subscriber instead
gets unlimited free-domain addresses under a SHARED-inventory daily cap,
`app_config.email_sub_daily_cap` (default **25**) — a stated hard stop, not a
throttle, because the free-domain pool is scarce and shared and one looping
subscriber could drain it for every user. **`gmail.com` is excluded from all
of this** — it was the 1-credit paid tier for everyone, subscriber or not,
until it was **removed from sale on 2026-08-26** (dead pool — see the removal
note above); the exclusion rule stands if it ever returns.

🔴 **THE LIFETIME ALLOWANCE IS TOMBSTONED — `public.email_free_grants`
(`20260826100000`) — because counting `email_orders` COULD NOT HOLD IT.**
`email_orders.user_id` is `ON DELETE CASCADE`, so Delete Account erased the
only record that the free address had been spent and the next sign-in
re-armed it; one Apple identity did exactly that **55 times** (found
2026-08-26 via `signup_grants.grant_count`, which caught it only because the
CREDIT grant is tombstoned and the EMAIL grant was not). The table has **no
foreign key to `auth.users`**, is keyed on `md5(lower(email))` AND
`md5(normalize_email(email))` — both checked, exactly as `signup_grants` —
and the gate now refuses on `greatest(per-user order count, tombstone
used_count)`. The order count is kept because it is authoritative *within* an
account and needs no address; the tombstone is the half that survives
deletion. It **fails open** on an address that cannot be resolved or
normalized (same policy as the other three grants), and writes nothing in
that case. Residual, stated plainly: a user with ten real mailboxes still
gets ten free addresses — a cost floor, not a wall. Only the non-subscriber
lifetime branch reads or writes it; the subscriber daily cap, the pre-flip
per-day branch and the gmail paid path are untouched. Behavioural checks:
`scripts/verify-email-free-tombstone.sql` (6 groups in a rolled-back
transaction).

`has_email_subscription(uuid)` is the entitlement check: `state in ('active',
'grace') and greatest(expires_at, grace_expires_at) > now()` — `greatest`, not
`coalesce`, so a stale `grace_expires_at` from a past grace period can never
shadow a later renewal's `expires_at` (see the migration's own comment; this
is the same shape as the line's ASSN state machine, one table earlier).
`email_subscriptions` has **no foreign key to `auth.users`**, by design and
for the same reason as the three credit-grant tombstones and
`line_subscriptions`: delete-account → re-signin must not silently re-grant an
Apple entitlement that already exists, and `record_email_subscription`'s
`subscription_bound` refusal is the replay catch.

`verify-email-subscription` (JWT-verified, no `config.toml` entry, in the
JWT deploy list) is the only client-reachable writer, and it deliberately
**accepts Sandbox** — unlike `iap-verify`, which gates credits on
`Production` because a Sandbox receipt is genuinely Apple-signed and costs $0.
There is no equivalent exposure here: the entitlement grants addresses on
domains that cost nothing, and it is still bounded by the subscriber daily
cap. Refusing Sandbox would mean the App Store reviewer subscribes, gets
nothing, and rejects the build.

**The paywall has TWO entry points as of 2.3 (2026-08-22), and they present
it differently.** (1) A refused order — `AppState.showMailPaywall`, the root
sheet. (2) `EmailCodeScreen`, right under *Done* once a code has landed: the
free-grant-spent card ("That was your free address") and the still-free
nudge both open `MailPaywallScreen` from a LOCAL `@State`, because the root
sheet is unreachable while that `fullScreenCover` is up — writing the flag
there is a dead button. Both paths set `intent = .mailSubscription`. The
card is rendered only over a DELIVERED code (asking for money on a mailbox
that got nothing sells a failure), never says "unlimited" (the 25/day cap is
a real server refusal), and quotes only StoreKit's `displayPrice`.

**`subscriptionFamily` is the SAME function line and mail must resolve
oppositely through — see the gotcha below.** `apple-notifications` dispatches
a mail-family notification away from the line lapse machine entirely; a bug
there would suspend or release a rented phone number over a cancelled $2.99
mail plan.

**`ops_subs()` gained a `mail` key, migration `20260818160002`** (Task 9): `total`,
`active`, `by_state`, `auto_renew_on`. ⚠️ **`active` MUST use
`greatest(expires_at, grace_expires_at) > now()`, byte-identical to
`has_email_subscription`'s own predicate — never `coalesce`.** Fix round 1
(2026-08-19) caught the migration shipping `coalesce(grace_expires_at,
expires_at)`, copied verbatim from the original brief without checking it
against the entitlement function it was meant to mirror: `coalesce` picks
whichever column is non-null FIRST regardless of which is later, so a
subscriber who went through a grace period and then renewed — a stale
`grace_expires_at` in the past alongside a fresh, later `expires_at` — read as
INACTIVE even though `has_email_subscription` correctly grants them the
entitlement. That would have fired the `/subs` disagreement warning below on a
perfectly healthy account, training the owner to ignore it. If this key and
`has_email_subscription` are ever touched separately again, re-diff them
against each other, not just against the brief that specified them. Rendered
in `/subs` (Telegram) with a disagreement warning —
entitled count vs raw active/grace state count — the same shape as the line
block's subs-vs-lines warning, catching a subscription stuck in an
active/grace state past its own expiry (an ASSN notification not yet landed
or processed).

### Rentable second numbers — the FOURTH product line (IN PROGRESS, 2026-08-05)

🔴 **SOLD, AND EVERY SINGLE SUBSCRIBER HAS CANCELLED (2026-08-17).** This
section said "BUILT BUT UNSOLD … Nobody has bought one" for twelve days after
the first sale. It is live on the App Store in 2.0, `lines_paused = false`, and:

| | |
|---|---|
| numbers rented | **6** |
| subscriptions | **5** (3 yearly w/ 3-day trial, 2 monthly) |
| `auto_renew = true` | **0 of 5** |
| median time from purchase to cancelling renewal | **3.9 minutes** |
| fastest | **6 seconds** |

**Read the two MONTHLY ones, not the average.** Yearly carries a 3-day free
trial and cancelling a trial immediately is ordinary hygiene, not a verdict. The
monthly plan has **no trial** — those two people paid $9.99 and killed renewal
at 6 seconds and 9.7 minutes.

**One churn is traceable end to end and it is not about price.**
`+14377832487` bought at **00:25:22**, attempted five calls between 00:25:52 and
00:31:37 — every one `missed`/`no_cdr` with no provider session — and cancelled
at **00:35**. The product did not work; he left. He is also the person who
e-mailed to say calling was broken.

**Do not treat this as a demand problem.** ~1.9% of 14-day signups subscribed
with the Number tab as the first tab, which is respectable for a $9.99/month
subscription shown to people who came for one throwaway SMS code. The leak is
entirely AFTER purchase. Scaling acquisition here multiplies refunds — Apple
already sent **15 `CONSUMPTION_REQUEST`** and **3 `REFUND_DECLINED`**
notifications in 48h.

⚠️ n = 5. Treat the ORDERING as the finding (cancellation is immediate and
universal), not the percentages.

Full design: `~/.claude/plans/binary-humming-moonbeam.md`.

| | state |
|---|---|
| Number tab, city→number→price store | ✅ shipped in the repo (not App Store) |
| `reserve-line-number` / `verify-line-subscription` | ✅ deployed |
| `apple-notifications` (ASSN V2) | ✅ deployed, **verified end to end** |
| messaging (webhook in, `send-line-message` out, threads, block/report) | ✅ deployed |
| `mint-line-token` | ✅ deployed; client caller added 2026-08-06 (it had none), adapters **unproven** |
| calling client (CallKit, PushKit, dialer, in-call) | ✅ `TelnyxRTC 4.1.2` linked, `TelnyxVoiceClient` live, dialer reachable — **never placed a real call** |
| `begin-line-call`, `report-line-call`, `sync-telnyx-cdr` | ✅ deployed + on cron |
| `release-lines` + the reclaim sweep | ✅ deployed + on cron (2026-08-06) |

🔴 **THE LIFECYCLE WAS NOT SURVIVABLE UNTIL 2026-08-06, and none of it threw.**
`reclaim_lapsed_lines()` shipped and was scheduled in **no cron job**;
`release-lines` — named in the migration as the thing that drains `releasing`
rows — **was never written**. An ordinary Apple cancellation went `EXPIRED` →
`suspend_line_claim` → `suspended` → **and nothing ever ran again**: $1/month
per cancelled subscriber, forever, discoverable only on the Telnyx invoice.

Fixed in `20260806100000` + `20260806110000`. The shape is worth keeping:
**the CLAIM is pure SQL on pg_cron and the provider DELETE is an edge function**,
because the claim must survive the edge layer being down (the same reason
`run_watchdog` is pure SQL) and a provider call cannot. A crash between them
costs one more sweep, never a lost number.

**The watchdog now checks BOTH a heartbeat and the state itself** —
`releasing` rows older than six hours. That second check is the load-bearing
one: it catches the leak even if the heartbeat is never written, which is
exactly the case that shipped. A heartbeat-only check would have stayed silent
for the same reason the bug did.

⚠️ **`swiftc -typecheck` NO LONGER WORKS** — the `TelnyxRTC` dependency landed
on 2026-08-06 and retired it exactly as the plan predicted. Use `xcodebuild`.
`NullVoiceClient` still exists and still throws rather than faking success, so
any path that falls back to it cannot look like it is placing real calls.

### Calling: WIRED AND REACHABLE as of 2026-08-06 — never placed a real call

**Owner decision, 2026-08-06: add `TelnyxRTC` and wire the dialer.** Done in one
commit, as the previous version of this section demanded: the SDK, the entry
point, and the calling copy on five surfaces all landed together.

**Resolved:** `TelnyxRTC 4.1.2`, and transitively **WebRTC 139.0.0** and
**Starscream 4.0.8**. ⚠️ The SwiftPM *library product* is named
**`telnyx-webrtc-ios`** while the *module* you import is **`TelnyxRTC`** — the
project file needs the former, the Swift file the latter. `Package.resolved` is
committed; keep it that way or builds stop being reproducible.

What is live: **CallKit** (`CallController.swift`), **`TelnyxVoiceClient`**
(the real adapter), **the dialer** (reached from a "Make a call" button in the
Number tab's Calls segment), **call history**, the **allowance gate**
(`begin-line-call`), **session reporting** (`report-line-call`) and **CDR
settlement** (`sync-telnyx-cdr`, on cron).

🟠 **CALLS CONNECT; AUDIO PROBABLY DID NOT — corrected 2026-08-19.** Three
calls to France (`+33`, 6s / 2s / 23s) and one attempt to Poland connected on
2026-08-18, every row carrying a `provider_call_session_id`, i.e. the leg
reached Telnyx. The provisioning fix below is what changed; nothing on the
device did.

⚠️ **"and media flowed" was an INFERENCE from the session id, and it does not
follow.** A session id says the signalling leg reached Telnyx, not that the
audio unit was running — and trap 6 below is a mechanism by which it was not,
on every outbound call, until 2026-08-19. Durations of 6s / 2s / 23s are what
"connected but silent" looks like. Nobody has reported hearing audio; treat
that as untested, not working.

✅ **PROVIDER-EVIDENCE SETTLEMENT WORKS AS OF 2026-08-26 — six calls settled
from real detail records the same day the fix landed.** For the twenty days
before that, NOTHING had ever settled from provider evidence: the heartbeat
read `{records: 0, settled: 0}` while every `line_calls` row closed
`no_cdr` / `no_cdr_full` via the 6h backstop. The query had been wrong
**three** times over (window filter, id field names, duration field names),
which is the whole lesson: **assume another cause before assuming provider
lag, and probe rather than re-read the docs** — the documented window filter
turned out to be dead too. See the ✅ three-defects block below.

**The 11 mis-billed historical rows were corrected on 2026-08-26** through the
production settlement path, not hand-written UPDATEs: `allowance_settled` was
cleared on all 11 and `sync-telnyx-cdr` invoked with its new
**`lookback_hours`** body param (cron-gated, clamped 1–720, default 24 — the
standing recovery tool for re-settling re-opened rows the 24h pending window
cannot see). Six matched real CDRs and re-settled — the 248s call went
`billed_seconds` 120 → **249** / cost **$0.035** / `NORMAL_CLEARING`; four ~1s
calls went 120 → 1–2s; the 18s call 120 → 18 — and the allowance meters moved
by exactly the sum of the deltas (verified: 1200 → 854, 120 → 18). The other
five carry session ids but **Telnyx holds no CDR for them** (dials that never
truly connected); the hourly stale backstop re-closes those at the flat
reservation, which is the documented over-bill-rather-than-under-bill policy
and unchanged. This exercise also proved `mergeCallRecords` +
`settle_call_claim` end to end in production. `cdr-never-matched` cleared the
moment the first row settled, exactly as designed.

**The watchdog now catches this, and it did not before** — the pre-existing
`sync-telnyx-cdr` check only tests the heartbeat's `updated_at`, so a sweep
that runs forever and matches nothing stayed green forever. `cdr-never-matched`
(migration `20260826140000`, in the companion `watchdog_delivery_checks()`)
pages while provider-reached calls exist in the last 30 days and NO call in all
history has ever been settled from a detail record. Its recovery signal is our
own rows, not the heartbeat: the heartbeat is per-run and overwritten every ten
minutes, whereas a CDR-settled call is exactly one that does NOT carry a
`no_cdr%` hangup cause, since those three values are written only by the
backstop.

**`probe-telnyx-connection` gained a second mode for diagnosing it:**
`POST {"probe":"cdr","session_ids":[…],"days":30}` (same cron-secret gate,
still read-only, writes nothing). It sweeps every window-filter shape × every
plausible `record_type`, looks each session id up under five filter keys in
both cases, asks Telnyx to 400 on an invalid record type, and — the part the
heartbeat cannot give — reports **`raw_rows` alongside `normalised`** per cell.
`normaliseCallRecord` returns null for a row carrying none of
`call_session_id`/`session_id`/`call_leg_id`/`leg_id`, and the caller drops
those silently, so `records: 0` cannot today distinguish "Telnyx returned
nothing" from "Telnyx returned rows whose id fields we do not read".

✅ **THE CAUSE IS KNOWN, MEASURED AND FIXED (2026-08-26).** The probe was run
against the live account and answered all five candidates at once. **THREE
independent defects**, each alone sufficient to settle nothing, none of which
threw, all now fixed in `_shared/telnyx.ts` + `sync-telnyx-cdr`:

1. 🔴 **THE WINDOW FILTER WAS DEAD, AND THE LADDER THAT CHOSE IT IS THE REAL
   BUG.** Measured over 30 days of real calls:

   | shape | HTTP | rows |
   |---|---|---|
   | `filter[date_range]=last_30_days` | 200 | **43 webrtc / 50 sip-trunking** |
   | no window at all | 200 | **43 / 50** |
   | `filter[start_time][gte]/[lte]` ← what we sent | 200 | **0, every type** |
   | `filter[created_at][gte]/[lt]` (the spec's own) | 200 | **0, every type** |
   | `filter[date_range][start_time]/[end_time]` | 400 | `No FilterType with name end_time` |

   The ladder accepted a **200 as proof a shape works** and cached the index in
   `app_config.telnyx_cdr_shape`. It locked onto `filter[start_time]` on
   2026-08-06 and asked a dead filter for twenty days. **The ladder and the
   cache are deleted**; the window is the single proven `last_30_days`.
   ⚠️ Note the SPEC-documented `filter[created_at]` is *also* dead here — so
   "read the docs harder" would have produced the same outage a third time.
   **On this API a 200 is not evidence. Only rows are.** Fourth instance of
   this exact silent-no-op-on-200 in this adapter.
2. 🔴 **WE MATCHED ON THE WRONG UUID.** A `webrtc` record carries BOTH
   `session_id` (`5ea3db0a-…`, the SDK's own) and **`telnyx_session_id`**
   (`475d4f74-…`, the one `line_calls` stores). `normaliseCallRecord` read
   `call_session_id ?? session_id`, so it normalised 43 of 43 webrtc rows onto
   an id that can never match, and dropped all 50 `sip-trunking` rows (they
   carry no `session_id` at all). Now reads `telnyx_session_id` /
   `telnyx_leg_id` first, old keys as fallbacks.
3. 🔴 **THE DURATION FIELD NAMES WERE ALL WRONG TOO.** The real fields are
   `call_sec` and `billed_sec`; not one of the four documented names
   (`billed_duration_secs`, `billed_seconds`, `duration_secs`,
   `duration_millis`) exists on a live record — so even a correctly matched
   record would have had `billedSeconds: null` and been skipped as unmatched.

**Two behaviours that follow, both decisions rather than mechanics:**
- 🔴 **ONE CALL WRITES TWO RECORDS AND THEY COST DIFFERENT AMOUNTS.** The
  2026-08-24 call: `webrtc` 249s/$0.010 and `sip-trunking` 249s/$0.025, same
  `telnyx_session_id`. Both are real charges, so wholesale is **$0.035** and
  taking either alone understates it by 29% or 71%. `mergeCallRecords` joins
  them per session, **sums the costs**, and prefers the `sip-trunking` record
  for everything else — it is the only one carrying `hangup_cause` and
  `answered_at`. Without the merge the same call would settle twice.
- **WE SETTLE ON `call_sec` (249s), NOT `billed_sec` (300s).** Telnyx bills in
  60-second increments; we sell 100 minutes of *talking*. Rounding a user's
  meter up to the provider's billing granularity would charge them 51 seconds
  they did not use — their rounding is their cost model, not our product.
  Their figure is kept as `providerBilledSeconds` for margin work.

⚠️ **`page[size]` is capped at 50 in the spec and we sent 250.** Tolerated in
practice (the probe got the same 43 rows either way), now clamped anyway.

⚠️ **THE FIRST RUN AFTER THE FIX WILL SETTLE NOTHING, AND THAT IS NOT A
FAILURE.** The 11 historical calls were already written off by the backstop, so
`allowance_settled = true` hides them from the pending query. Proof of the fix
is `raw_rows > 0` **and** `records > 0` in `telnyx_cdr_heartbeat` plus a
`telnyx_cdr_probe.parsed.sessionId` that exists in `line_calls`; real
settlement needs a new call. Assertions are in
`scripts/verify-cdr-email-watchdog.sql`. The heartbeat now reports **`raw_rows`
alongside `records`**, because "Telnyx returned nothing" and "we discarded
everything Telnyx returned" were indistinguishable for twenty days.

⚠️ **This is the open defect underneath the call-billing rules — treat the
6-hour `settle_stale_calls` backstop as the ONLY settlement path, because it
is.** `20260818140000` argued its full-reservation bill was safe on the premise
that the backstop is rare. It is not rare; it is universal, so that rule
silently became the billing rule for 100% of calls. **When you change anything
about call billing, check that heartbeat first** — the premise you are reasoning
from is probably about a path that never runs.

**Billing for a call with no CDR (`20260820110000`), and the reasoning is not
derivable from the code:**
- **No `provider_call_session_id` AND no `provider_call_leg_id` ⇒ the leg never
  reached Telnyx ⇒ bill NOTHING** (`hangup_cause = 'no_cdr_unreached'`). Before
  this, a never-connected international call was charged its entire credit
  block, and a 17-second domestic call ate 120 s of a 6,000 s allowance.
- **Either id present ⇒ bill the FULL reservation** (`no_cdr_full`). Knowingly
  over-bills a short connected call; the only other number available is the
  device's, and that must never decide money.
- 🔴 **THE GATE IS DELIBERATELY NOT ON `status`, AND MUST NOT BE MOVED THERE.**
  A `p_status in ('missed','busy','failed','canceled')` guard inside
  `settle_call_claim` looks like the obvious fix and even makes that function's
  own comment true — but `status` is written straight from `report-line-call`'s
  request body, so that guard **is** the exploit `20260818140000` closed: set
  one string, talk for an hour, pay nothing. `settle_call_claim` is left
  byte-identical so nobody "restores" it. The gate is an on/off test only, never
  an input to the amount.
- The exploit's real bound is Telnyx's per-line `daily_spend_limit`, not our
  settlement. The full-reservation bill was ~2 credits (~$0.80) against ~$36 of
  wholesale on a 10-minute premium call — a rounding error on the attack, and a
  certain recurring over-charge on every honest missed call.
- Behavioural checks: `scripts/verify-call-settlement.sql` (3 assertions in a
  rolled-back transaction, including that a client-reported `canceled` on a
  reached call still bills the full block).

*Kept because it is how this was diagnosed — the state until 2026-08-17:* seven
attempts across two users, every row `provider_call_session_id = NULL`, so no
call reached Telnyx at all.

The probe cleared the server:

- `mint-line-token` **succeeded** — no new entry in `app_config.telnyx_voice_faults`
- the destination priced correctly (France, `iso=FR`, 0.75 cr/min, 2 credits reserved)
- `allowance_settled = false`, i.e. the settle fix is holding

~~**So the failure is on the DEVICE, after the token is issued.**~~ 🔴 **NO.
THIS WAS WRONG FOR TWELVE DAYS. THE FAILURE WAS ON THE SERVER, AND IT IS FIXED
(2026-08-18).**

`attachOutboundProfile` in `_shared/telnyx.ts` PATCHed
`outbound_voice_profile_id` at the TOP LEVEL of the credential connection. The
docs put it under `outbound: {}`. Telnyx returned **200 and attached nothing**
— its documented silent-no-op on a misplaced field, the THIRD time this
adapter has hit that pattern (after `messaging_profile_id` and
`features.sms.international_inbound`). So every connection was recorded
`provider_voice_attached = true` in OUR database while Telnyx held **no
profile at all**, and — as the comment two lines above the function said —
"Telnyx requires a profile on the connection to place an outbound call." Every
INVITE was refused before a session existed. That IS "music ducks then
returns": CallKit activated audio, the dial was rejected, the session tore
down. It read exactly like an SDK failure from the phone.

**Found by a Sonnet agent re-reading the Telnyx docs, then VERIFIED, not
inferred**: `probe-telnyx-connection` (new, cron-gated, read-only — the API key
never leaves the platform) read connection `3028594732042290885` back and
`outbound.outbound_voice_profile_id` was **`null`** on a line we had marked
attached. After the fix + one `sync-line-voice` run: **`3028594742351890119`**
— the exact profile id our row holds — and `attached_verified: 6`.

Three things changed:
- `attachOutboundProfile` sends the nested shape **and reads the connection
  back**, returning a fault unless the profile is genuinely held. A 200 is not
  evidence on this API; the read-back is.
- `lineVoice.ts` step 2b: a line whose profile id is already persisted is
  verified-and-repaired on every run, not skipped.
- `sync-line-voice` runs that verify on every line with a profile, hourly,
  and reports `attached_verified` / `attach_faults`.

**The lesson is the one this file already states and this bug then broke:
"the first real use IS the probe" — but only if you READ BACK. Our own
`provider_voice_attached = true` was a record of a 200, and a 200 here means
nothing.** Anything that PATCHes Telnyx must read the field back before
recording success. `providers.md`'s standing rule ("read the value back; do
not trust the 200") applied to this function and was not followed.

⚠️ **The four inbound-calling client bugs in Known-open are still real and
still unfixed** — inbound has never been tried, and they are device-side. But
outbound was never a device bug. **The next step is a real outbound call from
a device with the 2.1 build** — the server half is now, for the first time,
actually able to place one.

⚠️ *Historical, kept because it was half-right:* provisioning WAS a separate
bug (five of six lines had no connection at all until 08-17, provisioned
lazily in `mint-line-token`). Fixing that was necessary. It could not have
been sufficient, because the thing it provisioned was then attached to
nothing.

**`isVoiceAvailable` still gates `case .dialer`**, and the "Make a call" button
is *hidden* rather than disabled when no client is attached. Keep that: a
disabled button still advertises the feature. The standing rule that produced
the removed copy is unchanged — **sell what ships** — and it now cuts the other
way, so anything added to the paywall must ship with its capability.

**Four traps, three of which are already handled in code.** They were in the
plan file (`~/.claude/plans/binary-humming-moonbeam.md`) which lives outside the
repo, so they are kept here — losing them costs a device-only debugging session:

1. 🔴 **Every `.voIP` push callback must call `CXProvider.reportNewIncomingCall`
   SYNCHRONOUSLY inside that callback** — before any `await`, any network call,
   before handing to the SDK. iOS terminates the app otherwise and, on repeat
   offences, permanently stops delivering VoIP pushes to it. Report from the
   payload metadata first, then hand to `TxClient`.
2. 🔴 **Never call `AVAudioSession.setActive(true)` yourself.** CallKit
   activates it and hands it over in `provider(_:didActivate:)`. Doing it
   manually is the classic "no audio on the first call" bug.
3. 🔴 **`INFOPLIST_KEY_UIBackgroundModes = "audio voip"` DOES NOT WORK, and
   this file told you to do it.** The setting is accepted, appears in
   `xcodebuild -showBuildSettings`, and is then **silently dropped** — Xcode's
   Info.plist generator honours only an allowlist of `INFOPLIST_KEY_*` names
   and `UIBackgroundModes` is not on it. No warning anywhere. The build
   succeeds and VoIP pushes are simply never delivered, so an incoming call
   never rings and nothing logs a reason. Caught 2026-08-06 only by dumping the
   built plist.

   The fix is **`VirtualSIM-Info.plist` at the REPO ROOT** plus
   `INFOPLIST_FILE`, with `GENERATE_INFOPLIST_FILE` left **YES** so Xcode
   merges its generated keys into it (verified: `CFBundleDisplayName` and the
   version still land). It must NOT live under `VirtualSIM/` — that folder is a
   `PBXFileSystemSynchronizedRootGroup`, so it would also be copied as a
   resource and fail with *"Multiple commands produce …/VirtualSIM.app/
   Info.plist"*.

   `INFOPLIST_KEY_NSMicrophoneUsageDescription` **does** work and is set in
   both Debug and Release. Also shipped: `VirtualSIM/InfoPlist.xcstrings` (the
   mic string is NOT covered by `Localizable.xcstrings`; verified compiling to
   `fr.lproj/InfoPlist.strings`) and `PrivacyInfo.xcprivacy` with
   `NSPrivacyCollectedDataTypePhoneNumber` + `…OtherUserContent`.

   **Assert it after ANY project-file change** — a green build proves nothing:
   ```bash
   plutil -p "$APP/Info.plist" | grep -A3 UIBackgroundModes   # must list audio + voip
   ```
5. 🔴 **THE IN-CALL SCREEN IS A ROOT `.overlay`, AND A ROOT OVERLAY RENDERS
   BELOW EVERY `fullScreenCover`.** The dialer IS a cover, so pressing call
   left the keypad on screen with the live call underneath it — invisible, and
   with no way to end it from inside the app. Reported from a real call to
   France, 2026-08-18. `InCallOverlay` is now duplicated into the cover's
   content (the shape `ErrorBanner` already had), the root copy is scoped to
   `state.flow == nil` so exactly one instance ever renders, the dialer
   dismisses itself once the call is committed, and any open sheet is
   dismissed — sheets are detented, so a call screen hosted in one would draw
   at sheet height. **In this app, "above everything" cannot be a root
   overlay.**

4. ⚠️ **`UUID.uuidString` is UPPERCASE and Telnyx's detail records are
   lowercase.** `sync-telnyx-cdr` matches with an exact-string lookup, so
   `providerSessionId` lowercases both ids. Uppercase would settle nothing and
   look exactly like a provider that never reported the call.

6. 🔴 **FULFILLING `CXStartCallAction` BEFORE DIALLING MAKES AN OUTBOUND CALL
   SILENT BOTH WAYS — fixed 2026-08-19, and a green build proves nothing about
   it.** Creating a call makes the SDK build a `Peer`, and `Peer.init` runs
   `configureAudioSession()`, which sets `useManualAudio = true` and
   **`isAudioEnabled = false`** (TelnyxRTC 4.1.2, `Peer.swift:267-268`). The
   ONLY thing in a healthy call path that sets it back is the app's own
   `enableAudioSession` (`TxClient.swift:253-255`) — the other re-enable
   (`Peer.swift:829`) fires only on an ICE restart / network change.

   Telnyx's sample places the call INSIDE `provider(_:perform: CXStartCallAction)`
   and fulfills afterwards, so the disable always precedes CallKit's activate.
   We fulfill first — the allowance gate must be able to refuse a call before
   CallKit hears about it — so our order was reversed: activate → enable →
   `dial` → **disable**, and nothing ever re-enabled it. The call connected, the
   timer ran, a `provider_call_session_id` was issued, and neither side heard
   anything. That is the shape of the three France calls (6s / 2s / 23s) and of
   `+14377832487`, who cancelled four minutes after five dead calls.

   The fix keeps our ordering and re-asserts the enable once the peer exists:
   `VoiceClient.reassertAudioSession()` (→ `isAudioDeviceEnabled = true`, NOT
   `enableAudioSession`, which would re-apply the category and `setActive` on a
   session CallKit already owns), called from `CallController` after `dial`
   returns AND again on `.ACTIVE` in `mediaConnected()` — the SDK does that
   configuration on its own queue, so a single call site is a race. It is gated
   on `audioSessionActive`, tracked from `didActivate`/`didDeactivate`, because
   claiming the session before CallKit hands it over is the same bug mirrored.

   ⚠️ **Still unverified on a device as of 2026-08-19** — read from the app and
   the resolved SDK source, not from a call anyone heard.

**Two costs, both now paid and both accepted by the owner:**
`swiftc -typecheck` no longer works and `xcodebuild` is the only check (done —
see `Common commands`), and **voice can only be tested on a physical device**;
the simulator cannot receive a PushKit push, so an outbound call appearing to
work there is not evidence.

**Two behaviours worth knowing before debugging a first call:**
- **`provider(_:didActivate:)` no longer marks the call connected.** It hands
  the session to the SDK — without which there is **no audio at all** — while
  the SDK's own `.ACTIVE` state drives `mediaConnected()`. CallKit activates
  audio moments after an outbound call *starts*, so the old wiring began the
  billing clock and the on-screen timer on a phone that was still ringing.
- **`mint-line-token` had NO Swift caller until now**, so `VoiceClient.connect`
  was unreachable by construction — the same shape as the six
  `line_subscriptions` updaters that shipped with no INSERT. `LineAPI
  .mintVoiceToken()` is it. **A deployed endpoint is not a reached endpoint;
  grep for a caller.**

⚠️ **The voice adapters in `_shared/telnyx.ts` are the one block written from
DOCS rather than probed**, and the detail-records block beside them was wrong
TWICE for exactly that reason. `mint-line-token` records every fault to
`app_config.telnyx_voice_faults`, so **the first real call is the probe** —
read that key after it.

✅ **ASSN IS PROVEN, not assumed.** Apple's own test-notification endpoint
(`POST /inApps/v1/notifications/test`) returned **`sendAttemptResult:
SUCCESS`**, and the row landed in `line_notifications` with `processed_at` set
and no error. That is the check the P-384 incident demands — verification that
passes locally and throws `NotSupportedError` in the hosted runtime looks
identical until a real request arrives. ASSN URLs are set for **both**
environments.

⚠️ **The ASC URL and the Server API do not agree instantly.** After
`PATCH /v1/apps/{id}` accepted the URL and read it back correctly,
`notifications/test` still returned **404 `4040007` "No App Store Server
Notification URL found"** for several minutes. That 404 is propagation, not a
broken key — a 401 is the auth failure. Poll rather than concluding anything.

⚠️ **The original migration shipped `line_subscriptions` with SIX updaters and
no INSERT.** The first subscribe had nowhere to write its row, every later
UPDATE would have matched zero rows, and the whole lapse state machine would
have run against a permanently empty table — silently, because an UPDATE
matching nothing is not an error. Fixed by `20260805190000_record_line_
subscription.sql`. Likewise `line_threads.blocked` shipped with no writer at
all (`20260805200000_line_thread_actions.sql`). **When a migration adds a
column or a table, grep for something that WRITES it.**

⚠️ **`settle_outbound_message_claim` keys on the MESSAGE UUID, not the provider
id** — `where id = p_message for update` is what makes it a claim. A delivery
receipt carries only Telnyx's id, so `telnyx-webhook` resolves the row first.
Passing the provider id there matches nothing and fails silently.

⚠️ **The voice adapters in `_shared/telnyx.ts` are written from the DOCS, not
probed** — the only block in that file that is. Every other function was probed
live first, which is why the traps in it are documented rather than guessed.
`mint-line-token` records each fault to `app_config.telnyx_voice_faults` so the
first real call doubles as the probe. Re-verify before trusting the shapes.

⚠️ **The Telnyx API key passed through a chat transcript on 2026-08-05 and
should be rotated** — same category as the HeroSMS key noted below. It lives
only as the `TELNYX_API_KEY` Supabase secret and is in no commit.

**What it is:** a phone number the user KEEPS — rented monthly, with two-way
SMS and two-way voice in-app. Owner decisions, all settled, do not re-litigate:
**rent-only** (no "buy outright" — a CPaaS rents from carriers forever, so a
one-time sale is an unbounded liability), **SMS + voice in one release**,
**auto-renewable StoreKit subscription** (the app's first), **Telnyx**,
**launch US/CA toll-free while pursuing 10DLC**, and a **hard-stop allowance**
with a visible meter rather than credit overage.

**Four properties that differ from the other three lines. Every one is load-bearing.**

**1. It NEVER touches the credit wallet.** Hard-stop billing means no
per-message charge and no refund path — so no `wallet_*` calls, no ledger FK,
and no new `wallet_reason`. That deletes the surface this repo has got wrong
more than any other ("a claim and its refund must be ONE transaction", which
seven paths violated). Money here is 100% Apple's. **Keep it that way.** If
overage credits are ever added they need a ledger FK plus a partial unique
index on `reason='refund'`, exactly like email and eSIM.

**2. ONE live line per user**, enforced by `phone_lines_one_live_per_user`, a
partial unique index — not by convention. Apple allows one active subscription
per group with no quantity on iOS, so **the subscription IS the line**. More
lines later means **TIERS inside the same group**, never a second group.

**3. `line_subscriptions` has NO foreign key to `auth.users`.** Same class as
the three credit-grant tombstones, but worse: without it, delete-account →
re-signin re-provisions a **second** Telnyx number while the first bills us
forever with no row pointing at it. Recurring, and invisible until the invoice.
`begin_line_rental` returns `subscription_bound` on that replay.

**4. Clients read the `my_line` VIEW, never `phone_lines`.** RLS is row-level
and cannot restrict columns, and the table holds `monthly_cost_cents` plus
every Telnyx id. SELECT is revoked outright from `anon` and `authenticated`.
This is the fix `routes` and `esim_plans` still need — consider back-porting.
⚠️ The view is deliberately **not** `security_invoker`: an invoker-rights view
would need the caller to hold SELECT on the base table, which is exactly what
was revoked. Its `where user_id = (select auth.uid())` IS the security
boundary. Do not "fix" it.

**🔴 `ON CONFLICT` CANNOT USE A PARTIAL UNIQUE INDEX unless the clause repeats
the index predicate.** Both idempotency guards — `line_messages_provider_key`
and `line_calls_session_key` — raised `42P10 no unique or exclusion constraint
matching the ON CONFLICT specification` until `where provider_message_id is not
null` was added to the statement. The indexes existed; they were simply not
reachable from the code depending on them, and every inbound webhook would have
500'd (which Telnyx retries). **A structural check cannot catch this** — the
index is present and correct. Only a behavioural test found it. The email line
uses the same partial-index pattern and never hit this because it never uses
`ON CONFLICT` against it.

**Every Swift enum mirroring these PG enums needs an `unknown` fallback in
`init(from:)`, in the first client commit.** iOS `OrderStatus` is a plain
String enum with no unknown case, which is why `begin_order` had to write a
semantically wrong `'waiting'`. Six lines each, and it permanently removes the
client-first-schema-second ordering constraint for this line.

**The subscription EXISTS in App Store Connect (created 2026-08-05 via the ASC
API, headlessly):**

| | |
|---|---|
| group | **`22289428`** "Second Number" (+ en-US localization) |
| product | **`6798378879`** `com.anthersystems.VirtualSIM.line.monthly` |
| period | `ONE_MONTH`, not family-shareable |
| price | **$9.99 USD → proceeds $8.49** (base territory **USA**) |
| availability | 175 territories, `availableInNewTerritories: true` (re-measured 2026-08-19; this said 32 for two weeks) |
| grace period | **16 days, ALL_RENEWALS, sandboxOptIn ON** |
| state | `MISSING_METADATA` |

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

### International calling — credits, not minutes (2026-08-17)

The $9.99 plan sells **100 DOMESTIC (NANP) minutes**, hard stop. Anything else
is priced from `public.voice_rates` at 5× wholesale and paid in **credits**,
because a minute-denominated bucket cannot tell a $0.005/min call from a
$3.62/min one — which is the whole reason this exists.

**TWO GATES, IN TWO SYSTEMS, AND ENABLING EITHER ALONE IS A BUG:**

| gate | where | enforced by |
|---|---|---|
| **price** | `voice_rates.enabled` | `begin_intl_call_claim` |
| **permission** | `whitelisted_destinations` on the line's Telnyx outbound voice profile | the carrier |

`begin_intl_call_claim` refuses an un-`enabled` row with `destination_unavailable`
**before charging** — *a price is not permission*. Both halves now derive from
one SQL function, `voice_dial_destinations()`, and `sync-line-voice` (hourly,
`:11`) patches every existing profile so a widening reaches lines already sold.
Profiles are **per line** (`vsms-<line id>`), each with its own
`daily_spend_limit`, so one abused line cannot ground another.

🔴 **THE NANP ROW IS NOT "US".** `voice_rates` carries ONE row for +1 labelled
"United States & Canada" with `iso2 = 'US'`. Deriving Telnyx destinations from
`iso2` alone yields a list with **no CA in it** — and every number sold is
Canadian, whose owners call Canada. `voice_dial_destinations()` expands it to
US/CA/PR/VI (matching `_shared/phone.ts`), giving **53** destinations from 50
rows. Verify with `select public.voice_dial_destinations();` before touching it.

🔴 **LONGEST-PREFIX MATCHING MEANS A COUNTRY ROW ANSWERS FOR ITS PREMIUM
RANGES.** Until 2026-08-17 the override mechanism the table documented had been
used **zero** times, so `+1900`/`+1976` (US premium, $1–5/min) resolved to the
+1 row as **`covered_by_allowance = true`** — billed against the free minute
allowance, with the dialer saying *"Included in your minutes"* — and `+4470`
(UK personal numbering, a classic IRSF target) billed at the UK landline rate.
The Caribbean NANP countries did the same. There are now **49 `enabled = false`
rows** covering those ranges; a disabled row is a REFUSAL, not a missing price.

⚠️ **A prefix table looks right in review and is wrong against real numbering
plans.** The first attempt used `3519` for "Portugal premium" — Portuguese
MOBILES are 91/92/93/96, so it would have refused most of Portugal. Premium is
760/761/762, shared-cost 707/808. **Query `voice_rate_for()` on real numbers
after any change**, both a number that must be refused and one that must not.

⚠️ Rates are **provisional**, written from public price lists — Telnyx has no
pricing API. Nine destinations (CH, JP, NZ, SI, HR, FI, SK, AT, LV/EE) sit close
enough to plausible mobile termination that a single expensive MNO range inside
them could go negative. Replace them from the real rate deck before volume.

### The line has NO free trial on either plan (owner decision 2026-08-23)

The yearly's 3-day `FREE_TRIAL` introductory offer was DELETED in ASC on
2026-08-23 (read back: 0 offers on `line.monthly` and `line.yearly`); the
monthly never had one. Why: 11 yearly trials lifetime — 4 cancelled inside
the trial, and **every one of the 3 that reached the $99.99 charge with
auto-renew ON was declined** (`DID_FAIL_TO_RENEW` → grace, all three still
`auto_renew = true`), including the line's most active user. The yearly has
billed **$0** in the product's history; the only successful line charges are
$9.99 monthlies. A trial converting to a single $99.99 hit is the wrong shape
for this audience. The 4 trials in flight at the time (converting 08-23 →
08-25) keep their original terms — Apple does not alter a running offer.
The paywall needs NO code change: `SubscriptionStore.trialLabel` reads the
live intro offer and is nil without one, so "Start 3 days free" disappears
on its own; `Products.storekit` and the DEBUG fixture were updated to match.
⚠️ The ops bot's trial heuristic (`price_milli = 0` on a `.yearly`) stays
exact for the in-flight four and is simply empty afterwards. **The MAIL
yearly's trial was removed the same week and then REINSTATED on 2026-08-27**
— see the mail-subscription section; the LINE products are the ones with no
trial, and that part of this section stands.

### Swapping a line's number — 8 credits (2026-08-21, repriced 2026-08-23)

`swap-line-number` replaces a rented line's phone number with a fresh one in
the **same area code**, charging `app_config.line_swap_credits` — **8** as of
2026-08-23 (was 5 at launch; `line_swap_cooldown_days` is **0**, i.e. no
cooldown). Owner rule: **≥ 3× margin on the swap.** Cost basis is Telnyx's
flat **$1.00 upfront** per number (the new number's $1/month replaces the
old one's); at the measured $0.40 net per credit, 8 credits nets $3.20 =
3.2×. The old number's unused remainder of the month is sunk and not in
that basis — if that ever matters, 10 credits is 4× / 2× against the $2
worst case. Available to monthly AND yearly lines alike (`canSwap` keys on
`status == .active`, not on the product). Built as **refund defence, not
revenue**: a yearly subscriber is locked in for a year, so a number that
gets spam-flagged leaves them with $99.99 of dead product and one move —
`reportaproblem.apple.com`, which we cannot decline.

**⚠️ It is NOT a retention fix, and the data says so.** Measured 2026-08-21
across 13 subscriptions: **8 inbound messages lifetime, on 5 of 13 lines**.
Nobody has worn a number out — they are not using them at all. Do not cite
this feature as an answer to churn.

🔴 **THE ROW IS MUTATED IN PLACE, and it has to be.**
`phone_lines_one_apple_line_per_user` is a partial unique index covering
`provisioning|active|grace|past_due|suspended|releasing`, so for an
Apple-billed user there is NO window in which a second row can exist:
insert-then-release is rejected by the index, and release-then-insert leaves
the user with no line at all if the insert fails. Mutating `e164` /
`provider_number_id` also preserves the line id — the Telnyx connection,
outbound profile and credential are all named `vsms-<line id>`, so they
survive the swap untouched.

**`status` never changes during a swap.** Adding a `'swapping'` value to
`line_status` would need the client shipped first, and it would be a lie: the
OLD number keeps receiving right up to the cutover. In-flight state lives in
`line_number_swaps`, where a partial unique index (`state='claimed'`) makes a
double-tap impossible without touching the enum.

**`complete_line_swap` sets `provider_voice_attached = false` deliberately.**
That flag is what `provisionLineVoice` keys its attach step on; leaving it
true would mean the new number never rings and nothing would ever notice —
the exact shape of the twelve-day outbound-voice outage.

**The old number's release is tracked in `line_number_swaps`, not
`phone_lines`.** Because the row is mutated, the old number stops being
referenced by any line the instant the cutover lands, so the swap row is the
only record it is still ours. `release-lines` drains
`swaps_pending_release()`; that drain is deliberately NOT behind
`line_orphan_release_enabled`, because an orphan is a number we cannot prove
is unused while a swap row names exactly which number was replaced.

Verified by `scripts/verify-line-swap.sql` — 10 behavioural groups in a
rolled-back transaction, including double-cutover, double-refund,
cross-user, and refuse-without-charge. ⚠️ **The Telnyx order/release half has
never run against the live API** (doing so would spend float and give away a
real customer's number); the call shapes are copied verbatim from
`reserve-line-number`, which is proven. **The first real swap is the probe.**

### Line country catalog — data-driven sellability (2026-08-27)

The rented-line store is no longer a hardcoded 7-Canadian-city list. Which
countries sell is decided by **`line_country_catalog`** (PK country_code ×
number_type), written only by `sync-line-countries` (cron `relay-sync-line-
countries`, 03:40 daily) from live Telnyx reads: `GET /v2/country_coverage`
(per-type capability flags) and `GET /v2/requirements?filter[action]=ordering`
(the document gate). Cities/area codes live in **`line_localities`** (seeded
with the exact 7 CA cities the old CITIES maps carried — the maps are deleted
from all three functions). Clients read the **views** `line_country_menu` /
`line_locality_menu` only; the base tables are the cost book and compliance
record and are service-role-only. Bootstrapped 2026-08-26: 125 rows, 3
sellable (US, CA, PR — all $1.00/mo except PR $3.00), GB/DE/FR/NL/PL/AU
blocked `documents_required` (3–6 docs each).

Rules that are load-bearing:
- **A country sells ⇔ probed AND (zero ordering documents OR an APPROVED
  requirement group)**, computed by `refresh_line_country_sellability()`.
  NULL fails closed everywhere: never-probed ⇒ blocked. There is deliberately
  **NO `force_sell` override** — the only override is `force_block`. Filing a
  requirement group in Telnyx (owner action, manual) and recording its id on
  the row turns a documented country green with no deploy.
- **Every seller calls `_shared/lineCatalog.ts::sellableCountry()` and fails
  CLOSED** (`country_not_sellable` / `catalog_stale` / `catalog_unreadable`).
  Consequence: **an empty or stale catalog takes the WHOLE line store down,
  Canada included** — the watchdog checks `line-country-catalog-stale`,
  `line-country-none-sellable` and `line-country-order-rejected` exist for
  exactly this. Never deploy the sellers against an unpopulated catalog.
- 🔴 **Never re-add a literal `filter[features][]` to `searchNumbers`.**
  Probed 2026-08-26: `features[]=sms&voice` on GB/DE local returns **HTTP 400
  code 10015**, not an empty list — the old hardcoded filter made every
  voice-only country read as a provider outage. `searchNumbers` now defaults
  to NO features filter; callers pass what the catalog row says.
- **`withinWholesaleCeiling`** (config `line_wholesale_ceiling_monthly_cents`
  300 / `_upfront_` 500) is a SAFETY guard, not pricing. The comparison is
  `>`, so a number at exactly the ceiling is allowed — PR samples at exactly
  300¢/mo and must stay orderable. Non-USD quotes are refused, never
  converted; outside NANP `costKnown=false` is a refusal (the fallback cents
  are NANP-calibrated).
- **`verify-line-subscription` re-checks sellability after the JWS and before
  `orderNumber`**, and a Telnyx `requirement-info-pending` rejection
  self-heals the catalog (`sell_reason='order_rejected'`, preserved by the
  refresh until a real blocker replaces it) so the next user never hits the
  same wall. `rent-line-credits` does the same. **Swap is deliberately NOT
  gated on sellability** (only the ceiling) — a regulatory change after the
  sale must not strand a paying subscriber; swap stays same-country always.
- **`toE164` takes the line's country** and refuses a bare national number on
  a non-NANP line instead of guessing +1. The client warns voice-only ONLY on
  `supports_sms === false`, so a sellable country must always carry a real
  supports_sms value.
- The client (2.4) shows ALL probed countries with capability icons, green
  where supported, gray where not; blocked rows render "Not available yet".
  Behavioural checks: `scripts/verify-line-country-catalog.sql` (10 groups,
  rolled back), `scripts/verify-line-catalog-gate.ts` (29 offline assertions),
  `scripts/verify-lines-countries-format.ts` (`/lines countries` rendering —
  the Telegram ops view of the catalog incl. per-country wholesale).
- ⚠️ **The first non-NANP order has never run** — US/CA/PR need no documents
  so today's sellable set exercises only the proven NANP path. When a
  requirement group first makes a documented country sellable, the first
  order IS the probe (owner-controlled credits line, read the order back).

### 🔴 The client is never authoritative about money

`report-line-call` takes `status` from the REQUEST BODY. Until 2026-08-17
`attach_line_call_session` saw a terminal-unconnected status and immediately
called `settle_call_claim(call, 0, …)`, which refunds the whole credit block and
sets `allowance_settled = true` — and `sync-telnyx-cdr` sweeps
`allowance_settled = false`, so **the real detail record could never correct
it**.

Exploit: dial anywhere, POST `{call_id, status:"canceled"}` ten seconds in
(`begin-line-call` is deliberately not on the ring path, so the call continues),
get every credit back, talk as long as you like, repeat. The same request
returned the 120-second domestic reservation on every call — an unlimited
allowance.

The migration that introduced it argued *"canceled/failed/busy/missed mean no leg
was ever answered BY DEFINITION"*. **True of a PROVIDER-reported status; false
of a client-reported one**, and this function only ever receives the latter.

The client's report is now **advisory**: it records status, `ended_at` and
duration for the UI and settles nothing. Money moves only on provider evidence
(`sync-telnyx-cdr`) or the `settle_stale_calls` backstop. The cost is that a
genuinely failed call holds its reservation until a sweep runs — the right
trade, because an instant refund on a live call is a loss that also destroys the
evidence needed to notice it.

**Generalise it: if a value decides money and the device can set it, the device
must not be the one that settles.**

🔴 **`provider_call_session_id` AND `provider_call_leg_id` ARE CLIENT-SUPPLIED,
DESPITE THE NAMES. THEY ARE NEVER PROVIDER EVIDENCE.** They are written only by
`attach_line_call_session`, whose argument is `report-line-call`'s request body
verbatim (`p_session: body.session_id ?? null`); `telnyx-webhook` handles no
call events. **Nothing in this product writes a call identifier from a source
the device does not control.**

This is not a hypothetical. On 2026-08-20 `settle_stale_calls` was changed to
bill ZERO when both ids are null — "the call never reached Telnyx" — explicitly
choosing that gate over a `status` gate because `status` is client-supplied.
Same column, same problem, hidden by the name. It made **silence the winning
move**: never report (or force-quit mid-call) and the 6-hour backstop refunded
the whole reservation and the whole international credit block, with
`sync-telnyx-cdr` unable to correct it because it matches on the ids the
attacker suppressed. Reverted in `20260820120000`.

**The only correct source of a call's duration is the provider's detail
record.** `sync-telnyx-cdr` has matched ZERO in the product's history, so until
it does, the backstop deliberately **over-bills rather than under-bills**: it
charges the server-set reservation from dial time. An over-charge is bounded,
visible in the ledger and refundable by hand; an under-charge is unbounded,
invisible and repeatable. **Any future gate must key on data THE DEVICE CANNOT
SET** — today no such field exists on `line_calls`.

### Support chat — user types in-app, owner answers from Telegram (2026-07-30)

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

### Retry steering (create-order)

A retry after a failure must not hand back the same dead pool. Two mechanisms,
both in `create-order`:

- **Fresh-number guarantee** (`157748c`): numbers this user already burned on
  this service are excluded from the reservation, so a retry is never the same
  number.
- **Operator rotation** (`fbfe8c9`): if the carrier we'd pin is one the user
  just failed on, pick the cheapest *untried, non-`Donor*`* real carrier from
  the live per-operator price map (`getCountryPrices` → `po`) that still fits
  `maxCostUsd`. Fallbacks are asymmetric on purpose — **standard** drops to
  unpinned (at least a different pool than the one that just failed);
  **premium** keeps the route pin, because the buyer paid for *that* real-SIM
  pool and must never be silently downgraded. The lookup is wrapped in
  try/catch and ignored on failure: rotation is an optimization, never a
  reason to fail an order.

Standard orders also pin the route's real carrier whenever it fits the ceiling —
probed 2026-07-21, the carrier costs the same or *less* than a random fill,
because "random" usually means a `Donor*` VoIP pool that strict services reject.

### Steering: never tie-break on price, and never "fix" it by hiding inventory

Route-level evidence covers **7 of ~17,800 routes**, so essentially every route
falls through to the tie-break — and that tie-break used to be **price**.
Cheapest-first is the one ranking rule guaranteed to select the least-vetted
inventory in the catalog. Colombia is the cheapest of all 69 countries (avg
wholesale **$0.109**, median 2 cr), so that is where every ranker landed: a sort
literally labelled *"Best success"* was leading with the bargain bin, and
`affordableFallbackCountry` put new users on discord/co (0 of 2).

**Hiding the bad country does not work, and the data is unambiguous.** With
Colombia hidden, a 3-credit user lands on instagram→bd, discord→il, google→vn,
tiktok→ph — **all never tested** — and where the next-cheapest countries have
been measured they are *worse* (cl 2/13, za 0/8, ph 0/2, bd 0/1). Colombia
(4 of 15) is the best performer in the cheap tier. **The price floor
regenerates**: delete the cheapest country and the next one inherits the
traffic, having thrown away the only measurement you had. Fix the rule, not the
catalog.

The replacement is `countries.observed_attempts/observed_codes/observed_orders`,
written by **`refresh_country_delivery()`** (migration `20260728130000`, in
`sync-prices`' hourly maintenance list). It mirrors `refresh_service_delivery`
including all four evidence rules. Tiering everywhere is now: proven route →
untested-in-a-good-country → untested-unknown → untested-in-a-bad-country →
measured-failing route. Applied in **four** places — `bestCountry`,
`affordableFallbackCountry`, `CountrySheet`'s "Best success", and the
post-failure **retry picker** (which matters most: retrying into the same
bargain bin is the worst possible answer after a user has already been let down).

Two constraints:
- **Country evidence is steering input and is NEVER rendered.** It is not a
  claim about the specific route on screen; the badge keeps saying exactly what
  was measured for that pair (see Badge confidence).
- **Do not roll this up client-side from `routes.success_*`.** That was tried
  and removed: it carries no provider scoping the client can apply, so it mixes
  in retired-provider numbers (all 5 of Indonesia's failures and 5 of South
  Africa's 8 are smspool/virtualsms), and it saw only **12 of the 25** countries
  with order history against the server's 20.

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

### The pool rate is the tie-break (1.8, 2026-08-03)

`routes.pool_rate_pct` is 5sim's published **7-day** rate for the **exact pool the
route buys from** (`routes.pool_operator`), written hourly by `sync-5sim`. It
covers **2,638 of ~7,700** active 5sim routes (08-05: 1,540 on the 7-day window,
1,097 falling back to 30-day because the pool saw no activations in a week) and
is the number the country row renders. This replaced `service_country_ranks` as
the tie-break. Coverage moves every hour — re-query before quoting it.

🔴 **IT WAS `rate24` UNTIL 2026-08-05, AND THAT MISLED USERS IN BOTH
DIRECTIONS.** `pool_rate_pct` was written from the same `rateOf` ladder that
PICKS the pool, so the row rendered the shortest, noisiest window 5sim
publishes. The incident: one user ran **seven** Tinder orders in 8.5 minutes.

| route | rendered (`rate24`) | `rate168` | `rate720` | what happened |
|---|---|---|---|---|
| tinder/co `virtual34` | **88** | 71.4 | 71.2 | 4 orders, 3 real attempts, **1 code** |
| tinder/us `virtual63` | **15** | 47.1 | 57.3 | 2 orders, both cancelled early |
| tinder/ar `virtual4` | **61** | 13 | — | 1 order, cancelled |

So the app oversold Colombia, undersold a usable US route, and oversold
Argentina — all from the same defect. Measured over 3,320 in-stock pools
publishing a positive rate somewhere (12 countries): median
|`rate24` − `rate720`| **9.6 points**, **16.6% differ by 30+ points**, only
50.8% agree within 10.

**The fix was display-only and cost nothing in coverage.** 5sim's rate fields
are perfectly nested by window length (0 violations over 14,892 in-stock pools),
so any pool publishing `rate24` also publishes `rate168` — both rules rate
exactly 8,791. Aggregate barely moved (mean 10.9 → 10.7; green 528 → 495, amber
808 → 834, red 7,455 → 7,462); **6.9% of pools changed colour band, 296 up and
310 down.** It is noise reduction, not a repricing of optimism.

⚠️ **The catalog is genuinely red-heavy and that is not a bug in this change** —
median rated route is **9%**, 814 routes publish exactly 0, only 292 are green.
That was equally true before. It is what the inventory is.

⚠️ **This changed what `orders.pool_rate_pct` stamps at reservation.** Orders
before 2026-08-05 carry `rate24`, after carry `rate168`. **Split the pending
correlation study on that date** or the halves are not comparable.

**STILL OUTSTANDING: the rendered number is ~2× our realised delivery.** Across
every 5sim order that got a number and was NOT cancelled: published 80+ → **40%**
(5 orders), 60–79 → **25%** (8), 30–59 → **0%** (9), <30 → **0%** (4). The
ranking is **monotone**, which is the first positive read on the correlation
study — the steering works. The LEVEL does not. n = 27, so treat the ordering as
the finding and the percentages as indicative. Re-run at ~100 non-cancelled
orders before acting. **DONE IN THE REPO 2026-08-27 (2.5 work): the user-facing
render no longer quotes a bare percentage** — `NetworkRateMeter` prints the
colour band as a word (High >60 / Medium 30–60 / Low <30, the same thresholds
as the colour so the two can never disagree), localized in all six locales; the
bar's continuous FILL still uses the raw value, and sorting, stamping and ops
surfaces stay numeric. Rationale: a third-party aggregate with no published
denominator should not wear two significant figures — this repo's own standing
rule (see Badge confidence, and the SMSPVA seeded grade demoted to
`.notTested`). Reaches users when 2.5 ships. `RecoveryScreen`'s
`CountryRank.vendorPercent` (the superseded `service_country_ranks` figure) is
the one remaining bare vendor percentage on any screen — same class, not yet
converted.

**Colour bands (owner, 2026-08-03): >60 green, 30–60 amber, <30 red.**
`CountrySheet.poolRateColor`. Sort options are exactly three — **Best success,
Cheapest, A–Z** ("Fastest" was removed). The "Top success rates" card was
deleted in favour of one advisory line telling users to prefer high rates.

**`AppState.rankedUntestedKey` orders untested routes by
*(pool tier, pool rate, country tier, country record, price)*.** Two bugs were
fixed getting here, and both are the same shape — a ranker reading a different
table from the row in front of the user:

1. It read `service_country_ranks` (1,043 rows) while the row rendered
   `pool_rate_pct` (2,715 at the time). **1,672 active routes displayed a real
   percentage that the ranker scored as 0** — 1,057 after the pool re-tiering,
   still the same defect. Where both exist they agree exactly, so this is a pure
   coverage win.
2. The **country tier came first**, and country evidence is a cross-service
   roll-up over a handful of orders. The UK (3 attempts, 0 codes) and the US
   (4, 0) sorted *below* countries we know nothing about while holding some of
   the best-rated pools. The pair-specific rate now leads; the country tier only
   breaks ties between equally-rated pools.

Measured over the 146 services with a bookable route, switching the key moves
the mean published rate of the DEFAULT country from **25.5% → 43.2%** and cuts
services defaulting onto a published-0% route from **34 → 5**; 103 services
change country.

**A published 0% sorts LAST, below unrated — and this deliberately differs from
the display sort.** `CountrySheet`'s "Best success" lists 0% *above* unrated,
because the owner asked for measured values descending. The default *pick* does
the opposite. The distinction is between a list the user scrolls and a choice we
make FOR them: **389 of ~1,760 rated routes publish exactly 0**, and defaulting someone onto inventory
the vendor itself reports as dead is the same error as the old cheapest-first
rule. "No information" beats "reported dead".
This is also why `MIN_POOL_STOCK`-style stock guards are not enough — see the
5sim section on tiny denominators.

**The post-failure retry picker (`retryKey`) shares the same key.** It used
`untestedKey` directly and was blind to the pool rate entirely, which is the
worst possible place for that gap.

**Does the rate predict OUR delivery? UNVERIFIED — this is the test that
justifies the whole feature.** Against HeroSMS orders, 5sim's rates correlated
*negatively* with our outcomes (r = −0.51, n = 16) — on a different provider's
pools, so it is not damning, but it is not nothing either. `orders.pool_rate_pct`
and `orders.pool_pinned` are stamped at reservation for exactly this. After ~100
numbered orders, group by band and compare. **If the correlation is not
positive, the number must come off the row.**

### Measured arrival timing + evidence-gated warnings

`services.eta_seconds` is seed data (22–35s, DB default 30, never recomputed) and
the app used to render it as fact in four places. Measured median arrival is
**~53s** with p90 ~139s, so the app promised a wait it could not keep and users
cancelled at a median of 63s believing the code was overdue — while 86% of all
codes ever delivered arrived inside that same window. Migration
`20260724120000_measured_arrival_timing.sql` adds
`arrival_p50_seconds/p90/sample/scope/hold_pct` on `services`, filled by
`refresh_arrival_timing()`. Percentiles resolve **service → global → NULL**, never
per-route: only 2 of 18,492 routes have ≥8 deliveries, and `routes` ships to every
phone with `select=*`, so 18k mostly-NULL columns to serve two routes is a bad
trade.

**Wired up end-to-end on 2026-07-25** — and doing so exposed that neither half
had ever worked:
- The migration's own header said it was "called from sync-prices' hourly
  maintenance list". It was not in that list. The p50/p90 had been written once
  by hand and then froze.
- Adding it revealed `refresh_arrival_timing` could never have run via RPC at
  all: `maintenance.arrivalTiming` returned **`error: UPDATE requires a WHERE
  clause`**, because the statement stamping the global band onto every service
  had no `WHERE`. Fixed in `20260725150000` with `where id is not null`.
- `Service.swift` had no `arrival_*` fields, so three screens still quoted the
  seed as fact. They now use `typicalWaitShort` / `typicalWaitSentence`, which
  return **nil rather than a guess** — Home shows "—", Checkout hides the row,
  Waiting says "Your code appears here the moment it arrives."
`typicalWaitSentence` phrases by `arrival_scope`: a **global** band must never
be worded as this service's own record. Live values: p50 47–52s, p90 ≤144s,
hold_pct 86 (267 services on the global band, 1 with its own).

`20260724120100_blunt_delivery_warnings.sql` adds `services.observed_orders` (ALL
outcomes — a superset of `observed_attempts`, which counts only conclusive ones)
and `routes.success_sample`. Both exist **only to warn on strong evidence, never
to reassure on weak evidence**: a service that has never once delivered could
previously sit under the sample gate and display nothing at all, and a bare
`success_rate` couldn't distinguish 1-of-3 noise from 2-of-40 disaster.
`success_sample` reached the Swift `Route` model only on 2026-07-25 — before
that the column existed server-side and the client never selected it, so any
claim that the client "requires `success_sample >= 5`" was false. It now does
carry it, and below 5 the UI states the sample instead of a bare percentage
("0% of 2 tries", not "0% delivered") — which matters because the asymmetric
gate writes `measured 0%` off just two attempts.

### Pausing the eSIM line (backend only, no build) — 2026-07-31

**eSIMs are PAUSED as of 2026-07-31** while the owner switches eSIM providers.

**The switch happened 2026-08-10: eSIM Access is implemented end to end and
the line STAYS PAUSED until the owner tops the account up (~$50 minimum).**
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

### The minimum hold (now 90s), and the late-code rescue (2026-07-27)

⚠️ **THE HOLD IS PER-PROVIDER as of 2026-08-18 — `MIN_HOLD_BY_PROVIDER` in
`cancel-order`, ALL AT 90 TODAY.** This whole section was written for a flat
180 and much of the reasoning below still quotes it; the *arguments* stand,
the *number* does not. Read `cancel-order/index.ts` before quoting a figure.

Why per-provider: measured over every code ever delivered, HeroSMS has NEVER
arrived after 86s (p90 79s) while 5sim's p90 is 155s. One number cannot be
right for both. **5sim is deliberately held at 90, not its p90 of 155**,
because shipped 2.0's `WaitingScreen.minHoldSeconds` is a hardcoded 90 —
raising the server first unlocked a Cancel the server then refused (13 of 29
recent 5sim cancels landed in that 90–155s gap), i.e. exactly the invariant
that file states: the client may only ever be RAISED ahead of the server.
It was raised to 155 and reverted the same day. **2.1 fixes the client side**
(`AppState.minHoldByProvider` mirrors the server, and `WaitingScreen` honours
`retry_after_seconds` from a 429 so the button re-locks instead of erroring)
— raise the 5sim server value to 155 ONLY after 2.1 is adopted, in the same
change as the client table.

⚠️ Do NOT justify a longer hold with "otherwise the code is lost": since
2026-07-27 a cancel does NOT release the number — the poller still delivers
a late code free. The hold protects the code from a REROLL, not a cancel.

Cancels landed at a **median of 57s**; codes arrive at a **median of 58s**, p90
134s, and 45% of codes that arrive do so after 60s. Users were destroying orders
one second before the typical code. Two changes, and they compose:

**1. `cancel-order` refuses to destroy an order held under `MIN_HOLD_SECONDS`**,
returning **429 `cancel_too_early`** with `retry_after_seconds`. It covers
**reroll too** — a reroll releases the number identically, so an early reroll
discards an in-flight code just the same. `WaitingScreen` renders a live
countdown in place of the ✕ and disables both reroll buttons.

The original 180 sat above p90 arrival while leaving 5 minutes of the 8-minute
window, and it worked: median cancel went **58s → 220s** with **zero** cancels
under 180s. It was cut to 90 because the same guard that protects an in-flight
code also traps a user who already knows the number is dead, and 90s still sits
above the 58s median arrival. Watch the cancel-time median and the
non-cancelled delivery rate; if delivery falls, this is the first thing to
re-examine.

**429, not 409, is deliberate:** shipped 1.4 has no case for the error code and
falls back on HTTP status, where 429 reads *"You're going a bit fast — please
wait a moment and try again"* — nearly right by accident, where 409's *"Not
available right now"* would mislead.

**Enforcement is UNCONDITIONAL as of 2026-08-01.** `enforce_min_hold` is still
accepted for compatibility but gates nothing.

It used to be opt-in because pre-1.6 `rerollNumber` does
`if let server = try? await orders.cancel(...)` and creates the replacement
**regardless of whether the cancel succeeded** — so enforcing for everyone would
leave the original `waiting` AND charge for a second order. Two measurements
retired that objection:

1. **`begin_order` already deduped** on (user, service, country, tier) within
   15s, so a **same-country** reroll was always protected and charged nothing.
   Only a different-country reroll slipped through — **7 in 30 days across 3
   users**, against 23 same-country ones already caught. `20260801100000` drops
   `country_id` from that predicate and closes it. That is a no-op for healthy
   flows, because the match still requires the earlier order to be `waiting`:
   a 1.6+ reroll either aborts client-side or cancels successfully first.
2. **A refused cancel does not trap pre-1.6 users.** Their `cancelWaiting`
   catch sets `flow = nil`, so they still LEAVE the waiting screen while the
   order keeps running — which is exactly the non-destructive ✕ that 1.6
   introduced. They get it for free, and a delivered code still reaches them by
   push. (They have no `ResumeBar`, so they cannot navigate back; the push and
   `resumeInFlightOrder()` on cold launch are the return paths.)

**Why it could not wait for adoption.** Over 30 days **87 of 147 numbered
orders (59%) were cancelled by the user and delivered 1.1%**, against ~73% for
orders left alone; `expired` orders delivered **0 of 16**. Gating the hold on
client version left the single largest lever on delivery switched off for
essentially the entire install base — in one 48h sample **20 of 22 cancels were
under 180s, one at 4 seconds**. Waiting for 1.6/1.7 adoption would have meant
weeks of it.

⚠️ **`MIN_HOLD_SECONDS` (90) is now EQUAL to `PRE_RESERVATION_GRACE_MS` (90s),
not 2× it.** While the hold was 180 it strictly subsumed the numberless-cancel
guard for the first three minutes; at 90 the two windows coincide exactly, so
the guard is doing real work again at its own boundary rather than sitting
inside a longer one. It must not be removed, and the two constants must be
reasoned about together — `cancel-order/index.ts:41` carries the same note.

**2. `cancel-order` NO LONGER CALLS `release()`.** It refunds, stamps
`orders.late_watch_until` = the original deadline, and leaves the number alive.
`poll-active-orders` sweeps those rows and, if a code lands, writes it and pushes
it — **the code is given away free; the refund stands** (owner decision: 92% of
users who ever receive a code go on to purchase, against at most $3.50 of
forfeited wholesale). Once the window closes with no code the sweep `markDead`s
it to reclaim what it can.

Three non-obvious constraints in that path:
- **Status stays `canceled`.** `order_status` cannot grow a value without
  shipping the app first (see the gotcha below), so a rescue is *not* a new
  status — it is an `otp` on a canceled row. **Every consumer must therefore
  treat `otp is not null` as "a code exists", not `status = 'received'`.** Five
  SQL functions and one Swift property keyed on the old predicate and scored a
  delivered code as a failure; `stranded_credit_candidates` would have told a
  user who *got* their code that "every number that fails is refunded".
- **The push carries no `orderId`.** Shipped `PushManager` routes on it and
  would deep-link into the refund screen instead of the code.
- **The sweep runs BEFORE the polling loop**, not after. It was last, behind up
  to 200 expiry claims and 50 sequential provider polls in a ~150s budget — so
  it was the first thing dropped under load, which is exactly when held numbers
  cost most, and it is now the *only* thing that ever releases a cancelled
  number.

**`markDead` cancels FIRST, then bans.** `cancelorder` is what reclaims the
wholesale; `blocknumber` is hygiene, and SMSPVA's docs don't say whether the ban
consumes the request id. Banning first was harmless while `cancel-order` called
`release()` directly — routing all reclamation through `markDead` made it a real
leak ($38.14 of wholesale sat in cancels over 30 days, against ~$146 net revenue
in the same period). A forfeited refund is certain cash; a re-issued number is
already filtered by the fresh-number guarantee.

**`resumeInFlightOrder()` runs on COLD LAUNCH ONLY.** Force-quitting during a
wait used to strand a paid order — screen gone, nothing polling, only a history
row. It restores the newest `waiting` order that has a number, and ignores rows
more than 10 minutes past expiry so old ones aren't resurrected. Never call it
from a `scenePhase` change: a backgrounded app still holds `flow` in memory, so
it would yank the user out of whatever they had navigated to.

**An eSIM LPA is single-use.** Once iOS consumes the profile the same QR/URL
fails with an opaque Apple error that looks like we sold a broken eSIM, so the
second and later taps of "Install eSIM" confirm first. It *warns* rather than
blocks — a first attempt that died before the profile was consumed must still
be retryable — and the flag is persisted in `UserDefaults`, because the user
leaves for Settings mid-install and returns to a freshly-built view.

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

### Evidence must describe the provider that serves the NEXT order

Three bugs, all silent. Two fixed 2026-07-30 (`20260730220000`,
`20260730230000`), the third 2026-08-04 (`20260804090000`).

**3. The per-provider loop OVERWROTE service evidence instead of adding to it.**
`refresh_evidence_all_providers` called `refresh_service_delivery(lookback,
provider)` once per provider. That is right for ROUTES — `routes` has a
`provider` column, so the passes are disjoint — and wrong for SERVICES, because
`public.services` has none, so every pass wrote the same row and the last one
won. The loop runs `order by 1`, so **`smspva` sorted last and silently won
every service it co-owns**, including the highest-volume ones (facebook: 52
orders across 4 historical providers; leboncoin: 50 across 3).

The wrapper's own comment asserted "`services` is made disjoint by the ownership
predicate" — true only under the per-service ownership rule, which the catalog
stopped satisfying (109 of 254 services sit on two providers; see the header).
**A comment claiming an invariant is not the same as enforcing it.**

Fixed by dropping the provider parameter and filtering each ORDER by whether
**its own** provider still actively serves that service, in a single pass called
once outside the loop — exactly how country evidence is already handled, and for
the identical reason. The property that mattered survives untouched: 53 orders
from retired providers (50 smspool, 3 virtualsms) are still excluded, because
those providers own no active routes. Live effect: services carrying evidence
12 → 14, orders counted **39 → 57**.

**The general rule: a per-provider refresh may only write to a table that has a
provider column.** `routes` does. `services` and `countries` do not, so both
must be refreshed exactly once with per-order ownership filtering.

**1. Only one provider was ever measured.** The three refreshes scope every
statement to `coalesce(p_provider, active_sms_provider())`, and
`active_sms_provider()` votes by **active route count**. After the per-service
split, and after `sync-herosms` hid what HeroSMS cannot serve, SMSPVA held
**7,757** active routes against HeroSMS's **5,201** — so the vote returned the
provider that had *stopped serving the demand*. HeroSMS routes could never gain
a measured rate, `rate_source='measured'` was **0 rows catalog-wide**, every
route rendered "Not tested", and the pre-registered 40-order rollback checkpoint
for the switch could not be evaluated at all.

Do **not** re-tune the vote. A vote by recent order count is unstable
mid-cutover and keeps one provider's evidence hostage to another's row count.
`refresh_evidence_all_providers()` instead runs the route + service refreshes
**once per provider**, and country evidence **once** (a country is not owned by
a provider). `sync-prices` calls only the wrapper.

**2. Surviving evidence described a RETIRED provider.** `services` and
`countries` have no provider column, so per-provider passes clobbered each
other — and the winner was whoever ran last. Worse, facebook is served by
HeroSMS while its evidence read 14 attempts / 6 codes, all **SMSPVA**, with 32
smspool and 3 virtualsms orders sitting in the same 30-day window from providers
we do not use at all.

Both functions now require that an order's provider **still owns that service**
(`exists (select 1 from routes r where r.service_id = … and r.provider = …
and r.status='active')`), and only wipe rows belonging to the provider being
refreshed. Retired providers drop out by construction.

**Expect evidence to look emptier after a provider switch, and that is
correct.** Applying this took facebook/instagram/whatsapp/leboncoin/tiktok to
NULL, because HeroSMS has barely any orders yet. "Not tested" beats a retired
provider's number, and it rebuilds within days at ~55 orders/week.

### VoIP-only routes are hidden for services that reject VoIP

`app_config.voip_strict_services` (seeded `["facebook","instagram","whatsapp"]`)
is a hand-maintained list in the same shape as `blocked_routes`. `sync-herosms`
hides any route for those services whose `physicalCount` is **0**.

Why: measured 2026-07-30, facebook **16.3%** and instagram **8.3%** over 30 days
— together ~50% of all order volume, against leboncoin 50%, tiktok 71%. Meta
rejects VoIP ranges, which is the entire reason we moved to the one provider
that reports real-SIM stock, and we had been recording `physicalCount` on 4,046
routes and using it for nothing.

First run hid **62** routes: facebook 69 → **47** active, instagram 69 → **48**,
whatsapp 64 → **45**, and every remaining active route for those three has real
SIMs. Non-strict services are untouched (leboncoin keeps 3 VoIP routes, tiktok
18).

This is "we cannot deliver this", the same category as `blocked_routes` — **not**
a judgement on measured performance, so it does not contradict the standing
"label, don't hide" rule, which governs outcomes we have actually observed.
Two guards, both asserted after the run: a route whose service failed to price
this run is skipped (never hidden), and `hit` is non-null at that branch so a
zero is a real reading rather than a missing one.

**STILL UNTESTED as of 2026-08-02 — and beware a tempting false refutation.**
`facebook/dk` has `physicalCount = 0` and delivered **4 of 5 (80%)**, which looks
like a counter-example and is not: `physicalCount` is a **HeroSMS** stock metric
and those 4 codes were delivered by **SMSPVA**, before the re-home. Comparing one
provider's inventory figure against another's outcomes is meaningless. Restricted
to HeroSMS orders only there is **no zero-physical band at all** (0 orders), so
the hypothesis is **untested, not falsified** — exactly as this file said, and a
claim to the contrary was made and retracted the same day.
`orders.operator_used` (see the Real SIM section) is what finally settles it.

**It is a well-motivated GUESS until measured, so it was made falsifiable in the
same change.** `orders.route_physical_count` records the route's real-SIM stock
at reservation (null = not recorded, never zero). Settle it with:

```sql
select (route_physical_count > 0) as had_real_sims,
       count(*) n, count(*) filter (where otp is not null) codes
from public.orders
where smspva_number is not null and provider = 'herosms'
  and service_id in ('facebook','instagram','whatsapp')
group by 1;
```

Rollback is `voip_strict_services = '[]'` — the next hourly run re-activates
everything.

### The Real SIM tier on HeroSMS (VoIP vs real carrier, +20%)

**⚠️ WE PIN EVERY REAL CARRIER, NOT ONE (2026-08-02, `routes.herosms_real_operators`).**
`getNumberV2`'s `operator` param takes a **comma-separated list** — verified in
the spec (`qpSAOptionalOperator`: *"List of desired telecom operators (separated
by commas without spaces)"*, example `tele2,beeline`). `sync-herosms` already
probed ~8 operators per country and measured each one's stock; it kept only the
maximum, so create-order pinned ONE carrier opportunistically and, the moment it
ran dry, **fell back to the UNPINNED pool — which is overwhelmingly VoIP**
(badoo/us: verizon 14,224 real against textnow's 458,985, ~96% of the country on
one VoIP operator). The fallback was landing users on exactly the stock strict
services reject.

Now the union of real carriers is named at once — mean **3.34 per route**, max 7
(`protonmail/es → lebara,orange,vodafone,movistar,you_mobile,lycamobile,llamaya`).
Better on quality AND availability, so the pin does not need to be strict.
Ordered most-stock-first, so the **head equals the old `herosms_real_operator`**
(verified 432 of 432) and the strict premium / `real_sim_only` pin is unchanged.
Routes probed before the column existed fall back to the single carrier.

**`orders.operator_used` records the carrier that ACTUALLY filled**, from
`getNumberV2`'s `activationOperator` (`"any"` = unpinned; NULL = not recorded,
which is NOT the same thing). This is the control arm the VoIP hypothesis has
never had — `route_physical_count` describes the ROUTE at sync time, not the
NUMBER the user got. Settling query is in migration `20260802090000`; **it must
exclude cancels**, which at a 60%+ cancel rate measure impatience, not delivery.

**Do not read it yet.** HeroSMS has ~41 numbered orders lifetime with ~64%
cancelled, so the non-cancelled cells are 2–6 orders. Needs 2–3 weeks.

Checkout has rendered **Standard / Real SIM** chips at a **+20%** uplift since
`859fa29`, and that UI is in the **1.5** archive — so the choice appears as soon
as 1.5 clears review, with no client change, purely from `premium_credits` being
non-null. `create-order` used to refuse the tier on HeroSMS because there was no
carrier to pin; `routes.herosms_real_operator` now supplies one.

- **Carrier resolution is CHUNKED**, 8 countries per hourly `sync-herosms` run
  with a cursor in `app_config.herosms_operator_cursor` — ~8 operators × 69
  countries is ~550 probes, far past the ~150s edge budget in one go. Candidates
  come from `getOperators` (no api key) minus `app_config.voip_operators`.
- **`herosms_real_count is NULL` means "never probed"; 0 means "probed, none
  there".** That distinction is load-bearing: hiding a VoIP-strict route on
  "not probed yet" briefly took facebook/instagram/whatsapp from 62 hidden
  routes to **185** — punishing the highest-volume services for our own backlog.
- **`real_sim_only` replaces hiding.** A VoIP-rejecting service with a real
  carrier is now sold Real-SIM-only rather than rendered "Unavailable"; the
  Standard chip is omitted and `create-order` refuses `tier: standard` with
  `real_sim_required`. Only a strict service with **no** carrier stays hidden.
- **Two mirrored dead-ends, both closed.** Never send `premium` to a route with
  no premium price (the Standard chip is the only visible escape), and never
  send `standard` to a real-sim-only route (the Standard chip is not rendered
  at all). `effectiveCheckoutPremium` handles both.
- **`defaultPremium` is evidence-driven, not a hardcoded country.**
  `Country.deliversPoorly` mirrors `Service.deliversPoorly` and reads
  `countries.observed_*`, so the US preselection follows measurement and
  corrects itself.
- **The tier promises a NAMED CARRIER, never a rate.** No premium order has ever
  been sold on HeroSMS. Operator classification is by exclusion (an operator
  absent from `voip_operators` is assumed real), which is the weakest part of
  the feature — `orders.route_physical_count` is what will settle whether it
  helps.

### Forcing a REAL SIM: `physic` is a pool, not a synonym for "physical"

`app_config.force_physical_operator` maps country_id → an **ordered list** of
acceptable real carriers. Seeded for `us` with verizon, tmobile, at_t, physic
and ten more. `sync-herosms` probes
`getNumbersStatus?country=<id>&operator=<name>` per operator and records the one
with the most stock on each route (`routes.herosms_real_operator` /
`herosms_real_count`); `create-order` pins that carrier **strictly**, so a dry
pool fails and refunds rather than silently handing back the VoIP number the
setting exists to prevent.

**The trap, and it cost a wrong deploy on 2026-07-31.** HeroSMS lists an
operator literally named `physic`, which reads like "all physical SIMs". It is
not — it is one narrow pool, frequently empty for services that have thousands
of real numbers elsewhere. Measured for badoo/us:

| operator | stock |
|---|---|
| `physic` | **0** |
| at_t | 131 |
| tmobile | 4,179 |
| **verizon** | **14,224** |
| **textnow** (VoIP) | **458,985** |

Pinning `physic` alone hid **71** US routes that were perfectly serviceable.
Note also that `textnow` — a VoIP texting service — is ~96% of the US pool on
its own: the VoIP problem is one operator, not the absence of `physic`.

`getPrices`' `physicalCount` is a THIRD number again and matches neither
(3,829 for badoo/us). Do not treat the three as interchangeable, and do not
infer operator-level stock from `getPrices` — it accepts an `operator` param
and **silently ignores it**. `getNumbersStatus` is the only per-operator view;
a service ABSENT from its result has no stock on that operator, which is
different from a zero.

### Why a service reads "Unavailable" — the price ceiling

⚠️ **BOTH price-based hides were REMOVED on 2026-08-04 (owner decision).**
`MAX_WHOLESALE_CENTS` is **100_000** in all four syncs and `blocked_routes` is
**`[]`**. The history below is kept because both levers still exist and one
number restores either.

*What the ceiling was for:* it hid any route whose wholesale exceeded a cap set
at **150 credits × that provider's divisor** — the largest credit pack — so the
rule was *hide only what a user literally cannot buy in one purchase*. A flat
$4.00 version until 2026-07-27 hid **WhatsApp across nearly every Western
market** (40 of 69 routes, UK/France/Netherlands/Poland at $5–6 wholesale) and
read as "the app is broken"; raising it to the pack size unhid 1,503 routes.

*What removing it actually did:* **+122 active routes (5,905 → 6,027)**, of
which **124 now price above 150 credits**, max **541**. Far less than the ~1,345
a naive `cost > ceiling` count suggests — most of those were **also** hidden for
having no stock, and a no-stock route stays hidden regardless of price. Count
`status='hidden'` reasons in order; they overlap.

🔴 **Those 124 routes are VISIBLE BUT NOT ORDERABLE at current balances.**
`create-order` refuses before charging when the provider balance is under the
order's own `maxCostUsd`. Measured 2026-08-04: 5sim's 7 need **$14.68–21.79**
against a $9.37 balance, HeroSMS's 10 need $13.00–40.68 against $9.62, SMSPVA's
107 need $24.00–60.00 against $5.26 — **zero orderable on any provider**. No
money is taken (the guard is pre-charge) but the user gets the
`provider_unreachable` copy, which does not say "we are out of float". Topping
up is what makes this change do anything.

*The blocklist* was a manual kill-list that won at any price: `whatsapp|us`,
`google|us`, `openai|us`, `twitter-x|us`, hidden because those numbers do not
work rather than because they cost too much. Cleared to `[]` because their whole
record — 8 orders, 0 codes — was 12–13 July on **SMSPVA and SMSPool**, providers
we have retired, and this repo's own rule says such evidence does not carry to
the provider serving the next order. They are re-opened for measurement under
5sim. **If they still deliver zero, put them back.**

So when checking why something is unavailable, look in this order:
`blocked_routes` (now empty), then cost vs `MAX_WHOLESALE_CENTS` (now
non-binding), then **no stock** — which after these two changes is the reason
for essentially every hidden route.

## Non-obvious gotchas (real bugs we've hit, do not re-introduce)

- **SMSPVA base URL is `https://api.smspva.com`**, NOT `smspva.com` (the docs spec lies — the marketing site 404s every `/activation/*` path).
- **Edge functions die at ~150s wall clock** — a synchronous long request gets IDLE_TIMEOUT, and `EdgeRuntime.waitUntil` background tasks are killed at the same mark (both verified live 2026-07-21). Any job longer than ~2 minutes must be cursor-chunked across multiple invocations (see `sync-smspva-operators`: 12 countries/run, pg_cron fans 6 slots across a nightly maintenance window). Its public docs describe a *different, older* `priemnik.php` API; the v2 REST surface we use is undocumented but real.
- **SMSPVA's official 174-page spec is NOT in this repo** (removed 2026-08-04 when the repo went public — it is the vendor's copyrighted document, not ours to redistribute). Keep a local copy at `docs/apidocs.pdf`, which is gitignored; obtain it from SMSPVA. Elsewhere this file has called that API "undocumented". Its status codes are load-bearing and `poll()` used to discard them: **407 = "we received the SMS but your balance is not enough to pay for it"**, so the code is being withheld, not missing. It now pages loudly on 407 and keeps the order alive (a top-up inside the window rescues the code), closes on 406/410 (order invalid/closed) via the atomic provider-close path, and logs 411 (karma/ratelimit). Treating 407 as "still waiting" polls to expiry and is indistinguishable from a stockout — which also corrupts the delivery evidence.
- **`create-order` refuses BEFORE charging when the provider is broke.** It reads `app_config.<provider>_health`, and if that reading is under 5 minutes old and `balance_usd` is below this order's own `maxCostUsd`, it refuses up front rather than charging and refunding. It fails **OPEN** on stale or missing data, and maps to the already-shipped `provider_unreachable` copy. ⚠️ This is why a missing `<provider>_health` row is dangerous: the guard silently stops guarding. `create-esim-order` gained the same guard on 2026-08-10 (reads `esimaccess_health`); the e-mail order path still charges-then-refunds — extend the guard if it grows volume.
- **Every SMSPVA response is an envelope: `{statusCode, data}`.** The value lives at `r.data.x`, never `r.x`. Reading the wrong level yields `NaN`/`undefined` and, on the balance path, wrote nothing at all — which looks *identical to a healthy provider*. Use `isOk(r)` before touching `r.data`.
- **The Apple receipt verifier must chain to Apple's PINNED root.** `_shared/iap.ts` once took the certificate out of the attacker-supplied JWS header and verified the signature against that same certificate — circular, so anyone with a free Sign-in-with-Apple account could self-sign a payload for `credits.150` and mint credits forever. It now walks every hop of `x5c` and requires termination at **Apple Root CA - G3, matched by SHA-256 thumbprint** (pinning by subject name is defeated by a self-signed cert named "Apple Root CA - G3"), plus Apple's receipt-signing OID `1.2.840.113635.100.6.11.1` on the leaf, and validity checked at `signedDate` not `now()`. **Pin the ROOT ONLY** — the leaf expires 2027-10-13 and Apple rotates intermediates routinely, so pinning anything lower turns a normal rotation into a total purchase outage. No OCSP: a live round-trip to Apple inside checkout would fail every legitimate purchase during an Apple outage.
- **Credits are granted only when `tx.environment === "Production"`.** Sandbox/Xcode receipts are genuine Apple-signed transactions that cost **$0** — any Apple ID can switch to a Sandbox account in Settings and "buy" packs free (this already happened: receipt id 21 credited a real user 12 credits 39s after signup). Non-production receipts are still persisted for the audit trail and still return `ok:true` so the client calls `tx.finish()` and StoreKit stops redelivering — they just move no balance and pay no referral reward. **This gate is worthless without the chain verification above**, because `environment` is just another field a forger sets to `"Production"`.
- **`order_status` cannot grow a value without shipping the app first.** iOS `OrderStatus` (`Components/Pills.swift`) is a plain `String` enum with **no unknown case**, so a status it doesn't recognise throws on decode and breaks the Orders tab for everyone on the released build. This is why `begin_order` writes a pre-reservation row as ordinary `'waiting'` with a null `smspva_id` instead of adding a `'pending'` state.
- **Charge and order row must be written together.** `create-order` used to charge and only insert the row after a provider reservation succeeded, so every failure left a spend+refund pointing at nothing: **258 spends vs 126 orders — 51% of paid attempts invisible**, and the real failure rate unmeasurable. `begin_order()` now does dedupe + insert + charge in one transaction under a per-user advisory lock (the old dedupe `SELECT`ed ~120 lines before the `INSERT`, with a multi-second provider call between, so two concurrent requests both passed it and both charged). A stranded row self-heals: the poller skips it for polling (`smspva_id is not null`) but the expiry sweep still closes and refunds it.
- **Never write a status transition without an atomic claim.** Every `orders` status write is `.eq("status","waiting")` + row-count check. `check-order`'s `received` branch was the one exception and could overwrite a terminal state the expiry cron had already set — handing a user a working code they'd *already been refunded for*.
- **A status claim and its refund must be ONE transaction, never two round-trips.** Where they are split, a worker killed in between leaves a TERMINAL row with the charge never returned — and the expiry sweeps only select `status='waiting'`, so nothing ever revisits it. No timeout value fixes this; a TypeScript rollback cannot either, because the process is gone. Seven paths had it wrong and were fixed one at a time across 2026-07-31 and 08-02 (`expire_order_claim`, `expire_order_early_claim`, `fail_esim_order_claim`, `close_email_order_claim`). ⚠️ **This entry then said "if you add an eighth close path, it goes through a claim function" while TWO existing paths still did not** — `cancel-order` and `create-order`'s `failOrder`, i.e. the busiest close path in the product (`margin_too_low`, stockouts, provider faults and `order_persist_failed` all land there). Both carried the TypeScript rollback this very rule says cannot work. Closed 2026-08-06 with **`cancel_order_claim(p_order, p_late_watch_until)`** (`20260806140000`); it had never fired — a query for terminal charged orders with no matching refund returns zero — but the window is real and the failure is silent and permanent. **The lesson is about the rule, not the bug: a written invariant is not an enforced one. Grep for violators when you write one down.**
- 🔴 **`on conflict (version) do nothing` WILL SILENTLY SWALLOW YOUR MIGRATION RECORD when two sessions pick the same timestamp.** Hit for real on 2026-08-18: a migration was applied with `db query --file`, then recorded with the documented `insert … on conflict (version) do nothing` — and `20260818130000` was ALREADY TAKEN by `iap_refund_revocation` from a parallel session. The insert did nothing, the SQL stayed applied, and `schema_migrations` had no trace of it. Two different migrations then claimed one version, one of them only on disk. **After recording a migration, SELECT it back by name**, not by assuming the insert landed — and pick a version by reading `select max(version) from supabase_migrations.schema_migrations` rather than from the clock, because more than one session works on this repo per day.
- 🔴 **`subscriptionFamily(productId)` must resolve to `"line"` or `"mail"`, never treated as a single yes/no.** `iap-verify` asks it "is this NOT a credit pack?" so a subscription renewal doesn't 400 and page the owner as `unknown_product` — mail products MUST be included in that check (`isSubscriptionProduct`). `apple-notifications` asks the SAME shape of question but means the opposite thing by it: every branch after its guard `UPDATE`s `line_subscriptions` and drives the phone-number lapse machine, so a mail product MUST be excluded there, dispatched instead to the mail-only path — or a cancelled $2.99 mail plan would suspend and release somebody's rented $9.99 phone number. A future subscription product (a third family) that is added to `isSubscriptionProduct`'s allowlist but not to `subscriptionFamily`'s dispatch is a family neither branch recognises correctly. Add a new product to `LINE_SUBSCRIPTION_PRODUCT_IDS` or `MAIL_SUBSCRIPTION_PRODUCT_IDS` in `_shared/iap.ts` — never treat `isSubscriptionProduct` as sufficient on its own for anything that acts on the subscription rather than merely refusing to 400 it.

- **`apply_migration` (MCP) mints its own version number and does NOT write a repo file.** Three migrations performing an entire provider cutover existed only in the live DB; a fresh `supabase db push` would have come up SMSPool-primary with the wrong crons scheduled. After any `apply_migration`, immediately write `supabase/migrations/<live-version>_<name>.sql` with the same SQL. Recover forgotten ones from `supabase_migrations.schema_migrations.statements`.
- **An unqualified `UPDATE` inside a SECURITY DEFINER function fails when called
  over RPC — `UPDATE requires a WHERE clause`.** Supabase's safeupdate guard
  applies to the roles edge functions call through, so a function that is fine
  in the SQL editor throws the moment `sb.rpc()` invokes it. This hid for a day
  inside `refresh_arrival_timing`, whose "stamp the global band on every row"
  UPDATE had no WHERE — the function looked healthy because nothing ever called
  it. Add a semantically-empty predicate (`where id is not null`) to any
  deliberate table-wide UPDATE, and check `maintenance.*` in the `sync-prices`
  response for `"error: ..."` strings after adding a maintenance job — each one
  is wrapped in try/catch, so a broken job returns 200 with the error nested in
  the body rather than failing the run.
- **`supabase db push` is BROKEN and cannot be used (verified 2026-07-25).** It aborts with *"Remote migration versions not found in local migrations directory"* listing **43** remote versions (20260716183819 … 20260721125706) that have no local file — the accumulated debt of the `apply_migration` gotcha above. **Do NOT run the `supabase migration repair --status reverted <43 versions>` the CLI suggests**: those migrations really are applied, and marking them reverted invites a later push to re-run them. To ship one migration today: write the file, apply it with `supabase db query --linked --file <path>`, then record it yourself:
  ```sql
  insert into supabase_migrations.schema_migrations (version, name)
  values ('<version>','<name>') on conflict (version) do nothing;
  ```
  (Note `db query` parses a leading `--` SQL comment as a CLI flag — always use `--file`, never inline SQL that starts with a comment.) Properly repairing the 43 is a separate, careful job: back-fill each missing file from `schema_migrations.statements` rather than reverting anything.
- **Clients get `UPDATE` on `profiles.display_name` ONLY.** RLS is row-level and cannot restrict columns, so a table-wide UPDATE grant let any user PATCH their own `referred_by` / `referral_rewarded_at` — pointing the referral at themselves and nulling the payout flag to farm 5 credits per purchase forever. The `SECURITY DEFINER` guards *read* those columns to decide, so writable inputs made them decorative.
- **An order refused for insufficient provider float PAGES you** (`create-order`'s `alertLowBalanceBlock`, `app_config.low_balance_block`). This is NOT the balance-tier ladder in `poll-active-orders`: that fires on `[37.50, 22.50, 11.25, 7.50]` whether or not anyone is buying, and since the 2026-08-04 ceiling removal it can miss this case completely — a route may need **$60** of float while the lowest rung is $7.50, so every tier reads healthy while real customers are turned away. The page carries the **shortfall** (not just the balance), the route, and a refusal count since the last alert, and states the customer was NOT charged — the shipped copy says `provider_unreachable`, which does not mean "we are out of float". ⚠️ The eSIM and e-mail paths have **no pre-charge guard at all** and still charge-then-refund on a dry balance; they would need the guard before they could page.
- **Both provider balances are monitored**, written every minute by `poll-active-orders` into `app_config.smspva_health` / `smspool_health`, and reported by the bot labelled with what they fund. A missing reading renders as "no reading", never omitted — an absent line reads as healthy, which is exactly the failure that hid SMSPVA having no monitoring at all while it served 100% of SMS.
- **PostgREST `max_rows` is now `60000`** (`alter role authenticator set pgrst.db_max_rows`). The catalog is ~18.5k routes and moved 6,962 → 16,320 → 18,492 in 36h purely from provider changes. Crossing the cap makes PostgREST **truncate silently** — HTTP 206, no error, the app just gets fewer routes and every missing one renders "Unavailable" or keeps a stale price. That is indistinguishable from "the prices are wrong" from the phone. Keep large headroom; it is nearly free.
- **CatalogAPI fetches only routes where `retail_credits IS NOT NULL OR status != 'active'`**. After sync-prices, all routes have a price → query effectively returns everything. The filter exists so a fresh project without sync data doesn't pull empty rows.
- **Cover/sheet content does NOT inherit `@Observable` env objects from the presenter.** Always wrap sheet/cover content with the `EnvBundle` modifier in `ContentView`.
- **The checkout draft must never be read outside the checkout flow — use
  `AppState.configuringService` / `configuringCountry`, never
  `checkoutService ?? lastService`.** `startCheckout` wrote the draft and
  nothing cleared it, while every picker read it with no `flow` check. So after
  a single visit to checkout — tapping "order again" on a history row is
  enough — the sheets opened from **Home** priced everything for the *last
  checked-out* service: Home read "Deliveroo · Kyrgyzstan · **4 cr**" while the
  country sheet opened from that same screen priced every row for Leboncoin and
  showed Kyrgyzstan at **60 cr** (2026-07-25, reproduced from screenshots and
  confirmed against `routes` — Leboncoin was the *unique* service in the catalog
  matching the sheet's exact price vector). It was never just cosmetic: the same
  wrong service drove **availability** (countries rendering "Unavailable" that
  were bookable for the selected service), the default **"Best success"**
  ranking — so the steering steered on the wrong service — and
  `creditsShortfall`, which preselected a credit pack sized for the stale route.
  Fixed on both sides: reads go through the two accessors, and `flow`'s `didSet`
  clears the draft on every transition out of `.checkout` (centrally, because
  `flow` is assigned from a dozen sites and `fullScreenCover(item:)` also writes
  `nil` on interactive dismiss). The general rule: **when a write path branches
  on `flow` but the matching read path doesn't, the two disagree the moment the
  flow ends.**
- **Which PRODUCT the user is buying is declared, never inferred —
  `AppState.PurchaseIntent`.** The same lesson as the checkout-draft bug above,
  one product line later. `creditsShortfall` used to branch on
  `if let plan = checkoutEsimPlan` with no `flow` check — deliberately, because
  the credits pill in the eSIM tab opens the ROOT sheet with `flow == nil`. But
  `flow`'s `didSet` cleared the SMS draft and **never cleared `checkoutEsimPlan`**,
  which was assigned in exactly one place and set to nil in none. So after a
  single visit to an eSIM checkout, every later "how many credits do you need?"
  answered for that plan — for the rest of the session, on every screen,
  including SMS checkout. `CreditsSheet` is product-agnostic and receives only
  `needed:`, so nothing could notice. Adding a third product to that if-chain
  would have multiplied the bug. `intent` is now set at each entry point
  (`startCheckout` / `startEsimCheckout` / the email paths) and cleared centrally
  in `flow`'s `didSet` alongside `checkoutEsimPlan`.
- **In email mode the SMS route price and delivery record must NOT render.**
  `ServiceSheet` fixes the country and varies the service, so in email mode it
  was quoting `cost(for:country:)` — an SMS price, meaningless when the email
  price comes from the DOMAIN chosen next — plus the measured arrival band and
  the per-route delivery record, which describe phone numbers on a route. Same
  rule as everywhere else: another product's evidence is not this product's. The
  Home hero has the same guard (no country, no dial code, no metrics row) and the
  Affordable toggle is inert there, since it filters on a price that does not
  apply and would hide most of the catalog.
- **`tint_hex`, not `tint`** — Service column is `tint_hex` (snake) → `tintHex` (Swift). Same casing rule for every Service/Country/Route field. Don't reintroduce shorter names.
- **Cron-secret auth reads from `Deno.env.get("CRON_SECRET")`**, not from `vault.decrypted_secrets`. The vault schema isn't reachable through PostgREST — the function would silently fail. Both `poll-active-orders` and `sync-prices` rely on the env var being mirrored to the vault entry. **CRON_SECRET therefore lives in TWO stores** (edge secrets + vault `cron_secret`, read by `private_cron_secret()`); rotating one without the other 401s every relayed function at once — including telegram-notify, i.e. the alert channel. The watchdog's `relay-http` check catches the 401s within ~25 min, but rotate both together.
- 🔴 **A GUARD READING A CONFIG KEY NOBODY WRITES FAILS OPEN AND SILENT — AND IT PINNED THE WATCHDOG RED FOR THREE DAYS.** `run_watchdog_core` skips its two SMSPVA freshness checks when `app_config.smspva_retired` says `retired`. `20260817100000_retire_smspva.sql` retired the provider and unscheduled both cron jobs but **never inserted the key**, so both checks kept measuring cursors that can never move again. Nothing reports "this key does not exist"; the `coalesce` even reads as deliberate defensive style. Two consequences, both worse than the noise: the genuine `5sim-float` page arrived buried among two permanent false positives, and **the "✅ recovered" transition can never fire while `failing` cannot return to empty** — retiring the one signal that says an outage ENDED. It also structurally suppressed a winback cohort (`claimSafe = balUsd >= 7.5 && failing === 0 && wdFresh` in `winback/index.ts:151`), the **sixth** time `stranded_credit_candidates` has been closed by an invisible gate. Written in `20260820100000`. **When you retire a subsystem, write its flag in the SAME migration that unschedules its jobs**, and after writing any guard that reads a key, `select` the key.
- **The watchdog is plain SQL — keep it that way.** `run_watchdog()` (pg_cron `*/10`, migration `20260722050000`) checks job freshness (poller heartbeat, `routes`/`esim_plans.last_checked_at`, digest stamp, sync cursors via `app_config.updated_at` — maintained by the `app_config_touch` trigger, so cursor upserts don't need to set it) plus any non-2xx row in `net._http_response`, and writes its verdict to `app_config.'watchdog'`. `telegram-notify` (minutely) turns that into pages (6h re-alert, ✅ on recovery); `/balance` shows the verdict too. It deliberately uses **no edge function, no CRON_SECRET, no HTTP** so it still evaluates when the whole edge/secret layer is broken. If you add a scheduled job, give it a freshness signal and a check here. Residual blind spot: telegram-notify's own death = digest silence >7h (documented in `docs/autopilot-runbook.md`).
- **IAP environment check constraint must allow `'Xcode'`** for local StoreKit testing alongside `'Sandbox'`/`'Production'`. See migration `..._iap_allow_xcode_env.sql`.
- **A status string written from TS is NOT checked against the enum — and the error is discarded.** `create-esim-order`'s failure path wrote `status: "canceled"`, which is a member of `order_status` but **not** of `esim_status` (`provisioning, installed, active, depleted, expired, refunded, failed`). PostgREST rejected the UPDATE with 22P02, the code did `const { data: claimed } = await ...` without destructuring `error`, so `claimed` came back empty and the function **returned without refunding**. Every failed eSIM purchase charged the user and silently kept the money. When you write a status literal from an edge function, check it against `pg_enum` — the two enums share several names and differ in exactly the ones that matter.
- **`supabase-js` RETURNS errors, it does not throw.** Every `await sb.rpc("wallet_credit", …)` that discards `{ error }` is a silent money bug: `wallet_credit` raises on a non-positive amount and on a missing wallet row, so the status claim commits, the balance never moves, and the user gets a push saying "N credits refunded". Four sites had this. Destructure the error at every money call.
- **`revoke execute … from anon, authenticated` IS A NO-OP while PUBLIC holds the grant.** `CREATE FUNCTION` grants EXECUTE to PUBLIC by default, and anon/authenticated are members of PUBLIC — so the revoke line present on ~35 migrations changes nothing on its own, and the function stays callable at `/rest/v1/rpc/<name>`. Read the ACL, not the migration: a secured function is `postgres=X/postgres | service_role=X/postgres`, a leaking one has a **leading `=X/postgres`** (empty grantee = PUBLIC). Caught 2026-07-27 when `revenue_snapshot` — the first function created after the default-privileges hardening — shipped world-callable *with* its revoke line, exposing gross revenue, wholesale cost and profit to anyone holding the publishable key (SECURITY DEFINER, so RLS was no help). `20260727211000` revoked the *default* for anon/authenticated but **not for PUBLIC**, so every future function kept arriving public. Fixed in `20260727240000`: `alter default privileges in schema public revoke execute on functions from public`, plus explicit `from public, anon, authenticated` on the four affected functions. Assert with `has_function_privilege('anon', p.oid,'execute')` — it must be **0 rows** across `pg_proc` in `public`; a passing `revoke` statement proves nothing.
- **`ALTER DEFAULT PRIVILEGES` grants `anon`/`authenticated` rights on every FUTURE object.** Until 2026-07-27 that was `arwdDxtm` on future tables and `EXECUTE` on future functions — so any new table missing `enable row level security` would have been world-**writable** at `/rest/v1/<table>`, and any new SECURITY DEFINER function missing its revoke callable at `/rest/v1/rpc/<name>`. That is how `run_watchdog` became public. The postgres-owned defaults are now revoked (SELECT retained; RLS still governs rows); **the `supabase_admin` half is NOT applied** — it needs membership in that role, which the CLI's postgres connection lacks. Statements are in `20260727211000_default_privileges.sql`. Note this is a backstop, not a licence to skip the explicit `revoke execute` on every new function.
- **A one-line refactor that changes a watchdog threshold is a monitoring outage.** Rebuilding `run_watchdog` for unrelated coverage silently narrowed the delivery check from 24h/≥10 to 6h/≥8 **and deleted its second branch** (≥20 conclusive at <10%). Measured: the max conclusive orders in ANY 6h window over 30 days is 8, against a gate of 8 — the check became effectively unreachable, leaving zero delivery-outcome coverage. When you re-create a function from `pg_get_functiondef`, diff it against the prior definition clause by clause; the dump is also **truncated** by most tooling, which is how a nonexistent `url` column on `net._http_response` got invented in the same rewrite.
- **A constant duplicated across files WILL drift.** `MAX_WHOLESALE_CENTS` lives in three sync functions (and as `MAX_ORDER_COST_USD` in `poll-active-orders`, and as `LOW_BALANCE_USD` in `_shared/opsFormat.ts`). Changing it in one place on 2026-07-27 stripped 1,432 routes of their carrier pin and premium price, and left the digest warning at $20 while the pager fired at $37.50. Same for `CREDIT_DIVISOR` (the SMSPVA 0.05 is **two** copies — `sync-prices` and `sync-smspva-operators` — and `sync-herosms` carries a deliberately DIFFERENT 0.025, so "consolidating" the three into one constant would silently reprice a whole provider) and `ESIM_MARGIN`/`CREDIT_VALUE_USD` (two each). `MAX_WHOLESALE_CENTS`'s three syncs are now `sync-prices`, `sync-smspva-operators` and `sync-herosms`. Change them in one commit or consolidate them into `_shared/`.
- **Deleting an IAP receipt to force StoreKit redelivery can eat the payment.** `iap-verify` used to delete the row when `wallet_credit` failed, assuming StoreKit would retry. But the client runs **two** paths into that endpoint (`Transaction.updates` and the `Transaction.unfinished` sweep), so a concurrent duplicate may already have been answered `already_credited` and called `finish()` — retiring the transaction forever. It now zeroes `granted_credits` (keeping both the audit trail and the replay guard), and the duplicate branch refuses to confirm a receipt that has no matching `wallet_transactions` row.
- **EVERY grant is farmable through account deletion unless it is tombstoned OUTSIDE the `auth.users` cascade.** This is the single most repeated money bug in this codebase — it has now been found **four** times, once per grant. Everything user-scoped cascades, so delete → sign in again erases our only record and mints the grant afresh. Apple *mandates* the Delete Account button, so this is not an edge case. The four grants and their tombstones: **signup credits** → `signup_grants` (hash of the email); **referral +2** → `signup_grants.referral_redeemed_at` (same key); **IAP purchases** → `public.iap_grants` (keyed on Apple's `transaction_id`); **the temp-e-mail lifetime free address** → `public.email_free_grants` (same two email hashes, added 2026-08-26 — see the temp-e-mail subscription section). ⚠️ **The fourth is the proof the rule needs restating rather than trusting: it is not denominated in credits, so nobody read it as a "grant", and it shipped counting `email_orders` rows that cascade — farmed 55 times from one identity before it was caught.** A grant is anything we hand out once per person. Each tombstone table must have **no foreign key to `auth.users`** — a reference there is precisely what deletes the row with the account. The email hash works because Apple's private-relay address is stable per (user, app), so it survives deletion while storing no address; all four fail **open** on a null email, because a missed grant on a real signup costs more than a rare duplicate. **If you add a fifth grant, it needs a tombstone in the same commit.**

  ⚠️ **THAT RELAY-STABILITY ARGUMENT IS NO LONGER THE WHOLE GUARANTEE (2026-08-18).** Email + password signup means the key can be an address the USER picks, which costs nothing to re-roll. Two things now hold it up, and neither is sufficient alone: `signup_grants.email_hash_norm` (md5 of `public.normalize_email`, which strips plus-tags everywhere and dots on gmail only) and the fact that the grant is paid on **confirmation** rather than at INSERT, so the mailbox must actually receive mail. **Both keys are checked and written; the legacy `email_hash` stays the primary key** because 8 of the 517 tombstones belong to deleted accounts whose address is unrecoverable — rewriting the key would have dropped exactly the rows doing the most work. State the residual honestly: a user with ten real mailboxes still gets ten grants. That is a cost floor, and it is LOWER than Apple's — price the grant accordingly (it is 0 today). See `20260818160000_email_signup_normalized_tombstone.sql` and `scripts/verify-signup-grant.sql`.
- **APNs `aps-environment` is `production`** in the entitlements file (flipped for archiving; set `APNS_ENV=production` secret to match). Flip back to `development` if you need to test push against a dev-token build from Xcode.
- **`Secrets.swift` is gitignored.** Template in `supabase/README.md`. Just `supabaseURL` + `supabaseAnonKey`. The publishable key (`sb_publishable_*`) is fine in client code — it's the new name for the anon key.
- **Logo loading cascades** in `ServiceLogo`: DuckDuckGo ip3 (`icons.duckduckgo.com/ip3/<domain>.ico`) → Google FaviconV2 → SF Symbol on tinted background. URLCache caches across launches. **Clearbit (`logo.clearbit.com`) was removed** — HubSpot sunset the free Logo API on 2025-12-01 and its host no longer resolves; leaving it as source #1 made every logo eat a DNS failure before falling through. Do not re-add it.
- **Logos + flags are bundled** (`VirtualSIM/BundledLogos/<domain>.png`, `VirtualSIM/BundledFlags/<code>.png`). `ServiceLogo`/`FlagImage`/`FlagCircle` render the bundled PNG **first** (via `BundledImageStore.shared`) and only fall back to the network cascade above for catalog entries not yet bundled. The Xcode file-system-synchronized group **flattens** these into the bundle root, so lookup is by flat filename (`Bundle.main.url(forResource: "<key>.png", withExtension: nil)`) — do NOT expect a `BundledLogos/` subdirectory at runtime. Logo key = `Service.domain`; flag key = `Country.flagImageCode` (`uk`→`gb`). After the catalog grows, regenerate + commit with `scripts/fetch-bundled-assets.sh --refresh`, then ship an app update; new services/countries work via the network fallback in the meantime.
- **Apple Sign-In is iOS-native flow** — no JWT secret needed in Supabase (the apple provider config). The dashboard's secret/services-id fields stay blank. **Since 2026-08-18 it is no longer the ONLY door**: `AuthFlowScreen` also offers email + password (`AuthWelcomeScreen` → sign-in / sign-up / 6-digit confirmation / password reset). 🔴 **It cannot reach a real user until custom SMTP is configured** — Supabase's built-in mailer is rate-limited to a couple of messages an hour and sends from their domain. **`vsmsapp.com` was bought for this on 2026-08-18**; the remaining work is Resend + DNS + the SMTP and template settings, all of it dashboard-side and written up in `docs/email-auth-setup.md`. Send from `mail.vsmsapp.com`, never the apex — the apex is where the legal pages the App Store points at will live, and sending reputation is per domain. The flow is deliberately **code-based, never link-based**: nothing in the app handles the `relay://auth` scheme `config.toml` declares, and mail scanners pre-fetch links and burn single-use tokens. Verified live 2026-08-18: `invalid_credentials` is a 400, **`otp_expired` is a 403** (the status ladder used to answer that with "Please sign in again"), `weak_password` a 422 whose server minimum is **6** (the client asks 8), `/auth/v1/recover` answers **200 for an unknown address** and `/auth/v1/resend` exists.
- **Never present seed data as measured fact.** `Service.successRate` is seed data (86–99% across all 268 services, avg 91%) and `Service.swift` says so explicitly. Show only `AppState.successRate(for:country:)` / `deliveryOdds` / `DeliveryNotice`, which are gated on real observed samples, and show **nothing** when there's no measurement. `WaitingScreen` was the last violator — it promised ~91% right after payment on clusters that actually measure ~9%. Same rule for eSIM coverage: the parser returns `null` rather than guess, because a wrong coverage claim is worse than none since the user acts on it.
- **Review prompt must stay incentive-free (App Store 5.6.4).** `OtpScreen` calls Apple's native `@Environment(\.requestReview)` (needs `import StoreKit`) on code delivery, gated by `AppState.shouldRequestReview(forOrderId:)` — fires from the user's FIRST successful code (lowered from the 2nd on 2026-07-31: only 7 of 20 code-receiving users ever reached two codes, so the 2nd-code gate excluded most of the eligible pool), at most once per app version, de-duped per order. **Never** tie credits/rewards to leaving a review, and **never** build a custom review UI that deep-links to the App Store page — both are rejectable. A no-strings welcome/bonus credit is fine as long as it isn't conditioned on a review.

- **Simulator builds WORK again (re-verified 2026-07-25) — the old "iOS 26.5 is
  not installed" note below is obsolete.** `xcrun simctl list runtimes` now shows
  **both** iOS 26.5 (23F77) and 27.0, so the SDK (26.5) and a runtime finally
  match and there are eligible destinations. This is confirmed, not assumed:
  ```bash
  xcodebuild -project VirtualSIM.xcodeproj -scheme VirtualSIM \
    -configuration Debug -sdk iphonesimulator \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' build
  # => ** BUILD SUCCEEDED **
  ```
  This is now the ONLY check — `swiftc -typecheck` was retired on 2026-08-06 —
  and it was always the better one: it catches resource/Info.plist/asset
  problems type-checking cannot. *Historical
  cause, kept because it will recur on the next Xcode update:* Xcode will not
  offer a simulator destination whose runtime is NEWER than its SDK, so when
  only runtime 27.0 was installed against SDK 26.5 there were **no** eligible
  destinations, and `-downloadPlatform iOS -buildVersion 26.5` answered
  `iOS 26.5 is not available for download`. If that returns, the fix is to match
  SDK to an installed runtime (install the newer Xcode), not to chase the old
  runtime. **Archiving for the App Store is still gated separately** by the
  beta-macOS `BuildMachineOSBuild` patch under "Release prep".
- **`INFOPLIST_KEY_<name>` SILENTLY DOES NOTHING for keys outside Xcode's
  allowlist.** `INFOPLIST_KEY_UIBackgroundModes = "audio voip"` is accepted,
  shows up in `xcodebuild -showBuildSettings`, and never reaches the generated
  Info.plist — no warning, build succeeds, VoIP pushes are then never
  delivered. The real keys live in **`VirtualSIM-Info.plist` at the repo root**
  (`INFOPLIST_FILE`, with `GENERATE_INFOPLIST_FILE` still YES so Xcode merges
  the generated ones in). It must stay OUT of `VirtualSIM/`, which is a
  synchronized root group and would also copy it as a resource — *"Multiple
  commands produce …/VirtualSIM.app/Info.plist"*. **Assert against the built
  plist, never the build setting**: `plutil -p "$APP/Info.plist"`. Full account
  in the calling section.
- **The repo lives at `/Users/adyl/Desktop/IOS_APPS/VirtualSIM`.** It MOVED from
  `~/Desktop/VirtualSIM`, which no longer exists — so any `cp` from the old path
  fails silently-ish and the instruction below used to point at nothing. Stale
  worktrees under the old path still show in `git worktree list` marked
  `prunable`; ignore them.
- **A git worktree cannot build or type-check until you copy `Secrets.swift` in.**
  `VirtualSIM/Networking/Secrets.swift` is gitignored, so a fresh worktree lacks
  it and both `swiftc -typecheck` and `xcodebuild` fail with `cannot find
  'Secrets' in scope` — which looks like your edit broke the build and is not.
  `cp /Users/adyl/Desktop/IOS_APPS/VirtualSIM/VirtualSIM/Networking/Secrets.swift
  VirtualSIM/Networking/Secrets.swift` first; it stays ignored, so it will not be
  committed. (This is also why `find VirtualSIM -name '*.swift' | wc -l` reads one fewer
  in a bare worktree — 115 vs 116 as of 2026-08-06.)
- **`isOk()` from `_shared/smspva.ts` dereferences its argument and callers pass
  it `null`.** `providers.ts` does `smsGetBalance().catch(() => null)` and then
  `isOk(before)` / `isOk(after)`; `isOk` reads `r.statusCode`, so a thrown
  balance call makes it a `TypeError` **after the number is already reserved** —
  charge, refund, and forfeited wholesale on a number we abandon. Live on the
  SMSPVA path until fixed. Caught by `deno check` 2026-07-30, present since
  `91dc756`; **FIXED** (`before && isOk(before)`, deployed 2026-07-31 and
  re-verified in code 2026-08-02 — an earlier version of this bullet said
  "not yet fixed" long after it was).
  (`deno check` also reports three `Cannot find name 'EdgeRuntime'` — those are
  a Supabase runtime global Deno does not type, and are benign.)
- **Xcode rewrites `Localizable.xcstrings` in the PRIMARY checkout while you
  work in a worktree**, which blocks the merge back with *"Your local changes
  would be overwritten"*. It is the string extractor, not human edits: it adds
  `"extractionState": "stale"` to strings your branch has not merged yet and
  drops others. Diff it before discarding — on 2026-07-30 it contained **zero**
  translations the branch lacked — then `git checkout --` it and merge.
- **A git worktree is also not linked to Supabase.** `supabase/.temp/` is
  gitignored, so `supabase db query --linked` in a worktree dies with
  *"Cannot find project ref. Have you run supabase link?"* — which looks like a
  broken CLI or expired auth and is neither. Copy the link state in:
  `cp -R /Users/adyl/Desktop/IOS_APPS/VirtualSIM/supabase/.temp supabase/.temp`. It stays
  ignored. Do **not** re-run `supabase link` in a worktree.
- **Merging a worktree branch into `main` usually needs a real merge, not a
  fast-forward.** `main`'s tip is typically one of the `Merge: …` commits from a
  previous round, so a branch cut from the pre-merge tip has genuinely diverged
  and `git merge --ff-only` aborts with *"Not possible to fast-forward"*. That is
  not a sign the branch is broken — check with
  `git merge-base --is-ancestor main <branch>` and then merge with `--no-ff`.

## Provider switch checklist

All FOUR switches broke something that threw no error. If you change the
SMS provider again, walk this list:

0. **Record ownership in `routes.provider` and make the router read it FIRST.**
   Added by the 5sim cutover. Once a route can carry codes for two providers at
   once, code-presence routing silently sends the order to whichever adapter is
   checked first — which may not be the one that PRICED the row. That is a
   margin gate reading one provider's cost against another's price list: on the
   HeroSMS-era premium path this refused **3,064 of 4,080 routes** with
   `margin_too_low`, charging and refunding every time. `providerOrder()` now
   resolves `owner` before falling back to codes.
1. **Update `providerOrder()`** in `_shared/providers.ts` — the only routing truth.
2. **Re-home `routes`.** One row per (service,country) with `provider` as a column. Hand every combo the new provider can serve back to it, or `sync-prices` will skip those rows and never reprice them — that silently killed leboncoin/nl and /ro, the two best-delivering routes in the app.
3. **Check the crons.** Unscheduling a provider's sync also kills anything else living inside that function. Four maintenance jobs (observed success, service visibility, delivery evidence, catalog ranking) died this way and froze the "self-correcting" catalog for hours with no signal. They now live in `sync-prices` and resolve the provider via `active_sms_provider()`.
4. **Re-price before re-enabling.** A provider switch changes wholesale costs; run `sync-prices` and confirm `count(*) where smoothed_cost_cents < last_cost_cents` is **0** before trusting the catalog.
5. **Classify the new provider's errors.** `create-order` branches on `errorType`, not on the raw error string. If the adapter doesn't set it, *every* failure — dead account, bad key, rate limit, genuine stockout — collapses into "no_numbers_available", so users are told to "try another country" while the whole product is down, and the escalation `console.error` (also gated on `errorType`) never fires.
6. **Point balance monitoring at it** (`app_config.<provider>_health` + the `ROLE` map in `_shared/opsFormat.ts`).
7. **Verify with data, not the deploy log** — per-provider delivery is in `ops_snapshot`'s `by_provider`. A single blended rate averages a dead provider with a live one and describes neither (it read 10% while the live provider was at 43%).
8. **Re-check `active_sms_provider()` AFTER the dust settles, not just after the re-home.** Added 2026-07-30, learned the hard way. It picks by *active route count*, which silently assumed one provider owns the catalog. A per-service split plus a sync that hides unfulfillable rows can leave the **retired** provider holding more rows than the live one — which is exactly what happened (SMSPVA 7,757 vs HeroSMS 5,198), pointing all five `refresh_*` evidence functions at the wrong provider with no error anywhere. Assert it returns what you expect, and re-assert it after the first sync run, not before.
9. **Give the new provider its own cost column, and scope every cached-cost fallback to the provider that owns the row.** `sync-prices` only maintains SMSPVA's `last_cost_cents`, so any other provider's rows carry a frozen number from a provider you are no longer buying from. A `??` onto that stale value passes the margin gate and then fails at reservation — a charge-and-refund that looks like a stockout. See `sync-herosms`.

## Current state (2026-08-05)

### Inventory — these move hourly. RE-QUERY, don't quote this block.

Every number below has been wrong within a day of being written at least once.
It is a starting point for "is this roughly right", never a citation.

- **iOS**: `MARKETING_VERSION 2.4`, `CURRENT_PROJECT_VERSION 45`, iOS min
  **18.0**, **3** SwiftPM dependencies (TelnyxRTC 4.1.2 → WebRTC 139.0.0,
  Starscream 4.0.8). Re-count sources with
  `find VirtualSIM -name '*.swift' | wc -l` rather than quoting a number.
  **2.3 (build 44) is `READY_FOR_SALE`; 2.4 (build 45, the line country
  catalog + country picker) SUBMITTED 2026-08-26 22:47Z —
  `WAITING_FOR_REVIEW`, submission `6c2530b0-…`, version `f08aaa70-…`.**
  (Build 43's submission `22be3a0b-…` was CANCELLED the same morning to pull
  the "≈ N verifications" paywall estimate and add the line-UI batch; the
  cancel → `DEVELOPER_REJECTED` → reattach → resubmit path worked a fourth
  time.)
  All 13 localizations carry the corrected listing (no "in and out", no
  trial, inbound calls in the "not yet" block). Read the live state with
  `python3 scripts/asc-release.py status 2.3` — never this line.
  ⚠️ **This line has been wrong about the review state FOUR versions running**,
  each time by describing a submitted build as still in review after it shipped.
  It is a decision error, not a typo: "still in review" is the argument for
  cutting another release. Read ASC — `GET /v1/apps/6774768570/appStoreVersions`
  answers it in one call — and never trust this bullet.
- **Backend**: **45** edge function dirs besides `_shared`, **193** migration
  files. (Counted 2026-08-20 with
  `ls supabase/functions | grep -v _shared | wc -l` and
  `ls supabase/migrations/*.sql | wc -l`. The previous figures — 41 / 178 —
  were stale by 4 and 15 in three days; run the commands rather than trusting
  this line, which has never once been correct when checked.)
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
- **Balances: 5sim $8.89 (rating 96/96), HeroSMS $9.41** (08-05 15:05Z). Both
  `low`, both at alert tier 3 on a `[37.50, 22.50, 11.25, 7.50]` ladder. **Both
  are near the $7.50 single-order ceiling — top up.**
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
- **Signup grant: 2 credits — SET 2026-08-25 (owner decision), verified by
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

### ⚠️ The grant size decides which ONE route new users land on

Not "how much they can buy" — **which single route the app picks for them**, and
that is where the whole cohort goes. `AppState.affordableStarter` walks a
HARDCODED service list and takes the **first entry with an affordable route**, so
the grant chooses the service by pure array position:

| grant | lands on | published rate |
|---|---|---|
| 1 cr | olx/us | 23% |
| 2–3 cr | deliveroo/Georgia | **unrated** |
| 5 cr | leboncoin/uk | 52% |

Measured 2026-08-03/04, and it is not theoretical: setting the grant to 1 at
13:12:24Z sent **16 of 16 subsequent orders to olx — from 9 different users,
with zero olx orders before that minute**. Every one came from a wallet holding
exactly 1 credit. The previous 5-credit cohort had clustered on leboncoin/subito/
whatnot the same way. Change the default, the cohort moves with it.

**This looked exactly like sabotage and was not.** Ruled out on six independent
checks: perfect alignment to a private `app_config` edit; every order from a
1-credit balance; **0** identities with `grant_count > 1`; 29 devices : 29 users;
organic signup gaps (0.5–296 min, mean 67); and a total cost of **$0.24**, all
refunded. Before suspecting users, check what the app pre-selected — and note the
cluster was on the CHEAPEST route in the catalog, the opposite of what someone
burning your money would pick.

✅ **FIXED and SHIPPED — the candidates are ranked by pool rate, not by array
position.** Landed as **`a14fb86`** (on this branch; `804a6dd` is the same
change under a duplicate hash left by another worktree and is reachable from no
branch) and rides in **build 31 = 1.9, `READY_FOR_SALE`**, confirmed against the
archive's dSYM. **Everything below describes the pre-1.9 behaviour**, which
users on 1.8 and earlier still have.

`preferred` is kept as the CANDIDATE SET and its order survives only as the
FINAL tie-break, so brand recognition still decides where the evidence is silent
and nowhere else. Scoring goes through the new `routeKey`, extracted from
`affordableFallbackCountry` so both callers share one definition of "better" —
the rule had no second caller before, which is precisely how the starter ended
up picking by position while every other ranker used the pool rate.

Old vs new, simulated against the live catalog (the two old-rule values in the
table above reproduce exactly, which is what validates the model):

| grant | old pick | new pick |
|---|---|---|
| 1 cr | olx/us 23% | **tiktok/uk 41%** |
| 2 cr | deliveroo/ge **unrated** | **discord/pl 70%** |
| 3 cr | deliveroo/us 76% | deliveroo/us 76% — agree |
| 5 cr | leboncoin/uk 52% | **glovo/pt 96%** |
| 8 cr | leboncoin/at 77% | **glovo/pt 96%** |

⚠️ **3 cr agreeing is LUCK, not correctness** — deliveroo happens to be both
near the front of the list and the best-rated today. The old rule would have
picked it just the same at 0%. Do not read the one matching row as evidence the
bug was minor.

**Corollary for any delivery analysis: an order on a route the user did not
choose is not evidence about that route.** Those 16 olx orders were cited as
proof its pool was dead; that was wrong, and only 5sim's own `rate168 = 0`
(measured across all their customers) actually supported it. The pending
`pool_rate_pct` correlation study must exclude default-landed orders or it will
measure our own steering.

### Adding services — the catalog was the bottleneck, not the provider

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

### The default-landed orders were numbers NOBODY EVER SUBMITTED (2026-08-04)

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

### ⚠️ Onboarding may never quote a credit amount

Got wrong twice, both times shipping to users. Onboarding page 2 rendered a
hardcoded **"WELCOME GIFT / +3 credits / Covers your first number"** card. When
the grant was zeroed on 08-03 the page's *prose* was rewritten and its header
comment updated to say the promise was gone — **but the card was left in
place**, and shipped that way in 1.8 and in build 29 of 1.9.

The screen runs **before sign-in**, so it cannot read `app_config` even if we
wanted it to, while the grant is a server value that changes with no release —
it has been 0, 1, 3 and 5. Any number there is a promise the server has not
agreed to keep. `RefundCard` (build 30) states the one thing true at **any**
grant including zero: a number that never delivers a code is refunded in full.

Same class as the seeded-success-rate rule — do not put a figure in front of a
user that something else is free to change underneath you.

**The same audit caught a SECOND one, and it is the more instructive of the
two.** `AppState.inviteJoinerCredits` was **5**, documented as the deliberate
SUM of `handle_new_user`'s 3 and `redeem_referral`'s 2 — correct the day it was
written, a 150% overstatement the moment the grant went to 0. It feeds three
shipped surfaces: the share text, the Account invite card and the OTP screen
prompt. Now **2**, tracking `redeem_referral` alone.

**Do not re-sum it if the signup grant is ever restored.** That is the whole
lesson: a client constant derived from a value the server changes without a
release cannot be kept honest, and the client cannot even *read* this one —
`app_config`'s RLS whitelist exposes only `maintenance` / `announcement` /
`esim_paused`. The referral half is safe to mirror because it changes only by
migration. When a grant amount moves, grep for every client constant derived
from it; there were two, and the second was found only by looking.

**It is not only client copy — the OPS channel had it too, and that one fooled
the owner.** `telegram-notify` rendered the signup alert as
`b != null ? "N free credits granted" : "welcome credit granted"`. But
`handle_new_user` writes a `wallet_transactions` row **only when the bonus is
> 0**, so at a grant of 0 the lookup misses and *every* signup alert claimed
"welcome credit granted". It read exactly like the grant was still live, and
produced the question "are you sure it's 0?" within four hours. Now
`?? 0` with `b > 0`, else *"no signup credit (grant is 0)"*.

**The general trap: a MISSING row means the grant did not happen, not that its
size is unknown.** Any code that renders a grant by looking one up must treat
absence as zero. Three of the four instances today were a fallback branch
asserting something the primary branch could no longer support.

**How to answer "did this user actually get a bonus?" — use
`public.signup_grants`, not `wallet_transactions`.** It has no FK to
`auth.users`, so it survives Delete Account, and `handle_new_user` writes to it
**only when the amount is > 0**. `wallet_transactions` cascades, so a deleted
account looks identical to one that was never granted. This mattered
immediately: three accounts that signed up after the flip had already been
deleted, and only the tombstone could prove they were granted nothing.

### What 2026-08-03 changed — the 5sim cutover

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

### Changelog — compressed

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

### ASA attribution — which keyword produced a PAYING user (2026-08-18)

Until this landed, ASA reported installs, `iap_receipts` recorded purchases,
and **the two were never joined** — so every bid was set on the cheap half of
the funnel. `AppState.submitAttributionIfNeeded` reads
`AAAttribution.attributionToken()` (framework `AdServices`, autolinked — no
project change) and posts it to **`record-attribution`**, which resolves it
against `https://api-adservices.apple.com/api/v1/` and writes one row per user
to `public.install_attributions`. Read it with **`attribution_summary()`**
(installs / buyers / purchases / credits per campaign+keyword; service-role
only, Production receipts only).

Five things that are load-bearing:
- **It runs AFTER `bootPhase = .ready`**, last in `coldStart`. A measurement may
  never lengthen the boot critical path.
- **It cannot throw out.** Every failure is swallowed; a simulator has no token
  at all and that is ordinary, not an error.
- **The `attribution.submitted` pref is set only on SUCCESS**, so a launch with
  no network retries next time. The token is per install, so one success is all
  there ever is to send.
- **Apple's 404 is AMBIGUOUS** — organic, or the token is not resolvable yet
  (documented propagation delay). The function retries once after ~3s and then
  takes it at face value. An UNREACHABLE Apple writes **no row**, so an absent
  row means "not measured", never "organic".
- **The table cascades from `auth.users` on purpose.** It is user data, not a
  grant tombstone — do not "fix" it to match `signup_grants` / `iap_grants`.

Not built: a `/attribution` Telegram command. `attribution_summary()` is the
payoff and is queryable by hand; the bot surface needs a formatter in
`_shared/opsFormat.ts` and is worth doing once there is data in the table.

### Known-open

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

🔴 **OUTBOUND SMS DOES NOT WORK, AND IT IS THE PRODUCT (2026-08-17).**
Lifetime: **1 sent / 6 failed** (the one "sent" never got a delivery receipt).
Inbound: **3 of 3**. Every cross-border send returns `40010: The sending number
is not 10DLC-registered but is required to be by the carrier`, and the number
also reports `features.sms.international_outbound: false`. The claim that
Canadian numbers need no 10DLC is **RETRACTED** — see `.claude/rules/providers.md`.

`send-line-message` now refuses cross-border (`cross_border_sms`) and non-NANP
(`international_sms`) sends up front rather than spending a segment to buy a
failure, and checkout/store no longer promise sending. **The decisive untested
case is CA → CA**: `domestic_two_way: true` says it should work with no
registration, and nobody has tried it. One message decides whether this product
has a market today or is receive-only until toll-free verification or 10DLC
clears — both of which require declaring a use case that "users send whatever
they like" does not satisfy.

🟠 **INBOUND CALLING — the four client bugs are FIXED IN THE REPO (2026-08-27,
2.5 work) but UNVERIFIED ON A DEVICE, and zero inbound calls have still ever
happened.** A simulator cannot receive a PushKit push, so the first real
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
verify-and-repair twin of `attachOutboundProfile`, run on every line every
run, so hourly `sync-line-voice` heals any push-less connection among the sold
lines). The env var alone no longer counts.


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
- 🟠 **PARTLY RESOLVED — Apple refund/revocation IS handled for the LINE, and
  still is NOT for CREDITS.** `apple-notifications` (ASSN V2, deployed and
  verified end to end) handles `REFUND`/`REVOKE` by releasing the number and
  paging. **`iap_receipts` still has no revocation column and nothing revokes
  granted credits**, so a buyer can still refund a credit pack through Apple
  and spend the credits. The endpoint now exists, so the remaining work is one
  branch in it plus a ledger reversal — not a new function. **First live case
  2026-08-10**: user `ae492f1f` bought three packs in 58 seconds ($11.97, 22
  credits, zero orders placed), asked support for a refund ("it was a
  mistake"). ⚠️ **This file said they "were pointed at reportaproblem.apple.com";
  the thread (`e36b25ba`) holds ZERO agent messages — verified 2026-08-21 —
  so no in-app reply was ever sent. It sat unanswered for 11 days and was
  closed unanswered on 2026-08-21 during the Telegram overhaul.** Apple is
  still the only refund channel (developers cannot issue Apple refunds). If
  Apple grants it, the 22 credits stay spendable until this branch is written.
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

- ⚠️ **`20260725130000_hide_route_cost_columns` deliberately NOT applied.**
  Postgres needs SELECT on every column to answer `select=*`, and the shipped
  `CatalogAPI` still sends it — applying this before build 19 is *adopted* makes
  the catalog fail to load and every price render "Unavailable" for the whole
  install base. Client-first, revoke-second, in that order.
- ⚠️ **`esim_plans` publishes the wholesale cost book** to anyone with the
  publishable key (`last_cost_cents`, `smoothed_cost_cents`) — the `routes` leak
  repeated. **The CLIENT half is now done**: `EsimPlansAPI.fetch()` names its ten
  columns instead of `select=*` (2026-07-30). The server-side column revoke is
  still outstanding and **must wait until build 19 is adopted** — revoking while
  the shipped 1.4 still sends `select=*` makes the eSIM catalog fail to load for
  the whole install base. Client first, revoke second, same as `routes`.
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

- ⚠️ **The deferred column-revoke migration `20260725130000` is a NO-OP as
  written, and would silently change nothing when finally applied.** It revokes
  SELECT on three cost columns from `anon`/`authenticated`, but `routes` carries
  a **table-level** SELECT grant (`anon=rxtm`) and has zero column-level ACLs — a
  column REVOKE only edits `pg_attribute.attacl` and cannot subtract from
  `pg_class.relacl`. Same shape as the PUBLIC-execute trap, one layer down. The
  proof it is the right diagnosis is `profiles`, where column restriction DOES
  work precisely because the table grant never included UPDATE. The fix is
  `revoke select on public.routes from anon, authenticated;` followed by an
  explicit `grant select (<columns>)`. Two further defects in the same file: it
  predates the cutover so it never revokes **`herosms_cost_cents`** (the current
  provider's wholesale, readable by `anon` today), and its re-grant list omits
  `success_codes` and `real_sim_only`, so applying it verbatim breaks build 19.
  Note also that `routes` and `esim_plans` both carry a **`public read`** RLS
  policy, so the cost book reads with **no account at all**, not merely with the
  publishable key.

- 🟠 **`orders.actual_cost_cents` — the CLIENT half is done, the server revoke
  is still outstanding.** `orders`, `esim_orders` and `email_orders` all carry
  per-order wholesale, RLS self-read grants the row, and **no Swift model
  decodes it** — a pure leak. As of 2026-08-27 **every PostgREST fetch in the
  iOS client names its columns explicitly; there is no `select=*` left**
  (`grep -rn 'value: "\*"' VirtualSIM/Networking` must return nothing). The
  lists live next to the fetch that uses them — `CatalogAPI.serviceColumns` /
  `.countryColumns` (routes was already explicit), `OrdersAPI.columns`,
  `EsimOrdersAPI.orderColumns`, `EmailAPI.orderColumns`, and the inline list in
  `SupportAPI.messages()`. Each is exactly the decoding model's stored
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

## Error UX rule

Never display raw API errors. AppState's catch blocks call `APIError.userMessage`, which maps known business-logic codes (`insufficient_credits`, `no_numbers_available`, `route_unavailable`, `provider_unreachable`, `margin_too_low`, etc.) to plain English. `errorDescription` stays for the Xcode console only.

**Keep the Swift map and the backend codes in sync.** The backend was renamed to emit `provider_unreachable` while `APIError` still only matched the old `smspva_unreachable`, so a third-party outage fell through to the 5xx fallback and blamed our own infrastructure. When you add or rename an `{ error: "..." }` literal in any edge function, add the matching case in `Networking/APIError.swift` in the same commit.

## When iOS data looks wrong, check in this order

1. Force-quit the app — `.task` only runs on cold launch (`scenePhase=.active` now also refreshes catalog, but cold start is the cleanest test). **Most "wrong price" reports are this**: the catalog is cached per launch, so any reprice you just ran won't show until a cold start.
2. Xcode console for catalog decode errors (column name mismatches show as `keyNotFound`). A field missing from the Swift model is dropped **silently** by `.convertFromSnakeCase` rather than erroring — that's how the eSIM SIM PIN sat in the database for a day and never reached the screen.
3. `curl` PostgREST directly with the publishable key — if curl returns the data, iOS decoding is the issue. Check the row **count** too, not just the shape (see the `max_rows` truncation gotcha).
4. Function logs in Supabase dashboard → Functions → pick function → Logs.

## ASO

Moved to the `aso-listing` skill (`.claude/skills/aso-listing/SKILL.md`).
Search is the app's ENTIRE acquisition channel — invoke it before touching
the store listing, keywords or screenshots.

**The name stays `vSMS: Temp Number, Receive SMS` — owner decision
2026-08-22, do not re-open it on feel.** The case was made and accepted: the
30-char name carries the two highest-weight search terms and search is the
only channel; cross-day retention is ~5 users, so brand equity lives in
ranking and ratings, not in users; and 2.0's umbrella-first onboarding
(Aug 15–19) cut first-day orders from ~30/day to 1 — a live measurement of
what breadth-first positioning costs. **Rebrand trigger:** a non-SMS line
exceeds **40% of monthly net for two consecutive months** (read from
`/profit` once it includes subscriptions — it does not yet, see Known-open).
If the umbrella *feel* is wanted before then, the in-app display name, icon
and onboarding can change per release without touching the indexed store
name — zero keyword risk. Mechanics if it ever happens: the store name is
editable only on a new version and reviewed with it; App ID, bundle ID,
ratings, subscribers and installs carry over; the cost is 13 localized
names/subtitles, new screenshots, a 7–14 day keyword re-rank and ASA
re-pointing — and the name cannot hold an umbrella brand AND both SMS terms.

## Release prep

Moved to the `release-prep` skill (`.claude/skills/release-prep/SKILL.md`).
Invoke it when cutting a release — it carries the headless ASC pipeline, the
beta-macOS `BuildMachineOSBuild` patch for ITMS-90111, and the in-app-purchase
review rules (including the one-way-door cancel).
