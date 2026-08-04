# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**vSMS** (App Store display name; formerly "vSIM OTP" — the Xcode target/scheme is still `VirtualSIM`) — iOS app selling three products, all paid with in-app **credits**: (1) **temporary phone numbers** for SMS verification codes, (2) **temporary e-mail addresses**, and (3) **eSIM data plans** priced at 4× wholesale (line currently PAUSED). iOS frontend in SwiftUI + Supabase backend (Postgres + Auth + Edge Functions + pg_cron).

**Provider split as of 2026-08-03 — 5sim is the PRIMARY SMS provider; HeroSMS
and SMSPVA still serve the services 5sim does not map; HeroSMS also serves the
whole temp-EMAIL line; SMSPool serves eSIMs only (paused).**

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
# iOS type-check (verify ALL Swift compiles; no simulator, no platform install)
# Use this when xcodebuild refuses to build — see the destination note below.
# The project has ZERO SwiftPM dependencies, so swiftc alone type-checks the
# whole app against the simulator SDK. Exit 0 = everything compiles.
xcrun swiftc -typecheck \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -target arm64-apple-ios26.5-simulator -swift-version 5 \
  $(find VirtualSIM -name '*.swift')

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
  create-email-order check-email-order email-domains support-send
# Cron-gated functions MUST ship --no-verify-jwt: their pg_cron relays send
# only x-cron-secret, no Authorization header. winback lived in the JWT group
# until 2026-07-21 and silently 401'd on every daily run — zero nudges ever
# sent, invisible because pg_net purges response history within hours.
supabase functions deploy poll-active-orders sync-prices sync-5sim sync-herosms \
  sync-esim-plans sync-smspva-operators sync-smspva-conversions winback \
  telegram-notify telegram-webhook daily-credit --no-verify-jwt
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
# ⚠️ The two lists above do NOT cover everything: there are **26** function
# directories besides _shared, and TWO appear in NEITHER list — `telegram-setup`
# (cron-gated, fails closed; rotating TELEGRAM_WEBHOOK_SECRET requires
# re-running it) and `goodwill-credit` (manual make-good grant + push, added
# 2026-08-02). Both deploy --no-verify-jwt.
# (This comment has been wrong about the count twice — 19, then 25. COUNT the
#  directories rather than trusting this line: `ls supabase/functions | grep -v _shared | wc -l`.)
# ⚠️ `_shared/*` is bundled PER FUNCTION at deploy time. After touching
# _shared/fivesim.ts, redeploy sync-5sim AND poll-active-orders AND every
# consumer of providers.ts (create-order, check-order, cancel-order,
# delete-account) — a stale bundle keeps the OLD copy with no signal anywhere.

# Query the remote DB
supabase db query --linked "select count(*) from public.routes;"

# Trigger any cron-gated function WITHOUT handling the secret yourself. pg_net
# calls it server-side and private_cron_secret() never leaves the database.
# Live pg_cron schedule (16 jobs, all active — re-verified 2026-08-03):
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
supabase db query --linked "
  select net.http_post(
    url := 'https://enugzltysdmjzavisloy.supabase.co/functions/v1/sync-prices',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'x-cron-secret', private_cron_secret()),
    body := '{}'::jsonb, timeout_milliseconds := 180000);"
```

There is no test suite. Verify iOS with the `swiftc -typecheck` command above
(exit 0 = all 96 sources compile as of 2026-08-03 — re-count before trusting). It does NOT catch everything — a missing
`import StoreKit` type-checked fine and failed the real build, so prefer
`xcodebuild` when you can afford it. Verify backend changes by re-deploying, then
**checking the resulting DB state** — not by assuming the deploy worked. Several
bugs this session looked identical to success until a row was queried: an
SMSPVA balance read that silently wrote nothing, and maintenance jobs that ran
against a retired provider.

If the CLI errors with `too many authentication failures ... (ECIRCUITBREAKER)`,
`supabase db query --linked` mints a temp login role per call and parallel
agents exhaust it. Use the Supabase MCP `execute_sql`/`apply_migration` tools
instead — different auth path, unaffected.

## Architecture

```
iOS (SwiftUI, iOS 18.0 min target)        Supabase
─────────────────────────────             ──────────────────────────────────────────
AuthGate                                  Postgres tables: profiles, wallets,
  ↓ Sign in with Apple (native)             wallet_transactions, services, countries,
ContentView (4 tabs: home / esim /          routes, orders, esim_plans, esim_orders,
  orders / account + flow cover)             referrals, push_devices, iap_receipts,
  ↓ APIClient (URLSession + apikey hdr)      telegram_events, app_config
  REST  → /rest/v1/...  (PostgREST)
  RPC   → /functions/v1/...               Edge Functions (Deno):
                                            create-order/check-order/cancel-order
Providers — _shared/providers.ts:           poll-active-orders (cron, every 1 min)
  SMS  → 5sim (5sim.net) — PRIMARY,        create-esim-order/check-esim-usage
         146 services / ~4,400 routes      sync-5sim (hourly :07, PRIMARY pricing)
  SMS  → SMSPVA (api.smspva.com), 115      sync-prices (hourly :17, + catalog
  SMS  → HeroSMS (hero-sms.com), 102         maintenance) / sync-esim-plans (daily)
  MAIL → HeroSMS /api/v1 (same account,    sync-herosms (hourly :37)
         same balance as its SMS side)     telegram-notify (cron 1 min) /
  eSIM → SMSPool (api.smspool.net) PAUSED  telegram-webhook (public, 2-gate)
  Ownership per SERVICE, no fallback       redeem-referral / winback
  smspool-SMS + virtualsms DELETED         register-push / iap-verify / delete-account
                                            create-email-order/check-email-order
APNs ←── token-auth (.p8) HTTP/2            sync-smspva-operators+conversions
Telegram ←── ops alerts + 6h digest         support-send / daily-credit (DISABLED)
```

**iOS minimum is 18.0**, lowered from 26.2 in `a9b92c0` (shipped as 1.5 build 16)
— the 26.2 floor excluded almost every device in the install base. Anything
guarded by an `if #available(iOS 26, *)` must keep a working 18.0 path.

### iOS source layout

```
VirtualSIM/
  VirtualSIMApp.swift            App entry; resizes URLCache (32MB mem / 64MB disk
                                 for brand logos + flag PNGs); installs AppDelegate
  ContentView.swift              4-tab routing (home/esim/orders/account) +
                                 fullScreenCover for Checkout/Waiting/OTP + eSIM
                                 flow (esimCheckout/esimDetail); EnvBundle
                                 ViewModifier re-injects every @Observable env
                                 object into sheet/cover content (covers don't
                                 inherit reliably)
  Auth/                          AuthGate (3-state: bootstrap/signedOut/signedIn),
                                 SignInScreen, Session (@Observable, Keychain-backed)
  Networking/                    APIClient + per-resource APIs (CatalogAPI, OrdersAPI,
                                 WalletAPI, ProfileAPI, IAPAPI, AccountAPI, PushAPI,
                                 AuthAPI). Secrets.swift is gitignored
  State/AppState.swift           Single @Observable source of truth — services,
                                 countries, routes, orders, prefs (UserDefaults-
                                 backed via didSet), checkout/flow machine
  Models/                        Plain Codable structs mirroring DB column names via
                                 .convertFromSnakeCase (Service, Country, Route,
                                 Order, EsimPlan, EsimOrder, CreditPack,
                                 CountryRank = the PROVIDER's success rate for a
                                 (service, country) — steering input, never a
                                 badge; see the steering section)
  Screens/                       Home, Checkout, Waiting (+ WaitingAnimations),
                                 OTP (fires native review prompt on code
                                 delivery), Orders, Account, + eSIM flow
                                 (EsimStore = Store/My eSIMs/Activity segments,
                                 EsimMapView = clustered MapKit country picker,
                                 EsimCountryPlans = duration→size chooser,
                                 EsimActivity = usage metrics + history,
                                 EsimCheckout, EsimDetail = QR + usage),
                                 Recovery (post-failure: retry on a fresh number /
                                 switch country / refund explainer — see the
                                 retry-steering note below), Maintenance (shown
                                 during the nightly operator-sync window),
                                 SplashScreen (cold-launch cover — see below),
                                 EmailWaiting/EmailCode (temp email),
                                 SupportChatScreen (live chat)
  Sheets/                        EmailDomainSheet (4 domains, live stock,
                                 Free/1cr), ServiceSheet (search + categories + per-route
                                 price; a service with no route in the SELECTED
                                 country shows where it IS bookable, never a bare
                                 "Unavailable" — see the picker note below),
                                 CountrySheet (sort + per-route price),
                                 CreditsSheet (StoreKit 2)
  Components/                    Theme primitives + ServiceLogo / FlagImage /
                                 FlagCircle — bundle-first via BundledImageStore,
                                 network cascade (DuckDuckGo/FaviconV2, flagcdn) as
                                 fallback; SuccessBadge renders MEASURED delivery
                                 odds only (grey/amber/red), never seed rates;
                                 BrandWordmark (green `v` + SMS — the logo, and on
                                 the splash also the loading indicator);
                                 CodeFlag (flag from a bare ISO2 — the eSIM
                                 catalog has no `Country`); DataRing/DataBar
                                 (usage gauges, show REMAINING not used)
  Push/, IAP/, Onboarding/       Self-explanatory
  DesignSystem/                  Theme, Typography, Icons + **Motion.swift**
                                 (`RMotion`: one animation vocabulary named by
                                 what moves — select/panel/content/value/camera
                                 + `stagger`. Use these, not inline curves)
                                 + **Glass.swift** (`.glassPanel(shape:)` —
                                 Liquid Glass on iOS 26, frosted material below.
                                 See the note below: the availability guard
                                 lives HERE and nowhere else)
  Localizable.xcstrings          String Catalog: en source + de/es/fr/it/ja/pt-BR
  Products.storekit              Local IAP test config (enable via scheme)
  VirtualSIM.entitlements        Sign in with Apple + aps-environment
```

### Backend layout

- `supabase/migrations/` — chronological SQL, each phase ships its own file
- `supabase/functions/_shared/` — `providers.ts` (unified router; per-SERVICE ownership across 5sim/SMSPVA/HeroSMS with NO cross-provider fallback — order/poll functions call this, NOT a specific provider), `fivesim.ts` (5sim REST wrapper — the PRIMARY SMS adapter), `herosms.ts` (SMS-Activate `handler_api` wrapper), `heromail.ts` (HeroSMS `/api/v1`, the temp-EMAIL line), `emailStatus.ts`, `smspva.ts` (v2 REST wrapper), `smspool.ts` (eSIM + balance ONLY — the SMS surface was deleted 2026-07-30), `apns.ts` (HTTP/2 + JWT), `cors.ts`, `iap.ts` (Apple receipt chain verification), `telegram.ts`, `opsFormat.ts`, `supabaseAdmin.ts`. `virtualsms.ts` is **gone**. That is **13 files** — count them rather than trusting this list.
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

### 5sim API — the provider that publishes delivery rates (live 2026-08-03)

Base `https://5sim.net/v1`. Auth is `Authorization: Bearer <JWT>` on `/user/*`;
`/guest/*` needs no key at all.

```
GET /v1/guest/prices?country=<slug>   # UNAUTHENTICATED
→ country → product → operator → {cost, count, rate, rate1, rate3, rate24,
                                  rate72, rate168, rate720}   # suffix = HOURS
GET /v1/user/buy/activation/{country}/{operator}/{product}    # pins the pool
GET /v1/user/profile                  # {balance, rating}
```

**`rate720` (30 days) is the base number we use, stored in `routes.pool_rate_pct`
and rendered in the picker.** It has the best coverage of any window *and* is the
most stable. Do not read 5sim's own website as a reference: its operator list
shows the **max across all seven windows**, and its Statistics tab shows
`rate72`, so our figures will look lower than theirs. That is correct, not a bug.

🔴 **`rate720` ALONE IS NOT SAFE — it lags a pool's death by up to three weeks,
and that cost us a whole route (2026-08-04).** olx/us pinned `virtual63` at a
published **49.24%** whose `rate168`, `rate72`, `rate24` and `rate` were all an
explicit **0**: it had not delivered in at least seven days. Thirteen real
orders across five different users, every one held to expiry, **zero codes**.
On the same route `virtual51` published `rate720 = 0` — so we ranked it last —
while actually running at `rate24 = 22.7%`. We pinned the corpse and skipped the
live pool, then painted the row green at 49%.

Measured over the 801 chosen pools in the 14 busiest countries: **96 (12.0%)**
published `rate720 > 0` against an explicit `rate168 = 0`.

**ABSENT IS NOT ZERO, and this distinction is the entire fix.** The windows are
perfectly nested by length, so an absent field means *no activations* in that
window while an explicit `0` means there *were* activations and every one
failed. Only the explicit 0 is evidence of death. `staleDead` therefore tests
`v.rate168 === 0` and must NEVER be written as `!v.rate168` — the sloppy form
condemns every low-traffic pool in the catalog.

**THE FIX IS A FRESHNESS LADDER, not a special case.** `rateOf(pool)` in
`sync-5sim` returns, in order: `rate24` if positive → `rate168` if positive →
**0** when `rate168` is an explicit 0 → `rate720` → `null` (never measured).
One helper drives all three tiers of `choosePool`.

Leading with the short windows is nearly free. Measured over 4,003 in-stock
pools (2026-08-04):

| window | published | published > 0 |
|---|---|---|
| `rate24` | 35.4% | 8.7% |
| `rate168` | 37.7% | 11.8% |
| `rate720` | 39.5% | 14.8% |

**⚠️ THE ASYMMETRY IS LOAD-BEARING.** A positive short window is accepted
immediately; a **zero is only believed when the 7-day window agrees**. A rate
has no denominator, so a 24h zero can be 0-of-1 and must not condemn a good
pool, whereas a full week of activations that all failed is a verdict. Guarding
only the positive direction is the easy mistake here.

Live effect: rated routes 1,906 → 1,753; simulated over 2,962 routes, 90 switch
pool and 373 are relabelled (187 up, 224 down) for a coverage cost of −3.6%.
olx/us went `virtual63` 49% → `virtual51` 23%.

**Only the bare `rate` field is documented.** All seven windowed fields are
undocumented, and the documented rule *"omitted below 20% or too few orders"* is
already false live (we observe 0.0 and 4.24). Treat presence as the only signal.

**There is no denominator.** Rates cluster on exact small-denominator fractions
(4.76 = 1/21, 33.33 = 1/3), so a published "0%" is frequently 0-of-3, not a
verdict — and **~66% of every published `rate720` in the feed is exactly 0**.
`MIN_POOL_STOCK` guards *stock*, not sample size. Nothing currently bounds it.

**Four traps, all paid for in production — see the header of `_shared/fivesim.ts`:**

1. **`status: "RECEIVED"` DOES NOT mean a code arrived.** A freshly-bought order
   returns `{"status":"RECEIVED","sms":[]}`, and the docs' own example shows the
   SAME status *with* a code. **`sms[].code` is the only authority** — the same
   rule as SMS `otp is not null` and e-mail `code is not null`.
2. **A stockout and a bad country both return HTTP 200 `no free phones`.**
3. **Errors are PLAIN TEXT, never JSON**, and the status alone is not enough.
   `classifyFivesimFault` classifies transport FIRST and must never return
   `undefined` for one — `reserve()` treats undefined-or-OUT_OF_STOCK as "pinned
   pool dry, retry unpinned", which has already caused a double purchase once.
4. **There is no `maxPrice` parameter.** The post-fill ceiling check in
   `create-order` is therefore the ONLY price guard, so `refuseAboveUsd` uses the
   **tight** `maxCostUsd` bound — the loose `MAX_REVENUE_FRACTION` bound is only
   safe for a provider that enforces a cap server-side.

**The rate limit is REAL and it is a 429, settled 2026-08-03.** This was an open
question because the adapter collapsed every failure to `null`: a 429 (back off)
and a 403 (Cloudflare's bot filter, which spacing cannot fix) were
indistinguishable. `getPricesForCountry` now returns the status and `sync-5sim`
histograms it into **`fetch_faults`**. First instrumented run: `{"429": 10,
"400": 2}`, sample `"429: too many requests"`. So `CALL_SPACING_MS = 600` targets
the right cause — **but 10 hits per run means it is not quite sufficient.** Raise
it only on more than one sample; a run costs ~71s at 600ms × 61 countries and the
edge kill is ~150s.

**Do NOT set an explicit User-Agent.** Measured on the same URL 4s apart:
`Python-urllib/3.11` → **403 `error code: 1010`**, while `curl/8.7.1`,
`Deno/2.1.4` and an empty UA all → **200**. Deno's default already passes;
pinning a value means defending it against their next rule change.

**`user/profile.rating` is a SECOND way to lose the ability to buy**, invisible
in the balance. Starts and caps at **96**; completed activation +0.5, top-up +8,
against cancel −0.1, ban −0.1, timeout −0.15. **At zero you cannot purchase at
all**, surfacing as `not enough rating` — which `classifyFivesimFault` maps to
AUTH_ERROR, i.e. it pages as a dead key rather than the slow drift it is. We ban
dead numbers deliberately and our cancel rate is high, so it only trends down
between top-ups. Recorded into `app_config.5sim_health.rating` by
`poll-active-orders` (currently **96**, ~140 days of headroom). Nothing gates on
it on purpose — the ban is load-bearing for the fresh-number guarantee.

### HeroSMS API — what cost us time (probed live 2026-07-30)

⚠️ **HeroSMS is no longer the primary SMS provider, but it is NOT retired**: it
still owns 560 active SMS routes and the entire temp-EMAIL line, on one shared
account and balance. Everything below still applies to both.

Runs SMS-Activate's `handler_api` protocol. Base is
`https://hero-sms.com/stubs/handler_api.php?api_key=…&action=…` — there is **no
`api.` subdomain**, it is NXDOMAIN. `getCountries` / `getServicesList` /
`getOperators` need no key, so the whole mapping can be built before paying.

- **Every response is served as `content-type: text/html`, including the JSON
  ones.** Block detection keyed on content-type therefore classified every
  *successful* response as a Cloudflare block, which broke ordering outright. Key
  on **status 403/429 plus an HTML-looking body**, never on content-type. The
  symptom was a missing `herosms_health` row — and `recordBalance` returns early
  on null, so the absence looked like nothing at all.
- **Error codes carry suffixes**: `WRONG_MAX_PRICE:0.35`, `BANNED:<date>`. Exact
  `switch` matching silently never fires; use prefix matching for those two.
- **`activeActivations` is an OBJECT, not an array** — the real shape is
  `{"status":"success","data":[],"activeActivations":{…,"rows":[]}}`. So
  `d.activeActivations ?? d.data` never falls through and always returned `[]`.
  Read `d.data` first.
- **There is no documented per-second rate limit.** A 403 during probing was the
  *website's* bot challenge, not the API — 25 rapid calls all returned 200. The
  real cap is the account's `CHANNELS_LIMIT`. Do not add throttling to work
  around a 403 you got from a browser-shaped request.
- **`classifyHerosmsFault` is mandatory.** Per the provider-switch checklist, an
  adapter that does not set `errorType` collapses dead account / bad key / rate
  limit / genuine stockout into `no_numbers_available`, so users are told to "try
  another country" while the whole product is down and the escalation
  `console.error` never fires.
- `getPrices` returns `{cost, count, physicalCount}` per (service, country) —
  `physicalCount` is the real-SIM signal and the reason we moved.
- **`getTopCountriesByService`** works and returns 194 rows of
  `{country, price, retail_price, count}` per service. That is stock and price,
  **not** delivery success. It is now marked **Deprecated** in their docs, which
  point to `GET activations/offers` instead. Its response is an ORDERED map
  (`{"0":{…},"1":{…}}`), and that ordinal is sorted by neither price nor stock —
  which makes it look like the dashboard's quality ranking. **It is not.**
  Decoded for `go` (Google) it reads Indonesia → Colombia → UK → Brazil →
  Philippines → Turkey → Chile, while the dashboard's own "by quality" sort for
  the same service reads Finland → Portugal → Colombia → Chile → Spain. It ranks
  **Indonesia first**, and we have measured google/id at **0 of 4**. Treat the
  ordering as popularity/volume; using it as a quality signal would steer
  straight into routes we know deliver nothing.
- **`/api/v1/activations/offers` WORKS with `Authorization: ApiKey <key>`**
  (verified 2026-07-31). This contradicts the note below, which concluded the
  whole `/api/v1/activations` namespace is session-only — that is true of
  `/api/v1/activations` itself but **not** of this sub-path, so a targeted retry
  is worth it when a specific endpoint is known. It returns strictly more than
  `getPrices`: per (service, country) `counts.{total,physical,defaultPrice}`,
  `prices.{default,retail,min}`, and a price→stock `map`. `prices.min` plus that
  map is a real margin lever — `sync-herosms` currently buys at the default
  price when cheaper stock may exist. Not yet wired up.
- **There IS a rate limit** (`{"title":"RATE_LIMIT"}`), hit after roughly a dozen
  rapid calls on 2026-07-31. This file previously said there was no per-second
  limit because 25 rapid calls all returned 200. Note `sync-herosms` makes ~148
  sequential fetches at `CALL_SPACING_MS = 150` and shares the key with the
  minutely poller — do not probe casually against the production key.

**The per-(service, country) SUCCESS RATES in HeroSMS's dashboard are NOT
available by API — do not go looking again.** Searched exhaustively 2026-07-30:
26+ `handler_api` action names; the `/api/v1` namespaces `statistics`, `stats`,
`analytics`, `top10`, `activations/statistics` (all `ROUTE_NOT_FOUND`); the docs
page (a pure client-side loader with no SSR content); Nuxt `_payload.json`
(empty); all 50 JS chunks for any spec reference; 13 conventional OpenAPI paths
on both the site and their CDN. `/fr/*` is Cloudflare-challenged, so scraping is
out too. The "decisive test" recorded here was that the **same key and `ApiKey`
scheme that returns data from `/api/v1/emails` is rejected by
`/api/v1/activations`**, concluding the whole namespace is dashboard-session.
**That inference was too broad** — `/api/v1/activations/offers` authenticates
fine with `ApiKey` (see above). The bare collection path is session-only; its
sub-paths are not. So the negative result is "these ~45 specific paths do not
exist", not "the namespace is closed".

Re-probed 2026-07-31 with five more targeted paths now that `offers` was known
to work — `activations/{statistics,top-countries,ranking}`,
`statistics/activations`, `activations/offers/statistics` — all
`ROUTE_NOT_FOUND`. **Stop guessing; the path is not discoverable by enumeration.**

**✅ THE FULL OpenAPI SPEC EXISTS AND IS ON DISK: `~/hero-sms-research/openapi.json`**
(219 KB, 31 paths, `"API protocol for working with HEROSMS"`, servers
`hero-sms.com/api/v1` and `/stubs/handler_api.php`). This file previously said
no spec exists at any conventional path — read the spec instead of probing.
⚠️ **It is a CURATED SUBSET, not an inventory:** `getNumbersStatus` appears
**zero** times in it yet we call it in production, `getPrices` has no documented
`currency` param (we send it, it works), and `/api/v1/stats/deliverability` is
absent entirely. "Absent from the spec" means **undocumented**, never
**"does not exist"**.

**Two dead leads, both settled — do not re-open:**
- **`getTopCountriesByServiceRank` is NOT deliverability.** It and
  `getTopCountriesByService` differ in exactly two keys (operationId, summary);
  identical response schema, both deprecated. "Rank" is the **account's loyalty
  discount tier**, verified against SMS-Activate's own pricing pages. Live
  payload is `{country, price, retail_price, count}` — stock and price, no
  outcome field. Same trap as `physic` reading like "all physical SIMs".
- **`getListOfTopCountriesByService` does not exist on HeroSMS.** SMS-Activate's
  archived docs document it returning `{country, share, rate}` where `rate` is
  "% of successful activations" — exactly what we collect by hand. Probed
  2026-08-02: **HTTP 404 `BAD_ACTION: Method Not Found`**. Controls in the same
  minute on the same key proved it a true negative: `getBalance` →
  `ACCESS_BALANCE:10.1551`, `getTopCountriesByService` → 200 / 13,247 bytes.

**FOUND 2026-07-31, by reading the request the dashboard's own Statistics panel
fires (DevTools → Network → XHR). Enumeration never would have reached it:**

```
GET https://hero-sms.com/api/v1/stats/deliverability
      ?service=go            # their service code
      &interval=12           # hours
      &successCount=medium   # the ">50 successful" filter
```

The earlier sweep tried the `/api/v1/stats` namespace but never
`stats/deliverability`. Response is `application/json`, 200, behind Cloudflare.

**It is NOT callable with our API key.** All four schemes return **401
`{"title":"Unauthenticated."}`** — `Authorization: ApiKey`, `Bearer`,
`X-Api-Key`, and `?api_key=`. Note that body is *not* `ROUTE_NOT_FOUND`, so the
route genuinely exists and is simply scoped to a logged-in dashboard session.
**Do not re-probe it; the answer is settled.**

So the vendor is now the only route — but the ask is far smaller than it was,
and should be made in these exact terms: *"please allow
`GET /api/v1/stats/deliverability` to authenticate with an API key."* That is a
middleware change on one existing endpoint, not a feature request.

Asked the vendor 2026-07-31 (Jivo chat, ticket `5207504-97969`) before the path
was known. Response: *"I will forward your request"* — acknowledged, no
commitment, no timeline. **Do not block anything on it.**

**The manual loop is now the ONLY route, confirmed 2026-08-02.** Every API path
to this data has been eliminated (see the two dead leads above plus the
session-scoped `stats/deliverability`). Stop looking; spend the effort on the
vendor ticket or on accumulating our own measurement.

**Until they answer, the data is collected BY HAND, roughly weekly.** The loop,
in full, because half of it is easy to forget:

1. Log in to hero-sms.com, open the Statistics page, DevTools → Console, paste
   `scripts/collect-herosms-deliverability.js`. ~74 min for 147 services at
   30s spacing. It negotiates the loosest interval/threshold the API accepts,
   saves after every service, and resumes if the tab closes.
2. `copy(HERO.sql())` → run against the DB.

**Step 2's SQL ends with `refresh_service_country_ranks()` and that call is
mandatory.** `merge_vendor_deliverability` only stores the RAW payload;
`service_country_ranks` is the projection the app actually reads and is rebuilt
only by that function. Skip it and you load a fresh week of data, watch every
merge return `ok`, and the app keeps serving last week's ranking — a silent
no-op wearing a success message. `HERO.sql()` appends it for exactly that reason.

Saved progress **expires after 6 days**, so a weekly re-paste starts clean.
Without that the second run would find the previous results in localStorage,
mark all 147 services already-collected, fetch nothing, and look like it worked.

**"Top 10" is a CAP, not a quota.** Measured on the first full run
(24h / `successCount=medium`), only **22 of 147** services returned ten
countries; **69 returned none** and 32 returned one or two. leboncoin returned 2
against 33 active routes — not because 31 routes are bad, but because only two
countries saw 50+ successful leboncoin activations in a day. This is why
absence must stay neutral everywhere it is consumed. A longer window and a lower
threshold are what fill the thin services in, which is what the ladder probes.

Replaying the dashboard's session cookie from an edge function would work
technically and is a bad idea: it expires, it carries XSRF, it would fail
silently, and it is the kind of thing that gets an account closed. If a manual
pull is ever wanted, the honest shape is a hand-maintained per-service country
allowlist in `app_config` — same category as `blocked_routes` and
`voip_strict_services`, used as steering input for UNTESTED routes only.

And if it ever IS exposed: it would be **steering input, never a badge**. It is
their aggregate across all customers, not our delivery — the same class of number
as SMSPVA's seeded per-country grade, which ranked as "proven", beat genuinely
untested countries, and had to be demoted to `.notTested`.

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
eSIM purchases and emits a 6-hourly digest; `telegram-webhook` answers `/stats`,
`/today`, `/week`, `/balance`, `/revenue`, `/orders`. Exactly-once is a claim row in `telegram_events`
(`kind`,`ref` PK) written *before* sending, so the instant path in `iap-verify`
and the sweep can never double-send. Secrets: `TELEGRAM_BOT_TOKEN`,
`TELEGRAM_CHAT_ID`, `TELEGRAM_WEBHOOK_SECRET`. The webhook is public and gated
twice — matching `X-Telegram-Bot-Api-Secret-Token` **and** owner chat id — and
returns a silent 200 on every rejection so it isn't an oracle.

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
  and never reserved anything. The rate is over `numbered`.
- Rows are capped at 35 with an explicit *"… and N older, not shown"*. A
  silently truncated list reads as "that was everything".

### Announcement banner + `/announce`, `/esim` (2026-07-31)

A small owner-written banner on **Home**, posted from Telegram. Ships in 1.6.

```
/announce Your message          → live, info (accent)
/announce warn Your message     → live, amber
/announce off                   → clears it
/announce                       → shows what is currently live
/esim on | /esim off            → set_esim_paused() from the phone
/esim                           → reports which way it is set
```

**`app_config` is RLS-restricted to an explicit key WHITELIST, and that is the
only safe way to widen it.** The table also holds `herosms_health` /
`smspva_health` (balances), `watchdog`, `blocked_routes` and sync cursors. The
policy is now:

```sql
app_config_read: SELECT to authenticated
  using (key = any (array['maintenance','announcement','esim_paused']))
```

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
Authorization header, and `config.toml` has no entry for it, so the flag is the
only control). Deploying it without the flag 401s every update and kills the bot
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

**Price does NOT predict delivery** (16% / 19% / 17% / 23% across ≤5¢ / 6–15¢ /
16–40¢ / >40¢, n=32/69/23/40, drift inside the noise, cancels dominating every
band). So dearer stock is not better stock, just more of it — there is no
quality argument for hugging the floor.

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

**eSIM** plans (`sync-esim-plans`) are priced **separately** at 4× wholesale (raised 3× → 4× on 2026-07-25) — `ESIM_MARGIN = 4`, `CREDIT_VALUE_USD = 0.48`, `retail_credits = ceil(usd * 4 / 0.48)` — NOT via `CREDIT_DIVISOR`, so the two product lines never collide. Inverted, the order-time ceiling in `create-esim-order` is `credits * 0.12`: SMSPool's `/esim/purchase` accepts no price cap and its response reports **no cost at all**, so the function takes a fresh `/esim/plans` quote, blocks above the ceiling, and writes that real number into `actual_cost_cents`. It fails **closed** on a bad price and **open** on a failed lookup — an unreachable SMSPool must not make eSIMs unbuyable. (Before this, `actual_cost_cents` echoed the cached catalog price, so margin analysis over it was circular and could never reveal drift.)

**The divisor is PER PROVIDER — 5sim 0.03 (10×, owner 2026-08-03), HeroSMS
0.025 (12×), SMSPVA 0.05 (6×). Each provider's sync sets its own
`retail_credits`.**

| provider | priced by | divisor | `MIN_MARGIN` | `0.30 / MARGIN` | `MAX_WHOLESALE_CENTS` |
|---|---|---|---|---|---|
| **5sim** | `sync-5sim` | **0.03** | **10.0** | 0.03 ✓ | **450** |
| herosms | `sync-herosms` | 0.025 | 12.0 | 0.025 ✓ | 375 |
| smspva | `sync-prices` | 0.05 | 6.0 | 0.05 ✓ | 750 |

`MIN_MARGIN_FALLBACK` is **12.0** — the strictest, never the loosest.
Each `MAX_WHOLESALE_CENTS` is `150 credits × that provider's divisor`, i.e. the
largest credit pack, so the rule stays "hide only what a user literally cannot
buy". **There are now FIVE copies of a divisor and THREE of
`MAX_WHOLESALE_CENTS` across four sync functions** — they are deliberately
different values, so "consolidating them into `_shared/`" would silently reprice
a whole provider. Change them in one commit, never one at a time.

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

### Why `sync-5sim` exists (hourly :07) — the PRIMARY pricing sync

Fetches `guest/prices` **one country at a time** (61 countries, ~71s/run). The
all-countries form is a single 9.1 MB response; per-country is 0.1–0.6 MB, which
bounds peak memory inside the edge runtime and lets a partial run still write
what it got. `CALL_SPACING_MS = 600` plus one 2.5s retry — see the 5sim section
for why (measured 429s, not a bot filter).

It prices routes (`CREDIT_DIVISOR = 0.03`), applies the **cost RATCHET**, picks
the pool each route buys from, and writes `pool_operator` / `pool_rate_pct`.

**`choosePool` has THREE tiers, and the ordering is the whole point:**

1. `rate720 > 0` — best rate first.
2. **unrated** — most-stocked, `ratePct = null`.
3. **all pools published zero** — most-stocked, and the 0 is kept.

Tier 2 must sit above tier 3. Before this was fixed (2026-08-03), **844 routes
picked a published-0% pool over an unmeasured pool holding a median 271× the
stock** — olx/Finland took `virtual4` at 0% over `virtual34`'s 8.6 M numbers —
and then painted the route red in the picker with that number. Both the pick and
the label rested on a sample that is frequently 0-of-3. Live effect: routes
carrying a published zero went **1,184 → 359**. It is also a **repricing**,
because cost derives from the chosen pool: 469 routes got cheaper, median −1
credit.

The chain is filtered by `affordable()` — non-head members above
`headCost × 3 + 0.10` are dropped, so a fallback can never cost wildly more than
the pool we advertised.

**Guards, each matching a failure this codebase has already had:** it aborts
without writing if every country fetch fails (`countries_ok === 0`); it skips
routes whose country failed *this* run rather than reading a failed fetch as
"not served" (`skipped_failed_country`); it enforces `blocked_routes` and
`MAX_WHOLESALE_CENTS = 450`. Watch `fetch_faults` and `countries_failed` in the
response — a country silently dropped for an hour reads as "5sim does not serve
it".

### Why `sync-herosms` exists (hourly :37)

**⚠️ IT PRICES FROM `/api/v1/activations/offers`, NOT `getPrices` (2026-08-02).**
`getPrices` returns a DEFAULT price and a TOTAL count, and **those two numbers
are not about the same numbers** — on many routes nothing at all is available at
the default price. The worked example cost a paying customer their entire
session (8 straight failures, then they left), apple / Turkey (`wx`/62):

```
getPrices : cost 0.30, count 140211              <- what we used to store
offers    : counts.defaultPrice = 0,
            map = { "0.4177": 641003 }           <- the truth
```

Zero numbers at $0.30; all 641,003 cost $0.4177. Storing $0.30 priced the route
at 12 credits, which set the order ceiling at $0.40 — **1.8 cents below the only
stock in existence**. Every attempt returned `WRONG_MAX_PRICE` → `margin_too_low`
→ charged and refunded, forever.

Measured over 1,554 pairs: **60 (4%) had ZERO stock at the advertised price** and
**1,107 (71%) had stock CHEAPER than it**, so `getPrices.cost` is wrong in both
directions. We now take the cheapest key in `map` **with a non-zero count**.

- **`prices.min` is NOT that number** — it reads 0.27 on wx/62 where nothing
  exists below 0.4177. It is "the lowest price you may bid". Only the map says
  what is buyable.
- Falls back per service to `getPrices` when offers fails **or reports
  `hasMore`** — the pagination params are undocumented, and a partial page must
  never read as "not served".
- **Also ~40× fewer calls**: 144 codes in ONE run of ~4 requests instead of ~148
  sequential fetches at `CALL_SPACING_MS`, which was most of our rate-limit
  exposure. Live run: **11.5s**, `via_offers 144 / via_getprices 0 / truncated 0`.
- Watch `via_getprices` in the response. If it climbs toward `codes_ok`, offers
  is degrading and we are silently back on the phantom default price.

It records HeroSMS's real per-route wholesale into
`routes.herosms_cost_cents` + `herosms_physical_count` / `herosms_total_count` /
`herosms_checked_at`, and hides routes HeroSMS cannot serve. **It deliberately
does not touch `retail_credits`** — repricing is the separate owner decision
above; this function exists to stop us selling what we cannot deliver.

The bug it fixes: after the cutover, HeroSMS rows still held SMSPVA's frozen
`last_cost_cents`, and `create-order`'s graceful degrade did
`liveCost ??= route.last_cost_cents/100`. For routes HeroSMS cannot serve at all
`livePriceUsd` returns null, the **stale SMSPVA cost passed the margin gate**,
and the reservation then failed `NO_NUMBERS` — charging and refunding the user
and telling them to "try another country". The fallback is now provider-scoped,
so a HeroSMS route can only fall back to a HeroSMS cost. First run hid **4,849**
routes (active HeroSMS 10,049 → 5,198); ~3× more than estimated.

Guards worth keeping, each matching a failure this codebase has already had: it
**aborts without writing if every price fetch fails** (a dead key must not hide
the catalog), skips routes whose service code failed *this* run rather than
reading a failed fetch as "not served", destructures every read error, and
enforces `blocked_routes` and `MAX_WHOLESALE_CENTS` — neither of which was
enforceable on HeroSMS rows before it existed.

`herosms_physical_count` is the **real-SIM** count (vs VoIP), confirmed against
HeroSMS's own UI: every country it labels "Only virtual" reports 0. **4,046 of
the 5,198 active HeroSMS routes have physical stock.** Stored and not yet used
for steering — that is the open lever for the Meta services.

**Credit packs** (`Models/CreditPack.swift` + `Products.storekit` + `_shared/iap.ts` `PRODUCT_TO_CREDITS`): 5/$2.99, 12/$5.99 (MOST POPULAR), 30/$12.99, 60/**$24.99**, 150/**$59.99** (BEST VALUE) — a strictly improving per-credit ladder (each pack beats stacking smaller ones): $0.598 → $0.499 → $0.433 → $0.417 → $0.400. The per-credit label is computed **live** from the StoreKit price in `IAPStore.perCredit`, so it never drifts; production prices must be set to match in App Store Connect.

**USD and EUR were realigned on 2026-07-31 (owner decision) — the numbers above
are now what BOTH storefronts bill.** Until then the US paid *less*: `credits.12`
was **$4.99** against €5.99 and `credits.30` **$11.99** against €12.99.

The cause was the base territory, and it is worth knowing because it will
recur: `credits.5/12/30` were anchored to **FRA**, so their dollar price was
*derived* from the euro one; `credits.60/150` were anchored to **USA**. Mixing
anchors across a single ladder is what let it drift. Fixed by adding an explicit
USA manual price to 12 and 30 while leaving FRA the base — so only USD moved and
every other territory (DEU/ESP €5.99, GBR £4.99, CAN $6.99, AUS $7.99, JPN ¥800)
is untouched. Verified after the write.

**That drift had inverted the ladder in the US, on the top revenue product.**
At $11.99/30 and $24.99/60 the 30-pack was **$0.3997**/credit and the 60-pack
**$0.4165** — so two 30-packs bought 60 credits for **$23.98**, beating the
$24.99 60-pack. The 60-pack was strictly dominated. The US ladder is now
strictly improving again and identical to the EUR one:

| pack | US price | per credit |
|---|---|---|
| 5 | $2.99 | $0.598 |
| 12 | $5.99 | $0.499 |
| 30 | $12.99 | $0.433 |
| 60 | $24.99 | $0.417 |
| 150 | $59.99 | $0.400 |

Apple proceeds went $4.24 → **$5.09** on the 12-pack and $10.19 → **$11.04** on
the 30-pack. A price change needs no review and takes effect immediately, but
**`revenue_snapshot` reads the signed `price` out of each receipt**, so
historical rows keep the old amounts and are still correct — do not "fix" them.
Confirm against `/v1/inAppPurchasePriceSchedules/<iap-id>/{manual,automatic}Prices`
before acting on any of these numbers; this file has been wrong about them twice.

**The 60 and 150 packs are the LIVE ASC prices, read back from the API on
2026-07-25 — this file previously claimed $22.99/$49.99, which was never what
the store would have billed.** **`credits.60` is now `APPROVED` and SELLING** —
verified 2026-07-30 both on `/v1/apps/6774768570/inAppPurchasesV2` and by two
live `$24.99 USD` purchases within 20 minutes of each other. This file said it
had "**never** been approved" and that the largest purchasable pack was 30
credits; that is wrong, and it mattered — the 60-pack is now the **top revenue
product**, out-earning everything else in the 24h to 2026-07-30. **All five packs now read
`APPROVED` (verified 2026-08-02)** — `credits.150` cleared review after being
submitted 2026-07-30 06:53Z, so the full ladder is purchasable.

Check `state` on `/v1/apps/6774768570/inAppPurchasesV2` before assuming the
ladder the code defines is the ladder a user sees — and note this file has now
been wrong about it twice. (Product-level `state` is unreliable for
*submittability* — see Release prep — but `APPROVED` vs not is trustworthy.)

### Temporary EMAIL addresses — the third product line (2026-07-30)

Temp mailboxes on three real consumer domains, from HeroSMS. **outlook.com and
hotmail.com are FREE and are the DEFAULT; gmail.com costs 1 credit** (7.5× at
$0.04 wholesale, clearing `MIN_MARGIN = 6.0`, so no pricing constant changed).

**icloud.com was REMOVED 2026-07-31 (owner decision)** — handing out throwaway
addresses on Apple's own consumer domain, from an app distributed on Apple's
store, is an avoidable review risk for a tier that earned nothing. It had **zero
orders ever**, so nothing was stranded. The removal is enforced by deleting the
key from `PRICING`: `create-email-order` rejects any domain absent from that map
with `domain_unavailable`, so no separate blocklist exists. **`PRICING` is
duplicated in `create-email-order` and `email-domains` — change both together**
(this file's own standing warning about duplicated constants).

**Render order is FREE first**, reversing the original "paid first" rule. That
rule existed because the free pair is the scarcest inventory and leading with it
risks a picker whose top row reads "Out of stock" — but the client defaults to
`first(where: { $0.inStock })`, so an empty outlook.com already falls through to
hotmail.com and then gmail.com. Free-first is correct because e-mail exists to
**acquire users, not to earn**: the paid tier is 1 credit against an SMS median
of 16.

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

**The free tier is the SCARCEST inventory**, two to three orders of magnitude
below gmail/icloud. It is also the only thing with no credit gate, so
`begin_email_order` enforces **N free per user per UTC day (default 3, tunable
via `app_config.email_free_daily_cap`)** under the same advisory lock. And
`cost_credits >= 0` is deliberate: `wallet_spend` RAISES on a non-positive
amount, so the free path skips the spend entirely rather than calling it with 0.

`site` comes from `services.domain`, populated for **254 of 265** visible
services — the other 11 cannot offer email at all and are filtered out of the
picker rather than failing at checkout.

**First real activation delivered 2026-07-30**: leboncoin, free tier,
`status = received`.

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

`routes.pool_rate_pct` is 5sim's published 30-day rate for the **exact pool the
route buys from** (`routes.pool_operator`), written hourly by `sync-5sim`. It
covers roughly **1,760 of 4,420** active 5sim routes (08-04: 1,373 positive,
389 zero) and is
the number the country row renders. This replaced `service_country_ranks` as the
tie-break. Coverage moves every hour — re-query before quoting it.

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

### Quote p90, never p50, next to a running clock

The waiting screen printed *"Codes usually arrive in about 59s"* — the **median**,
i.e. wrong for half of all codes by definition — beside a live timer and (at the
time) a ✕ that destroyed a paid order. Live band is p50 59s / **p90 161s**.
The ✕ is no longer destructive — see the waiting-screen note below — but the
quoting rule stands on its own.

Measured 2026-07-28, every user's first order that got a number: **28 of 37 were
cancelled and NOT ONE ever produced a code**; the 9 who let the window run
delivered 33%. Median first-timer bail: **104s** — past our stated number, well
short of the real one. `Service.typicalWaitSentence` now quotes p90 rounded
**up** ("Most codes arrive within 3 min"). That used to coincide exactly with the
180s minimum hold; **since the hold dropped to 90s the two no longer agree**, so
the screen now quotes a wait roughly 2× the window in which cancelling is
blocked. That is the honest ordering (quote the real p90, don't trap the user),
but do not "tidy" one number into the other — they answer different questions.
`typicalWaitShort` keeps p50 for browse/compare surfaces, where there is no
clock and no destructive button.

This is the seed-`etaSeconds` bug one layer up (28s promised against 53s actual):
that fix corrected the data source and kept the framing.

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

### Cold launch — the splash, and why readiness is not a timer

`AppState` starts from `SeedData` with `routes = []`, so `cost(for:country:)`
returns nil for **every** pair. Before `SplashScreen` existed the launch was:
blank system launch screen → a bare `ProgressView` → a Home screen whose primary
CTA read **"Unavailable · Pick another country"** for the whole fetch. The seed
default pair is WhatsApp/United States, which is in `blocked_routes` and never
bookable, so it stayed wrong until `applyStartupSelection()` ran at the END of
the chain. A first-run user met a screen saying the product was unavailable —
expensive here specifically, because activation is a single-session event
(median signup → first order is 2 minutes).

- **`AppState.coldStart(api:)`** owns the sequence and publishes `bootPhase` +
  `bootProgress` from steps that actually completed. **Never fill that bar on a
  timer** — a synthetic bar is the same class of claim as a seeded success rate.
- **Readiness is NOT "the chain finished".** The two eSIM fetches are read only
  by the eSIM tab, so they run *after* `bootPhase = .ready`, behind the revealed
  UI, instead of holding a correct Home screen behind them.
- **`loadCatalog` returns `Bool`.** It used to be `-> Void` with a bare
  `catch { /* keep current state */ }`, so an offline launch silently kept the
  30-service seed stub and rendered a full Home screen on which every service
  read "Unavailable" — indistinguishable from "this product is broken". The
  splash now offers **Try again** / **Continue anyway**. It still keeps existing
  data when a *foreground* refresh fails; only the cold path treats it as failure.
- The splash sits **above** the maintenance overlay but is suppressed once
  maintenance is known active — that screen is the honest answer and must not
  wait behind five more fetches.
- Measured 2026-07-30: catalog = 18,492 routes, **3.48 MB raw / 179 KB gzipped**,
  ~0.8–1.5s, and it is one of **six sequential round-trips** (~3s total).
  Overlapping them would genuinely help, but `AppState` is a plain `@Observable`
  with no actor isolation, so `async let` over methods that all mutate `self` is
  a data race, not a speed-up. Doing it safely means making the API calls return
  values instead of mutating — a separate change.

**The logo is `BrandWordmark`: a green `v` + `SMS`.** The old lockup was a
`bolt.fill` in a rounded-rect tile — a generic badge that said nothing about the
product. The `v` takes `theme.ink` (the user-selectable accent) and **not**
`theme.live`, which is the semantic success green; spending that colour on
branding is the conflation `AccentColor` documents as forbidden. On the splash
the letters type on and then the `v` rotates as the loading indicator, which is
why there is no spinner. The progress bar appears only after 1.2s and the
slow-connection line after 3.5s, so a healthy launch shows neither.

**Appearance is `AppearanceMode` — System / Light / Dark, defaulting to System.**
It replaced a `pref.isDark` Bool that defaulted to **false**, so the app and the
splash rendered LIGHT on a dark-mode phone until the user found the toggle, and
there was no way to say "follow my device" at all. `colorScheme` is
`ColorScheme?` on purpose: **nil is what actually lets the device decide**, which
a Bool cannot express. Migration keys on *explicitly set vs never touched* —
`defaults.bool(forKey:)` returns false for both, which is exactly how "never
chose" became "wants light" for everyone — so `object(forKey:)` decides, and the
legacy key is deliberately not rewritten so a downgrade to 1.4/1.5 still works.
`ContentView` reads the ambient `colorScheme` **above** its own
`.preferredColorScheme`, because that modifier pushes a scheme *down* to children
and `.system` must resolve against the device's.

### The service picker says where a service IS bookable

`ServiceSheet` fixes the COUNTRY and varies the service — the mirror of
`CountrySheet` — so a service with no route in the selected country used to
render a bare **"Unavailable"** with nothing on the row naming that country.
Measured 2026-07-30: **all visible services (265 then, 254 now) are bookable in at least one
country**, so the word was wrong every single time it appeared. It read as "not
at all" for a median of **79 services per country** (Turkey: 165 of 265 — 62% of
the catalog looked dead), and the services hidden on a Turkey selection are
available in **68 of the 69 countries**.

Worse, the row was dimmed to look disabled but stayed tappable and the tap
WORKED — the handler already relocated via `bestCountry`. The label was steering
users away from taps that would have succeeded.

**`AppState.pickDestination(for:)` is the single shared definition** used by both
the picker row and the tap handler, so the row cannot promise a country the tap
does not deliver. A row promising Romania while the tap lands in Colombia would
be a worse lie than the one it replaced. "Unavailable" now survives only for
bookable-nowhere — the one case where it is true — and that case is `disabled`,
because the tap would otherwise set the service without moving the country and
strand the user on a Home screen whose only button is a disabled "Unavailable".
The badge is scored against the DESTINATION route, and the Affordable filter
judges by the price the row shows (it used to test `cost(for:country:)` alone and
silently drop every service without a route here).

### Palette + Liquid Glass (2026-07-30)

**The brand accent is GREEN `#279400`** (owner decision, 2026-07-30). It was
briefly switched to blue `#0057FF` and switched back; the blue remains available
as the retuned `.blue` accent option.

**Known and accepted: white on `#279400` measures 3.95:1**, below WCAG AA's
4.5:1 for normal text, so primary buttons do not pass AA. On the background the
accent measures 3.68:1. This is a deliberate brand choice, not an oversight —
do not "fix" it by silently changing the hex. If it is ever revisited,
`#1F7A00` is the same green a few steps darker and measures **5.47:1** against
white while still reading as the brand.

Light `bg` is warm paper **`#F8F7F4`** (was iOS's cool `#F2F2F7`) with `elev`
left pure white, so cards read as genuinely raised. Dark mode is unchanged. The
warm background is kept independently of the accent.

Three things that must move together, each a real trap:
- **The `AccentColor` default is declared in FOUR places** — `Theme.light(_:)`,
  `Theme.dark(_:)`, `AuthGate`'s `@AppStorage` *and* its own
  `?? .green` fallback, plus `AppState`'s init fallback. Missing one is not
  hypothetical: the blue experiment changed three and left `AuthGate:28` on
  green, so an unreadable preference would have resolved to a different colour
  depending on which screen asked. Grep for all of them together.
- **`Assets.xcassets/LaunchBackground.colorset` must match `theme.bg`.** It is
  the static launch screen, so a mismatch is a visible colour flash on every
  cold launch before SwiftUI has drawn anything.
- **`live`/`warn`/`fail` are untouched and must stay that way.** Green still
  means "your code arrived" / "your credits came back". Now that the accent is
  no longer green, that separation is *stronger* than before — but it also means
  green appearing anywhere is a semantic claim, not decoration.

**Liquid Glass is `.glassPanel(_:interactive:)` in `DesignSystem/Glass.swift`,
and the `#available(iOS 26)` guard lives there and nowhere else.** The
deployment target is **18.0**, so the majority of devices only ever render the
fallback (near-opaque fill over `.ultraThinMaterial` with a hairline border) —
which is precisely why scattering the guard would let one surface drift without
anyone noticing.

Applied ONLY to chrome that floats over content: the tab bar, `ResumeBar`, and
the eSIM map's selection card / globe button / warning pill. Not to inline
cards — Apple's guidance is that glass belongs to the navigation layer, and on
ordinary cards it puts text over unpredictable backgrounds while destroying the
elevation hierarchy `theme.elev` already expresses.

**`.glassEffect` RENDERS but is not HIT-TESTABLE — `GlassPanel` therefore always
appends `.contentShape(shape)`, and that line is load-bearing.** The filled
`.background(Capsule())` it replaced did contribute a touch surface; glass does
not. So every gap the glass appeared to cover — the tab bar's 6pt padding, the
4pt between its buttons — went transparent to touch and the tap fell through to
whatever was behind. On the eSIM tab that is a full-bleed MapKit view which
`.ignoresSafeArea(edges: .bottom)` extends *under* the tab bar, so a slightly
misplaced tab tap silently panned the map instead. Reported as "the click
registers behind it". Never apply `glassEffect` directly; go through
`.glassPanel`.

**`interactive` is only for glass that IS the control** (a single icon button).
On a container that holds its own buttons — tab bar, resume bar — touch-reactive
glass competes with the children for the gesture and reads as lag on first taps.

**Glass over a saturated background is the failure case, and the eSIM tab is
exactly that** (a full-bleed map, the default view). Inactive tab-bar icons are
at their weakest over bright ocean. The map's cluster bubbles also need an
**opaque** ring in `theme.elev`: the original translucent-white ring let a
bubble blend into whatever was under it — invisible as blue-on-ocean, and
nearly as bad as green-on-Europe, since the landmass is green too.

### Localization: `Text("literal")` is localized, a `String` return is NOT

`Text("Preparing")` picks up the catalog automatically because the literal
becomes a `LocalizedStringKey`. A computed property returning a plain `String`
does not — it never enters `Localizable.xcstrings` at all, so it cannot even be
*seen* as missing by an audit of the file. The whole eSIM tab passed a
file-level "0 untranslated" check while still rendering **"14 MB/day"** in
French, and that was only caught by screenshotting a non-English locale.

Anything user-facing returned as `String` needs `String(localized:)`:
`EsimStatus.label`, `EsimPlan.validityLabel`, `perDayLabel`,
`dataRemainingLabel`, and the expiry line in `EsimActivityScreen` all needed it.
**`Metric(label:)` takes a plain `String`** and does `Text(label.uppercased())`,
so every call site must pass `String(localized:)` itself.

Two more rules, both learned here:
- **Never interpolate a pluralised noun into a sentence.** `"Show %lld more %@"`
  with `%@` = "plan"/"plans" cannot be translated — German and the Romance
  languages inflect the adjective to agree. Ship four complete sentences instead.
- **Verify format specifiers mechanically.** A dropped or reordered `%lld`/`%@`
  is a runtime crash and is invisible in review. Compare the multiset of
  specifiers in every translation against its key, and normalise positional
  form (`%1$@`) first — it is equivalent, and a translation may legitimately
  *omit* a later argument (Italian and Japanese do exactly that for the English
  plural-`s` fragment in "You're %lld credit%@ short…").

### The map's camera callback fires EVERY FRAME

`.onMapCameraChange(frequency: .continuous)` fires per frame of a pan or pinch.
`EsimMapView` derives `clusters` from `span`, so assigning `span` on every
callback invalidated the computed property, re-bucketed all 66 pins, and made
SwiftUI tear down and rebuild **every annotation — each containing a
`CodeFlag` — at 60–120 fps**. That is a per-frame rebuild of the whole
annotation set, and it is why the map felt slow and its taps unreliable while
being dragged.

`commit(_:)` now adopts a new span only when it differs by >15%, which is well
below the ~1.6× step needed for the grid cell to regroup anything — so clusters
still merge and split visibly during a pinch, while a pan (which does not change
the span at all) rebuilds nothing. If you add anything else derived from the
live camera, throttle it the same way.

**Derived catalog data must be STORED, not computed.** `AppState` is
`@Observable`, so a computed property is re-evaluated on every body evaluation
of every view that reads it. `esimCountries` walked all **1,081** plans and
rebuilt a dictionary — twice per `HomeScreen` redraw, once per `EsimStoreScreen`
redraw, continuously while the map was being dragged — and returned a
freshly-allocated array each time, so SwiftUI saw new `ForEach` data and rebuilt
every annotation. Same for `esimPlans(forCountry:)`, a filter+sort over 1,081
called ~4× per body on the plans screen. Both are now derived once inside
`loadEsimCatalog` (`esimCountries`, `esimPlansByCountry`), and
`EsimMapView.clusters` is `@State` refreshed on change rather than computed.

**Do not put `.animation(_:value:)` on a container holding the `Map`.** It
applies to every descendant, so an unrelated state change animates MapKit's own
layout. `SegmentedTabs` and the browse toggle already wrap their state changes
in `withAnimation`, which the branch `.transition`s pick up.

### Pausing the eSIM line (backend only, no build) — 2026-07-31

**eSIMs are PAUSED as of 2026-07-31** while the owner switches eSIM providers.

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

### The eSIM store — why it shows FEWER plans than the catalog has

The store used to render every active plan for a country in one price-ascending
list. Measured against the live catalog on 2026-07-30, that list is unusable for
two independent reasons, and neither is fixable with a nicer row design:

- **382 of 1,081 active plans (35.3%) are DOMINATED** — another plan in the same
  country gives *at least as much data, for at least as many days, at the same
  price or less*. Japan sells 490 MB/1 day for **6** credits and 490 MB/**7
  days** for **5** — cheaper *and* longer. Sorting by price ascending puts the
  strictly worse plan first.
- **187 (country, data, days) triples have more than one plan.** Japan lists
  "1 GB · 1 day" **four** times at 9/10/11/12 credits with nothing on the row to
  tell them apart — because there *is* nothing; the extra 3 credits buy nothing.

`EsimPlanRanking.frontier()` keeps only the Pareto frontier over
(data ↑, days ↑, price ↓), collapsing exact three-axis ties to one row. Japan's
7-day view goes 5 rows → 3. Two rules in it are load-bearing:

- **Plans missing data/validity/price are never dropped.** They cannot be
  compared, and hiding a row because a provider column was NULL would let a
  catalog gap decide what the user may see.
- **The filter is never silent.** A "Show N more plans" control states exactly
  how many rows are held back. It is a default, not a decision made for them.

Duration is the FIRST axis, not a filter. It is the only one the traveller
already knows before opening the app. The catalog is clean here — 1/7/15/30/180
days cover 1,078 of 1,081 plans — and the chips are derived from the data, so a
new duration appears without a code change. The default is **the duration
closest to 7 days**: 1-day plans are 496 of 1,081 purely because the provider
lists many, so defaulting to the modal duration would open every country on
single-day plans.

`credits/GB` is shown because it is the one number that makes different sizes
comparable, and it is arithmetic on **our own retail price** — not a provider
quality signal. There is deliberately no speed/coverage/reliability score on
these screens: we do not measure any of that, and the standing rule is to show
nothing rather than a plausible-looking guess.

**The map is `EsimMapView` (MapKit) and it clusters — that is not optional.**
35 of the 66 countries are European, so one pin per country is a solid blob over
Europe at world zoom. Pins are grid-bucketed against the live camera span
(`onMapCameraChange`), so bubbles become flags as you pinch. Two things learned
the hard way:

- **MapKit aspect-FILLS a requested region, it does not fit it.** On a 0.46-aspect
  phone the whole world is simply not reachable in flat mode: `MKMapRect.world`
  matched the view's *height* and cropped longitude to ~140°, and a 120°×150°
  region cropped to ~60° over Africa. The opening camera therefore centres on the
  densest part of the catalog instead of pretending to show everything.
- **A price badge and a cluster count are the same glyph.** Cameroon's "33"
  (credits) was indistinguishable from a green "13" (a 13-country cluster) — same
  size, same badge. The price chip now always carries its unit ("33 cr") and a
  distinct light treatment.

`CountryGeo` is a static ISO2→centroid table, not geocoding (CLGeocoder is a
rate-limited network round-trip per country, which would make the map's contents
depend on connectivity). `CountryGeo.missingCodes(in:)` exists so a catalog
country with no pin is *assertable* — the map renders a "N not on map" note
rather than silently dropping a country it can sell. Currently 66/66 are placed.

### Order-state honesty (client) — the reconcile invariant

**`check-order` is NOT the authority on whether an order ended.** It polls the
live SMS provider and returns HTTP 502 `provider_unreachable` whenever that
throws, so the one moment you most need an answer (provider is sick) is exactly
when it can't give one. `pollActiveOrder` used to `catch { /* transient */ }`
and keep waiting — so with a flaky provider the 60s cron would expire AND refund
an order while the screen sat on a frozen "Waiting / 00:00" indefinitely. The
user has been made whole and has no idea; this is the state that generates
refund requests and 1-star reviews.

The invariant now, in `AppState` (2026-07-25):
- **`OrdersAPI.fetch(orderId:)`** reads the order row straight from PostgREST.
  No provider in the path — the cron has already written `expired`/`canceled`
  plus the refund. This is the authority. Anything asking "did it end?" uses it.
- **`pollActiveOrder`** falls back to that read after 2 consecutive check
  failures, or immediately once past `expiresAt` + grace.
- **`checkNow`** (the "Check now" button) ALWAYS falls back — an explicit tap
  must never dead-end on a swallowed error.
- **`WaitingScreen`** independently reconciles every 3s once past expiry, and
  renders "Closing…" instead of a stopped `00:00`. Never show a dead countdown
  as a live one.
- **One `apply()`** handles every terminal status. `canceled` used to fall into
  `default: break` and strand the UI even on a *successful* poll — never write a
  status switch here without covering all cases.
- `reconcileActiveOrder` swallows its own failure **on purpose**: if we truly
  can't reach the DB we assert nothing, because inventing a terminal state is
  its own lie.
- **Reroll and cancel hold `isPlacingOrder`** while they mutate the row.
  Without it the background reconcile reads the intermediate `canceled` and
  bounces the user to recovery mid-reroll.

Refunds must be **visible twice**: at the moment (`RecoveryContext.refundedCredits`
→ "+N credits refunded" on the recovery card) and **durably** (`Order.isRefunded`
→ "+N cr refunded" on the history row). "Expired" with no money line reads as
"I paid and got nothing" even though the refund landed. Both terminal paths
refund unconditionally server-side, so status alone is a sound signal.

**The ✕ on the waiting screen LEAVES — it no longer cancels (changed
2026-07-30).** This file previously said the opposite, and the opposite was the
bug. The glyph reads as "back", and the user *has* to leave to paste the number
into another app, so coming back is the NORMAL path rather than an edge case.
Making it destructive — first instantly, later behind a confirmation dialog —
meant the ordinary action of stepping away was the same button that threw away a
paid, in-flight order.

Now: ✕ sets `flow = nil`, the order keeps running, and **`Components/ResumeBar.swift`**
sits above the tab bar on every tab whenever something is waiting. That bar is
what makes non-destructive close honest: without a way back, a live order simply
vanishes from view and the user reasonably assumes it died. It reads the waiting
order from the LIST, not from `activeOrder` — that is cleared when the flow
closes, which is exactly the moment the bar must appear.

Cancelling is still available and still refunds, as an explicit labelled
**"Cancel & refund N cr"** lower down the screen, still gated by the minimum hold (now 90s).
A named destructive action does not need a confirmation dialog the way a ✕ did.

### The minimum hold (now 90s), and the late-code rescue (2026-07-27)

⚠️ **`MIN_HOLD_SECONDS` is 90, NOT 180 — lowered 2026-08-03.** This whole
section was written for 180 and much of the reasoning below still quotes it;
the *arguments* stand, the *number* does not. Read `cancel-order/index.ts:44`
before quoting a figure. 1.8's release notes tell users "90 seconds instead of
3 minutes", so the shipped copy and the constant agree.

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

Client side, **every route carries a label and there are exactly two of them**
(`DeliveryRecord` in `Components/SuccessBadge.swift`): **"Not tested"** or
**"Worked X of Y times"**. Rendered unconditionally in ServiceSheet, CountrySheet,
Home and Checkout.

The third state is what was wrong. A route we had never sold rendered **no badge
at all**, and an absent badge reads as *fine*, not as *unknown* — which described
**17,471 of 17,804 active routes**. Silence was the answer to almost every "is
this any good?".

Two rules that look like details and are not:
- **A seeded rate is `.notTested`.** SMSPVA's per-country grade (323 routes) is a
  vendor's number about a route we may never have sold once. The old muted
  "~40% estimate" was still a *number*, and users read numbers as evidence.
- **"2 of 7", never "29%".** A percentage off a 7-order sample wears the
  confidence of a 700-order one; the raw pair carries its own uncertainty.

`routes.success_codes` is the numerator (backfilled + written by
`refresh_route_observed_success`) — deliberately stored rather than derived from
the rounded `success_rate`, because an off-by-one in "worked N times" discredits
the whole label. **Colour still carries confidence**: `.notTested` is always
muted; green/amber/red are reserved for measured records.

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
- **`create-order` refuses BEFORE charging when the provider is broke.** It reads `app_config.<provider>_health`, and if that reading is under 5 minutes old and `balance_usd` is below this order's own `maxCostUsd`, it refuses up front rather than charging and refunding. It fails **OPEN** on stale or missing data, and maps to the already-shipped `provider_unreachable` copy. ⚠️ This is why a missing `<provider>_health` row is dangerous: the guard silently stops guarding. The eSIM and e-mail order paths still charge-then-refund — extend the same guard if either grows volume.
- **Every SMSPVA response is an envelope: `{statusCode, data}`.** The value lives at `r.data.x`, never `r.x`. Reading the wrong level yields `NaN`/`undefined` and, on the balance path, wrote nothing at all — which looks *identical to a healthy provider*. Use `isOk(r)` before touching `r.data`.
- **The Apple receipt verifier must chain to Apple's PINNED root.** `_shared/iap.ts` once took the certificate out of the attacker-supplied JWS header and verified the signature against that same certificate — circular, so anyone with a free Sign-in-with-Apple account could self-sign a payload for `credits.150` and mint credits forever. It now walks every hop of `x5c` and requires termination at **Apple Root CA - G3, matched by SHA-256 thumbprint** (pinning by subject name is defeated by a self-signed cert named "Apple Root CA - G3"), plus Apple's receipt-signing OID `1.2.840.113635.100.6.11.1` on the leaf, and validity checked at `signedDate` not `now()`. **Pin the ROOT ONLY** — the leaf expires 2027-10-13 and Apple rotates intermediates routinely, so pinning anything lower turns a normal rotation into a total purchase outage. No OCSP: a live round-trip to Apple inside checkout would fail every legitimate purchase during an Apple outage.
- **Credits are granted only when `tx.environment === "Production"`.** Sandbox/Xcode receipts are genuine Apple-signed transactions that cost **$0** — any Apple ID can switch to a Sandbox account in Settings and "buy" packs free (this already happened: receipt id 21 credited a real user 12 credits 39s after signup). Non-production receipts are still persisted for the audit trail and still return `ok:true` so the client calls `tx.finish()` and StoreKit stops redelivering — they just move no balance and pay no referral reward. **This gate is worthless without the chain verification above**, because `environment` is just another field a forger sets to `"Production"`.
- **`order_status` cannot grow a value without shipping the app first.** iOS `OrderStatus` (`Components/Pills.swift`) is a plain `String` enum with **no unknown case**, so a status it doesn't recognise throws on decode and breaks the Orders tab for everyone on the released build. This is why `begin_order` writes a pre-reservation row as ordinary `'waiting'` with a null `smspva_id` instead of adding a `'pending'` state.
- **Charge and order row must be written together.** `create-order` used to charge and only insert the row after a provider reservation succeeded, so every failure left a spend+refund pointing at nothing: **258 spends vs 126 orders — 51% of paid attempts invisible**, and the real failure rate unmeasurable. `begin_order()` now does dedupe + insert + charge in one transaction under a per-user advisory lock (the old dedupe `SELECT`ed ~120 lines before the `INSERT`, with a multi-second provider call between, so two concurrent requests both passed it and both charged). A stranded row self-heals: the poller skips it for polling (`smspva_id is not null`) but the expiry sweep still closes and refunds it.
- **Never write a status transition without an atomic claim.** Every `orders` status write is `.eq("status","waiting")` + row-count check. `check-order`'s `received` branch was the one exception and could overwrite a terminal state the expiry cron had already set — handing a user a working code they'd *already been refunded for*.
- **A status claim and its refund must be ONE transaction, never two round-trips.** Where they are split, a worker killed in between leaves a TERMINAL row with the charge never returned — and the expiry sweeps only select `status='waiting'`, so nothing ever revisits it. No timeout value fixes this; a TypeScript rollback cannot either, because the process is gone. Seven paths had it wrong and were fixed one at a time across 2026-07-31 and 08-02 (`expire_order_claim`, `expire_order_early_claim`, `fail_esim_order_claim`, `close_email_order_claim`). If you add an eighth close path, it goes through a claim function.
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
- **The watchdog is plain SQL — keep it that way.** `run_watchdog()` (pg_cron `*/10`, migration `20260722050000`) checks job freshness (poller heartbeat, `routes`/`esim_plans.last_checked_at`, digest stamp, sync cursors via `app_config.updated_at` — maintained by the `app_config_touch` trigger, so cursor upserts don't need to set it) plus any non-2xx row in `net._http_response`, and writes its verdict to `app_config.'watchdog'`. `telegram-notify` (minutely) turns that into pages (6h re-alert, ✅ on recovery); `/balance` shows the verdict too. It deliberately uses **no edge function, no CRON_SECRET, no HTTP** so it still evaluates when the whole edge/secret layer is broken. If you add a scheduled job, give it a freshness signal and a check here. Residual blind spot: telegram-notify's own death = digest silence >7h (documented in `docs/autopilot-runbook.md`).
- **IAP environment check constraint must allow `'Xcode'`** for local StoreKit testing alongside `'Sandbox'`/`'Production'`. See migration `..._iap_allow_xcode_env.sql`.
- **A status string written from TS is NOT checked against the enum — and the error is discarded.** `create-esim-order`'s failure path wrote `status: "canceled"`, which is a member of `order_status` but **not** of `esim_status` (`provisioning, installed, active, depleted, expired, refunded, failed`). PostgREST rejected the UPDATE with 22P02, the code did `const { data: claimed } = await ...` without destructuring `error`, so `claimed` came back empty and the function **returned without refunding**. Every failed eSIM purchase charged the user and silently kept the money. When you write a status literal from an edge function, check it against `pg_enum` — the two enums share several names and differ in exactly the ones that matter.
- **`supabase-js` RETURNS errors, it does not throw.** Every `await sb.rpc("wallet_credit", …)` that discards `{ error }` is a silent money bug: `wallet_credit` raises on a non-positive amount and on a missing wallet row, so the status claim commits, the balance never moves, and the user gets a push saying "N credits refunded". Four sites had this. Destructure the error at every money call.
- **`revoke execute … from anon, authenticated` IS A NO-OP while PUBLIC holds the grant.** `CREATE FUNCTION` grants EXECUTE to PUBLIC by default, and anon/authenticated are members of PUBLIC — so the revoke line present on ~35 migrations changes nothing on its own, and the function stays callable at `/rest/v1/rpc/<name>`. Read the ACL, not the migration: a secured function is `postgres=X/postgres | service_role=X/postgres`, a leaking one has a **leading `=X/postgres`** (empty grantee = PUBLIC). Caught 2026-07-27 when `revenue_snapshot` — the first function created after the default-privileges hardening — shipped world-callable *with* its revoke line, exposing gross revenue, wholesale cost and profit to anyone holding the publishable key (SECURITY DEFINER, so RLS was no help). `20260727211000` revoked the *default* for anon/authenticated but **not for PUBLIC**, so every future function kept arriving public. Fixed in `20260727240000`: `alter default privileges in schema public revoke execute on functions from public`, plus explicit `from public, anon, authenticated` on the four affected functions. Assert with `has_function_privilege('anon', p.oid,'execute')` — it must be **0 rows** across `pg_proc` in `public`; a passing `revoke` statement proves nothing.
- **`ALTER DEFAULT PRIVILEGES` grants `anon`/`authenticated` rights on every FUTURE object.** Until 2026-07-27 that was `arwdDxtm` on future tables and `EXECUTE` on future functions — so any new table missing `enable row level security` would have been world-**writable** at `/rest/v1/<table>`, and any new SECURITY DEFINER function missing its revoke callable at `/rest/v1/rpc/<name>`. That is how `run_watchdog` became public. The postgres-owned defaults are now revoked (SELECT retained; RLS still governs rows); **the `supabase_admin` half is NOT applied** — it needs membership in that role, which the CLI's postgres connection lacks. Statements are in `20260727211000_default_privileges.sql`. Note this is a backstop, not a licence to skip the explicit `revoke execute` on every new function.
- **A one-line refactor that changes a watchdog threshold is a monitoring outage.** Rebuilding `run_watchdog` for unrelated coverage silently narrowed the delivery check from 24h/≥10 to 6h/≥8 **and deleted its second branch** (≥20 conclusive at <10%). Measured: the max conclusive orders in ANY 6h window over 30 days is 8, against a gate of 8 — the check became effectively unreachable, leaving zero delivery-outcome coverage. When you re-create a function from `pg_get_functiondef`, diff it against the prior definition clause by clause; the dump is also **truncated** by most tooling, which is how a nonexistent `url` column on `net._http_response` got invented in the same rewrite.
- **A constant duplicated across files WILL drift.** `MAX_WHOLESALE_CENTS` lives in three sync functions (and as `MAX_ORDER_COST_USD` in `poll-active-orders`, and as `LOW_BALANCE_USD` in `_shared/opsFormat.ts`). Changing it in one place on 2026-07-27 stripped 1,432 routes of their carrier pin and premium price, and left the digest warning at $20 while the pager fired at $37.50. Same for `CREDIT_DIVISOR` (the SMSPVA 0.05 is **two** copies — `sync-prices` and `sync-smspva-operators` — and `sync-herosms` carries a deliberately DIFFERENT 0.025, so "consolidating" the three into one constant would silently reprice a whole provider) and `ESIM_MARGIN`/`CREDIT_VALUE_USD` (two each). `MAX_WHOLESALE_CENTS`'s three syncs are now `sync-prices`, `sync-smspva-operators` and `sync-herosms`. Change them in one commit or consolidate them into `_shared/`.
- **Deleting an IAP receipt to force StoreKit redelivery can eat the payment.** `iap-verify` used to delete the row when `wallet_credit` failed, assuming StoreKit would retry. But the client runs **two** paths into that endpoint (`Transaction.updates` and the `Transaction.unfinished` sweep), so a concurrent duplicate may already have been answered `already_credited` and called `finish()` — retiring the transaction forever. It now zeroes `granted_credits` (keeping both the audit trail and the replay guard), and the duplicate branch refuses to confirm a receipt that has no matching `wallet_transactions` row.
- **EVERY credit grant is farmable through account deletion unless it is tombstoned OUTSIDE the `auth.users` cascade.** This is the single most repeated money bug in this codebase — it has now been found three times, once per grant. Everything user-scoped cascades, so delete → sign in again erases our only record and mints the grant afresh. Apple *mandates* the Delete Account button, so this is not an edge case. The three grants and their tombstones: **signup +3** → `signup_grants` (hash of the email); **referral +2** → `signup_grants.referral_redeemed_at` (same key); **IAP purchases** → `public.iap_grants` (keyed on Apple's `transaction_id`). Each tombstone table must have **no foreign key to `auth.users`** — a reference there is precisely what deletes the row with the account. The email hash works because Apple's private-relay address is stable per (user, app), so it survives deletion while storing no address; all three fail **open** on a null email, because a missed grant on a real signup costs more than a rare duplicate. **If you add a fourth grant, it needs a tombstone in the same commit.**
- **APNs `aps-environment` is `production`** in the entitlements file (flipped for archiving; set `APNS_ENV=production` secret to match). Flip back to `development` if you need to test push against a dev-token build from Xcode.
- **`Secrets.swift` is gitignored.** Template in `supabase/README.md`. Just `supabaseURL` + `supabaseAnonKey`. The publishable key (`sb_publishable_*`) is fine in client code — it's the new name for the anon key.
- **Logo loading cascades** in `ServiceLogo`: DuckDuckGo ip3 (`icons.duckduckgo.com/ip3/<domain>.ico`) → Google FaviconV2 → SF Symbol on tinted background. URLCache caches across launches. **Clearbit (`logo.clearbit.com`) was removed** — HubSpot sunset the free Logo API on 2025-12-01 and its host no longer resolves; leaving it as source #1 made every logo eat a DNS failure before falling through. Do not re-add it.
- **Logos + flags are bundled** (`VirtualSIM/BundledLogos/<domain>.png`, `VirtualSIM/BundledFlags/<code>.png`). `ServiceLogo`/`FlagImage`/`FlagCircle` render the bundled PNG **first** (via `BundledImageStore.shared`) and only fall back to the network cascade above for catalog entries not yet bundled. The Xcode file-system-synchronized group **flattens** these into the bundle root, so lookup is by flat filename (`Bundle.main.url(forResource: "<key>.png", withExtension: nil)`) — do NOT expect a `BundledLogos/` subdirectory at runtime. Logo key = `Service.domain`; flag key = `Country.flagImageCode` (`uk`→`gb`). After the catalog grows, regenerate + commit with `scripts/fetch-bundled-assets.sh --refresh`, then ship an app update; new services/countries work via the network fallback in the meantime.
- **Apple Sign-In is iOS-native flow** — no JWT secret needed in Supabase (the apple provider config). The dashboard's secret/services-id fields stay blank.
- **Never present seed data as measured fact.** `Service.successRate` is seed data (86–99% across all 268 services, avg 91%) and `Service.swift` says so explicitly. Show only `AppState.successRate(for:country:)` / `deliveryOdds` / `DeliveryNotice`, which are gated on real observed samples, and show **nothing** when there's no measurement. `WaitingScreen` was the last violator — it promised ~91% right after payment on clusters that actually measure ~9%. Same rule for eSIM coverage: the parser returns `null` rather than guess, because a wrong coverage claim is worse than none since the user acts on it.
- **Review prompt must stay incentive-free (App Store 5.6.4).** `OtpScreen` calls Apple's native `@Environment(\.requestReview)` (needs `import StoreKit`) on code delivery, gated by `AppState.shouldRequestReview(forOrderId:)` — fires only from the 2nd successful code onward, at most once per app version, de-duped per order. **Never** tie credits/rewards to leaving a review, and **never** build a custom review UI that deep-links to the App Store page — both are rejectable. A no-strings welcome/bonus credit is fine as long as it isn't conditioned on a review.

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
  Prefer a real build over `swiftc -typecheck` when you can afford it — it
  catches resource/Info.plist/asset problems type-checking cannot. *Historical
  cause, kept because it will recur on the next Xcode update:* Xcode will not
  offer a simulator destination whose runtime is NEWER than its SDK, so when
  only runtime 27.0 was installed against SDK 26.5 there were **no** eligible
  destinations, and `-downloadPlatform iOS -buildVersion 26.5` answered
  `iOS 26.5 is not available for download`. If that returns, the fix is to match
  SDK to an installed runtime (install the newer Xcode), not to chase the old
  runtime. **Archiving for the App Store is still gated separately** by the
  beta-macOS `BuildMachineOSBuild` patch under "Release prep".
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
  in a bare worktree — 95 vs 96 as of 2026-08-02.)
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

## Current state (2026-08-04)

### Inventory — these move hourly. RE-QUERY, don't quote this block.

Every number below has been wrong within a day of being written at least once.
It is a starting point for "is this roughly right", never a citation.

- **iOS**: `MARKETING_VERSION 1.9`, `CURRENT_PROJECT_VERSION 30`, iOS min **18.0**,
  **96** Swift sources, **357** strings / 0 untranslated / 0 specifier reorders.
- **Backend**: **26** edge function dirs besides `_shared`, **13** `_shared` files,
  **136** migration files, **16** pg_cron jobs (all active).
- **Catalog** (08-04 07:15): **5,905** active routes, 5sim **4,417**. Pool rate:
  **1,373 positive / 389 zero / 2,655 unrated**. 268 services (254 visible), 69
  countries. eSIM 1,081 plans, **0 active — line PAUSED**.
- **Evidence**: `rate_source='measured'` = **3 routes**, rebuilding from 0 after
  the cutover. That reset is CORRECT — see "Evidence must describe the provider
  that serves the NEXT order".
- **Balances: 5sim $9.37 (rating 96/96), HeroSMS $9.62.** Both `low`, both at
  alert tier 3 on a `[37.50, 22.50, 11.25, 7.50]` ladder. **Both are near the
  $7.50 single-order ceiling — top up.**
- **App Store**: **1.8 (build 28) is `READY_FOR_SALE`**, and has been since
  2026-08-03 07:03Z — this file claimed `WAITING_FOR_REVIEW` for a full day
  after it went live, which matters because 1.8 is what every current user and
  every new signup is actually running. **Read ASC, not this line.**
  **1.9 is `WAITING_FOR_REVIEW` on build 31** since 2026-08-04 16:07Z, notes in
  13 locales. 1.7/1.6 `READY_FOR_SALE`. All five packs `APPROVED`.
  Builds 29 and 30 are superseded (29 carried the "+3 credits" card; 30 was
  uploaded before the `inviteJoinerCredits` bug was caught). **Cancel-and-
  replace took ~90 seconds end to end** and confirms the note under Release
  prep: an app-version submission is not a one-way door. `PATCH
  reviewSubmissions/<id> {"canceled": true}` → version goes `DEVELOPER_REJECTED`
  → `PATCH appStoreVersions/<id>/relationships/build` → new `reviewSubmission`
  + item + `{"submitted": true}`.
- **Signup grant: 0 — REMOVED PERMANENTLY** (owner decision 2026-08-04 15:42Z,
  `20260804160000`). The product is paid: you want a number, you buy credits.
  It had been 5 → 0 → 1 → 3 → 0 in two days; the reach table that used to live
  here (1 cr → 67 routes, 3 cr → 618, 5 cr → 1,486) is kept only in that
  migration, because reach was never the reason the grant mattered — see the
  two sections below. Rollback is one UPDATE and takes effect on the next
  signup with no deploy.

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

✅ **FIXED 2026-08-04 (`804a6dd`) — the candidates are now ranked by pool rate,
not by array position. NOT IN BUILD 28**, so every shipped build still has the
behaviour above; it needs a release to reach anyone.

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

### Known-open

**Top of the list as of 2026-08-04:**

- 🟠 **The starter list is FIXED in the repo but NOT SHIPPED.** `804a6dd` ranks
  the candidates by pool rate instead of array position; every released build,
  28 included, still lands the whole new-user cohort on one position-picked
  route. See "The grant size decides which ONE route new users land on" for the
  before/after table. **This needs a build to be worth anything** — it is the
  only fix in the tree whose entire value is in a release.
- ✅ **RESOLVED 2026-08-04 — the IAP fix is CONFIRMED working.** A Production
  receipt at 2026-08-03 16:41Z granted credits (`granted_credits > 0`), which is
  the settling evidence this entry asked for. Revenue is proven, not assumed.
  *Original:* every purchase failed `chain_verify_failed` until 2026-08-03
  because the Supabase edge runtime does not implement ECDSA P-384; fixed in
  pure JS via `@noble/curves/p384`.
- 🔴 **Does `pool_rate_pct` predict OUR delivery? Unverified, and the obvious
  query is now KNOWN-CONTAMINATED.** Against HeroSMS orders the same vendor's
  rates correlated **negatively** (r = −0.51, n = 16). Stamped per order as
  `orders.pool_rate_pct` / `pool_pinned`. **Exclude default-landed orders before
  running it** — 16 of the last 20 5sim orders were the app's own pre-selected
  route, placed by users who had no reason to want that service and almost
  certainly never submitted the number anywhere. Scoring those as delivery
  failures measures our steering, not the pool. **If the correlation is not
  positive, the number must come off the row.**
- ⚠️ **Both provider balances are near the funding floor** — 5sim $9.37, HeroSMS
  $9.62, against a $7.50 single-order ceiling. HeroSMS funds SMS *and* the whole
  e-mail line.
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
- ⚠️ **Two migrations are written but NEVER APPLIED** (verified 2026-08-04:
  `expire_order_early_claim` does not exist in `pg_proc` and neither version is
  in `schema_migrations`): `20260803120000_expire_order_early_claim.sql` and
  `20260803121000_clear_foreign_seeded_rates.sql`. The second matters more than
  it sounds — **338 routes still carry `rate_source='seeded'`**, a vendor grade
  inherited from a provider that no longer serves them. The client renders
  seeded as `.notTested` so nothing is currently mis-stated to users, but it is
  stale evidence sitting in the steering tables.

**Found by a 5-agent audit on 2026-08-01, still open, in priority order.**
Several were mis-reported by the audit and re-checked by hand — the corrections
are as load-bearing as the findings:

- 🔴 **Three landmines before the eSIM provider switch.** `esim_plans.id` IS the
  provider's plan id AND the PK, with `esim_orders.plan_id` as an FK — a new
  provider using small integers (SMSPool uses "1107") **overwrites rows in place
  and silently repoints live orders at different products**, including the
  `validity_days` that drives expiry. `esim_orders.provider` exists with **zero
  readers**, so after a switch all live eSIMs get their transaction ids sent to
  the wrong vendor (the eSIM path never got `refuseRetired()`). And
  `dataUsedMb ?? 0` renders a dead provider key as **"full data remaining",
  forever**. Also: 10 of 11 live eSIM orders have `expires_at` NULL and can never
  be swept. **The 9-item provider-switch checklist above is entirely SMS-specific.**
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
- ⚠️ **Six locales read English UI chrome while their translations sit unused in
  the catalog.** `Text(someString)` does not consult the catalog — only
  `Text("literal")` does. `PrimaryButton` works around it with
  `Text(LocalizedStringKey(label))`; `SheetHeader`, `Metric`, `ChipButton`,
  `StatusBadge`, `StockPill`, `GhostButton` do not. So every sheet header, the
  Home greeting, every order-history status pill and the metric labels ship
  English to all six locales. Matters now that 13 storefront localizations are
  live. Fix the components, not the call sites.
- ⚠️ **The e-mail waiting screen still hangs forever.** `refreshEmailOrder`
  transitions on `hasCode` only, no branch for expired/canceled/failed, and the
  poll loop is gated on a `flow` nothing else clears. This file previously said
  it ships in 1.6/1.7 — **verified against current code, it does not**.
- ⚠️ **`intent` leaks out of e-mail mode — the THIRD instance of the
  `PurchaseIntent` bug class.** Turning e-mail mode OFF is a no-op
  (`ContentView.swift:145-148` guards `else { return }`), clearing neither
  `emailDomain` nor `intent`. Home → E-mails → pick a domain → back to Numbers →
  tap the credit pill, and the sheet sizes for a 1-credit e-mail instead of the
  SMS route: on a 100+ credit route the user buys a pack and is still short.
- ⚠️ **Two ways the catalog can go dark returning HTTP 200.** `sync-esim-plans`
  has no fail-loud path (its `catch` is dead code — `esimPlans()` cannot throw,
  it returns a fault object that is silently dropped) and its hide-sweep floor is
  50 plans against a 1,081 catalog (4.6%, vs `sync-prices`' 40%).
- ⚠️ **`sync-herosms` advances a positional cursor over an unordered SELECT**, so
  countries are permanently skipped and never get `herosms_real_count`.
  `sync-smspva-operators` does it correctly (`.order("id")` + id cursor).
- ⚠️ **No Apple refund/revocation handling anywhere** — no App Store Server
  Notifications V2 endpoint among the 24 functions, no revocation column. A buyer
  can refund through Apple, keep the credits and spend them.
- ⚠️ **The alert channel fails identically to health.** `telegram-notify`
  discards the error on its `app_config` read, so a failed read skips the entire
  paging block and returns `200 {sent:0}` — byte-identical to a healthy quiet
  run. Same for `ops_snapshot`, which matters because digest silence is the
  documented human backstop for telegram-notify's own death.
- ⚠️ **`supabase_admin` default privileges still grant `anon`/`authenticated`
  `arwdDxtm` on every FUTURE table** — a dashboard-created table arrives
  world-**writable** unless RLS is explicitly enabled. Needs role membership we
  do not have. Also `claim_daily_credit()` and `daily_credit_status()` are
  `authenticated`-executable (deliberate — the shipped app calls them — and now
  harmless since both are no-ops).
- ⚠️ **`routes.status` has no index**, and `routes` shows 111.7M sequential tuple
  reads. A partial index `where status='active'` is the cheap win.

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

- ⚠️ **`orders.actual_cost_cents` ships per-order wholesale to the buyer.**
  `orders`, `esim_orders` and `email_orders` all carry it, all three client
  fetches use `select=*`, and RLS self-read grants the row — while **no Swift
  model decodes it**. A pure leak. Fixing it needs the client to name its columns
  first, so it is a two-phase rollout like the others; it missed build 19.

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
- ⚠️ **Email is absent from `ops_snapshot` / `revenue_snapshot` /
  `_shared/opsFormat.ts`.** Per the third-product-line checklist it must be added
  to all three or it is invisible in the digest, `/stats` and `/profit`.
- ⚠️ **The HeroSMS API key passed through a chat transcript and should be
  rotated.** It lives only as the `HEROSMS_API_KEY` Supabase secret and appears in
  no commit (verified), but rotate it.
- ⚠️ **Removable code — most of it is now gone.** `virtualsms.ts`,
  `sync-virtualsms/`, `sync-smspool/`, `smspool-catalog/` and `smspool.ts`'s SMS
  surface were all deleted 2026-07-30. Still outstanding: `AppState.routes`
  (written once, never read, ~3 MB of observation-tracked memory) and the
  constants duplicated across files above.
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

**Ratings cap position; keywords only buy eligibility.** The US storefront shows
**0 ratings** (3 reviews exist, FR/POL). That is why `shouldRequestReview` now
fires on the **first** delivered code — only 7 users in the app's history ever
reached two, and those 7 produced all 3 reviews.

⚠️ **Never let email keywords go live ahead of the build that ships email.**

## Release prep

**Beta-macOS build gotcha (ITMS-90111).** This Mac runs a beta macOS (observed `26A5388g` on 2026-08-03; it moves with each seed). Every `xcodebuild archive` embeds the host OS build in `BuildMachineOSBuild`, and App Store validation **rejects binaries built on beta macOS** — "Invalid Binary" / ITMS-90111 — regardless of Xcode/SDK (the installed Xcode 26.6 + iOS 26.5 SDK are fine; the `DTSDKBuild` seed suffix is NOT the cause). Established workaround: after `archive`, patch the app `Info.plist` in the `.xcarchive` to a **stable** macOS build before `-exportArchive` (export re-signs, so signatures stay valid):

```bash
/usr/libexec/PlistBuddy -c "Set :BuildMachineOSBuild 25F84" \
  "$ARCH/Products/Applications/VirtualSIM.app/Info.plist"
# then xcodebuild -exportArchive ...  (verify BuildMachineOSBuild in the exported IPA)
```

vSMS is a single-target app, so only one `Info.plist` needs patching. The real fixes are building on stable macOS or Xcode Cloud; patch is the interim path while on the beta.

**Submitting is fully headless via the App Store Connect API** (no Xcode Organizer) — see the `app-store-submission-asc` memory for the exact working pipeline: `xcodebuild archive` with `-allowProvisioningUpdates -authenticationKeyPath/-authenticationKeyID/-authenticationKeyIssuerID` (auto-provisions the Distribution cert; the Mac only has an *Apple Development* cert locally, which is fine) → patch `BuildMachineOSBuild` (above) → `xcodebuild -exportArchive` → `xcrun altool --upload-app` → ASC REST API (`POST /v1/appStoreVersions`, attach build, set `whatsNew`, `reviewSubmissions` submit). ASC API key lives at `~/.appstoreconnect/private_keys/AuthKey_R5ZVLBTUR6.p8` (key id `R5ZVLBTUR6`); app id `6774768570`. **The issuer id IS available: `4644ed13-4d98-489e-a94b-687f63946f46`** — an earlier note here claimed the machine had no issuer id and that API checks return `NO_ISSUER_ID`. That was wrong, and it cost real time: every "verify in ASC first" instruction was being skipped as impossible when the whole REST pipeline in fact works headlessly. The repo is at **`MARKETING_VERSION 1.8` / `CURRENT_PROJECT_VERSION 28`**. **Always verify live store state via the API before submitting** — the notes here drift within hours, and did twice on 2026-07-31 alone. **Release notes (`whatsNew`) are per-locale and there are 13 of them** — PATCH every `appStoreVersionLocalizations` row, or twelve storefronts ship the previous version's notes. Historical: 1.3 (build 12) released; 1.4 (build 13) submitted 2026-07-19; build 16 shipped as 1.5 in `a9b92c0` (which lowered the iOS floor to 18.0); build 17 submitted then cancelled 2026-07-25; build 18 submitted 2026-07-25 and released as **1.5**; build 19 submitted 2026-07-31 13:56Z and released as **1.6** the same day; build 20 submitted 2026-07-31 20:05Z as **1.7**, then **cancelled and replaced by build 21** (submitted 21:26Z; build 21 released as **1.7**, `READY_FOR_SALE` verified 2026-08-02) to strip the word "supplier" from shipped copy — cancelling an app-version submission is NOT the one-way door an IAP cancellation is: the version simply goes `DEVELOPER_REJECTED`, and re-attaching a build plus a fresh `reviewSubmission` recovers it in about a minute. **1.8**: build 23 submitted 2026-08-03 then cancelled; **build 28 submitted 13:18Z the same day and is `WAITING_FOR_REVIEW`** — the DEVELOPER_REJECTED recovery path above was exercised again and took under a minute (attach build → `POST /v1/reviewSubmissions` → `POST /v1/reviewSubmissionItems` → `PATCH {submitted:true}`). Export compliance is already declared in `Info.plist` (`ITSAppUsesNonExemptEncryption = false`), so nothing stalls on that question.

**Use the committed `ExportOptions.plist`; do NOT hand-write one.** (It genuinely is committed as of 2026-07-31 — this line previously said so while the file existed in no commit and no checkout, so the first export after a fresh clone had to invent one.) `-exportArchive` needs `teamID = UDMK379475` and fails with the useless pair *"No Account for Team X"* + *"No profiles for 'com.anthersystems.VirtualSIM' were found"* when it is wrong — which reads like a signing/provisioning problem and is not. Read the real value from the archive if ever in doubt: `PlistBuddy -c "Print :ApplicationProperties:Team" <archive>/Info.plist`. Note the archive is signed *Apple Development* locally and re-signed for distribution on export; that is expected, not a fault.

**Run `xcodebuild -exportLocalizations` before submitting anything with new UI strings.** SwiftUI compiles interpolated literals into forms you will not guess — a sentence with two `\(…)` and a percent becomes `%1$@ / %2$@ / %3$lld` positional, and `Text("reports \(n)%")` becomes `reports %lld%%`. Guessing the key silently yields an English fallback; guessing the SPECIFIERS is a runtime crash. Export, then translate against the real keys, then verify the specifier multiset per locale (normalise positional form first — a translation may legitimately reorder arguments, as the Japanese strings do).

**Finding a just-uploaded build:** use `GET /v1/builds?filter[app]=<id>&filter[version]=<n>`. The version→build *relationship* endpoint reports nothing useful while the build is still processing, which reads as "stuck" and invites a pointless re-upload. Ingestion takes ~2 min before the build is even visible, then `processingState` goes `PROCESSING` → `VALID`.

**In-app purchases are a separate review track from the app version, and the public API can only do half of it.** Verified 2026-07-25 by direct experiment, replacing an earlier guess in this file:
- IAPs **cannot** ride along with the app version. `POST /v1/reviewSubmissionItems` with an `inAppPurchaseV2` relationship returns `ENTITY_ERROR.RELATIONSHIP.UNKNOWN` — *"'inAppPurchaseV2' is not a relationship on the resource 'reviewSubmissionItems'"*. Do not cancel a version submission planning to bundle them; it cannot work, and you lose your place in the queue for nothing.
- The **product-level `state` lies about submittability.** During the 2026-07-25 diagnosis `credits.60` and `credits.150` *both* read `READY_TO_SUBMIT` while being in completely different situations — one already queued for review, the other developer-rejected and unrecoverable. The truth is on the version: `GET /v2/inAppPurchases/<id>/versions`. Always read that before acting on the product state.
- `POST /v1/inAppPurchaseSubmissions` fails with 409 *"has no pending version for submission"* in **two opposite** cases — the version is already `READY_FOR_REVIEW`/`WAITING_FOR_REVIEW` (nothing to submit), or it is `DEVELOPER_REJECTED` (nothing submittable). Read the version state before believing the error means "incomplete metadata".
- An ASC-UI-created review submission can sit at `state: READY_FOR_REVIEW` with **`submittedDate: null`** — staged but never actually sent, so the IAP waits forever. Fix is `PATCH /v1/reviewSubmissions/<id> {"attributes":{"submitted":true}}`; its `platform` resolves from null to IOS on submit. This is how `credits.60` finally entered review, and it did **not** disturb the in-flight version submission.
- **The in-flight cap is exactly TWO per platform, and hitting it looks like a broken submission.** This file previously concluded "two IOS submissions coexisted fine, contradicting the one-in-flight rule" — the real rule is a limit of **2**, which is simply where we stopped. Verified 2026-07-28: `PATCH …{"submitted":true}` on `credits.150`'s staged submission failed with `STATE_ERROR.MAX_IN_REVIEW_SUBMISSIONS_PER_PLATFORM_LIMIT_REACHED` — *"maximum limit of 2 in-flight reviewSubmissions for platform=IOS"* — because both slots were held by the 1.5 app version and `credits.60`. The failed PATCH is a clean no-op; nothing changes. So a staged-unsent submission has **two** possible causes: nobody pressed submit, or the queue is full. Read the `associatedErrors` array, not just the top-level `detail`, which only says "check associated errors".
- **`credits.150` is NOT `DEVELOPER_REJECTED` any more** (this file said it was, and that it needed the ASC web UI). As of 2026-07-28 its version `d934db03-60ec-4a8b-acaf-0bd4ad85d9a6` is `READY_FOR_REVIEW` with a staged submission `0320433d-b4ba-4bd4-83e0-24106d146129` waiting on a free slot. **Submit it the moment 1.5 or `credits.60` clears** — it is the pack that lifts both the ARPU ceiling and the eSIM ceiling (median eSIM plan 25 cr, mean 59, largest approved pack 30). **DONE 2026-07-30 06:53Z**: `credits.60` was approved, freeing a slot, and the same `PATCH …{"submitted":true}` that failed on 2026-07-28 succeeded — `WAITING_FOR_REVIEW`, `platform` resolved null→IOS. Confirms the cap reading exactly: the identical call fails or succeeds purely on slot availability, so a `MAX_IN_REVIEW_SUBMISSIONS` failure means "retry later", not "this submission is broken".
- **Cancelling an IAP submission is close to a one-way door.** It leaves the IAP version at `DEVELOPER_REJECTED`, and nothing in the public API moves it back: editing `reviewNote` (a product-level field) does not dirty a version, and even a localization write leaves it at version 1. Recovering it requires the ASC **web UI**. Prefer leaving an IAP submission alone over cancelling it.

`docs/submission-checklist.md` is the source of truth for App Store submission steps. `docs/app-store-listing.md` has all metadata copy + nutrition labels pre-filled. Legal docs (`privacy-policy.md`, `terms.md`, `refund-policy.md`, `help.md`) are written to be pasted into Notion as public pages — URLs then go into `VirtualSIM/LegalLinks.swift`.
