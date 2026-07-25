# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**vSMS** (App Store display name; formerly "vSIM OTP" — the Xcode target/scheme is still `VirtualSIM`) — iOS app selling two products, both paid with in-app **credits**: (1) **temporary phone numbers** for SMS verification codes and (2) **eSIM data plans** priced at 4× wholesale. iOS frontend in SwiftUI + Supabase backend (Postgres + Auth + Edge Functions + pg_cron).

**Provider split as of 2026-07-21 — SMSPVA for SMS, SMSPool for eSIMs only.**
SMSPool served 43 SMS orders over 3 days and delivered 3. The decisive test was
leboncoin/NL — 8 of 13 on SMSPVA — going 0 of 1 on SMSPool with every mechanism
working correctly. Measured after the switch: SMSPool 5% delivery vs SMSPVA 43%
on the same catalog. SMSPool keeps eSIMs (9 of 9 delivered). virtualsms is fully
retired. `providerOrder()` in `_shared/providers.ts` is the single source of
truth for SMS routing; order/poll functions call the router, never a provider.

The provider has now changed twice in 24h and each switch broke something
non-obvious, because **`routes` is ONE row per (service_id, country_id) with
`provider` as a column** — re-homing rows strands any combo the new provider
can't serve. If you switch again, re-read the "provider switch checklist" below.

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
  create-esim-order check-esim-usage redeem-referral
# Cron-gated functions MUST ship --no-verify-jwt: their pg_cron relays send
# only x-cron-secret, no Authorization header. winback lived in the JWT group
# until 2026-07-21 and silently 401'd on every daily run — zero nudges ever
# sent, invisible because pg_net purges response history within hours.
supabase functions deploy poll-active-orders sync-prices sync-smspool sync-esim-plans \
  sync-smspva-operators sync-smspva-conversions winback telegram-notify telegram-webhook \
  smspool-catalog --no-verify-jwt
# smspool-catalog is an operator-only read-only dump of SMSPool's service/country
# ids (for mapping unmatched catalog entries); CRON_SECRET-gated like the syncs.
# NOTE: supabase/functions/list-orders/ is an EMPTY leftover directory, untracked
# and not deployed — don't add it to a deploy list.

# Query the remote DB
supabase db query --linked "select count(*) from public.routes;"

# Trigger any cron-gated function WITHOUT handling the secret yourself. pg_net
# calls it server-side and private_cron_secret() never leaves the database.
# Live pg_cron schedule (12 jobs, all active — verified 2026-07-25):
#   relay-poll-active-orders  * * * * *     relay-telegram-notify  * * * * *
#   watchdog                  */10 * * * *  relay-sync-prices      17 * * * *
#   relay-sync-smspva-conversions 49 * * * *  relay-sync-esim-plans 0 2 * * *
#   relay-sync-smspva-operators (fans 6 slots)  relay-winback      0 15 * * *
#   relay-smspva-operators-maint-up 29 4  / -down 43 4  (maintenance screen)
#   purge-job-run-details 7 3 * * *       telegram-events-prune 30 4 * * *
# relay-sync-smspool is UNSCHEDULED (SMSPool serves eSIMs only).
supabase db query --linked "
  select net.http_post(
    url := 'https://enugzltysdmjzavisloy.supabase.co/functions/v1/sync-prices',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'x-cron-secret', private_cron_secret()),
    body := '{}'::jsonb, timeout_milliseconds := 180000);"
```

There is no test suite. Verify iOS with the `swiftc -typecheck` command above
(exit 0 = all 73 sources compile). Verify backend changes by re-deploying, then
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
  SMS   → SMSPVA  (api.smspva.com)          create-esim-order/check-esim-usage
  eSIM  → SMSPool (api.smspool.net)         sync-prices (hourly :17, + catalog
  virtualsms retired; adapters kept           maintenance) / sync-esim-plans (daily)
  only so historical orders poll/cancel     sync-smspool (UNSCHEDULED)
                                            telegram-notify (cron 1 min) /
APNs ←── token-auth (.p8) HTTP/2            telegram-webhook (public, 2-gate)
Telegram ←── ops alerts + 6h digest         redeem-referral / winback
                                            register-push / iap-verify / delete-account
                                            sync-smspva-operators (nightly, chunked)
                                            sync-smspva-conversions (hourly :49)
                                            smspool-catalog (operator-only dump)
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
                                 Order, EsimPlan, EsimOrder, CreditPack)
  Screens/                       Home, Checkout, Waiting (+ WaitingAnimations),
                                 OTP (fires native review prompt on code
                                 delivery), Orders, Account, + eSIM flow
                                 (EsimStore, EsimCheckout, EsimDetail = QR + usage),
                                 Recovery (post-failure: retry on a fresh number /
                                 switch country / refund explainer — see the
                                 retry-steering note below), Maintenance (shown
                                 during the nightly operator-sync window)
  Sheets/                        ServiceSheet (search + categories + per-route
                                 price), CountrySheet (sort + per-route price),
                                 CreditsSheet (StoreKit 2)
  Components/                    Theme primitives + ServiceLogo / FlagImage /
                                 FlagCircle — bundle-first via BundledImageStore,
                                 network cascade (DuckDuckGo/FaviconV2, flagcdn) as
                                 fallback; SuccessBadge renders MEASURED delivery
                                 odds only (grey/amber/red), never seed rates
  Push/, IAP/, Onboarding/, DesignSystem/  Self-explanatory
  Localizable.xcstrings          String Catalog: en source + de/es/fr/it/ja/pt-BR
  Products.storekit              Local IAP test config (enable via scheme)
  VirtualSIM.entitlements        Sign in with Apple + aps-environment
```

### Backend layout

- `supabase/migrations/` — chronological SQL, each phase ships its own file
- `supabase/functions/_shared/` — `providers.ts` (unified router; SMS goes to SMSPVA only — order/poll functions call this, NOT a specific provider), `smspool.ts` (eSIM + legacy numbers), `smspva.ts` (v2 REST wrapper), `virtualsms.ts` (retired), `apns.ts` (HTTP/2 + JWT), `cors.ts`, `iap.ts` (Apple receipt chain verification), `telegram.ts`, `opsFormat.ts`, `supabaseAdmin.ts`
- `supabase/functions/<name>/index.ts` — one per endpoint, all Deno.serve
- `supabase/README.md` — deployment + secret setup walkthrough

**Key SQL functions** (all `SECURITY DEFINER`, all revoked from `anon`/`authenticated` — clients reach them only through edge functions on the service role):
- `begin_order(user, service, country, credits)` — dedupe + insert order + charge, in ONE transaction under `pg_advisory_xact_lock(user)`. See the gotcha below; do not go back to charging before the row exists.
- `wallet_spend` / `wallet_credit` — atomic single-statement balance moves. Always pass `p_order` so the ledger reconciles.
- `active_sms_provider()` — returns whichever provider owns the most `active` routes. Maintenance functions default to it so a provider switch can't silently orphan them again.
- `refresh_route_observed_success` / `refresh_service_delivery` / `sync_service_visibility` / `apply_measured_service_ranking` — catalog self-correction, all called from `sync-prices`.
- `ops_snapshot(interval)` — one JSONB blob powering both the Telegram digest and `/stats`.

### Telegram ops bot

`telegram-notify` (cron, every minute) sweeps new signups / credit purchases /
eSIM purchases and emits a 6-hourly digest; `telegram-webhook` answers `/stats`,
`/today`, `/week`, `/balance`. Exactly-once is a claim row in `telegram_events`
(`kind`,`ref` PK) written *before* sending, so the instant path in `iap-verify`
and the sweep can never double-send. Secrets: `TELEGRAM_BOT_TOKEN`,
`TELEGRAM_CHAT_ID`, `TELEGRAM_WEBHOOK_SECRET`. The webhook is public and gated
twice — matching `X-Telegram-Bot-Api-Secret-Token` **and** owner chat id — and
returns a silent 200 on every rejection so it isn't an oracle.

### Pricing model

`AppState.cost(for:country:) -> Int?` uses an O(1) `routeIndex` dict (keyed `"serviceId|countryId"`) built in `loadCatalog`. Returns `nil` when the pair has no active route with a `retail_credits` price — meaning **unavailable to book**; UI shows "Unavailable" (see ServiceSheet/CountrySheet) and disables the Get-number button. It deliberately does **NOT** fall back to the seed `service.cost`, since undercharging vs the live provider price burns margin per order. **Do not** linear-scan `routes` (~17k rows after sync-prices) — that froze the country picker before the index was added.

`sync-prices` formula: `credits = max(1, ceil(price / 0.05))` — 1 credit per started 5¢ of wholesale (`CREDIT_DIVISOR = 0.05`, same in `sync-smspool` **and `sync-smspva-operators`**, which prices the premium tier; tune it for global margin adjustment). Order-time enforcement matches: `create-order` has `MIN_MARGIN = 6.0` / `NET_USD_PER_CREDIT = 0.30`, so the max we pay a provider is `credits × $0.05`, enforced on the actual charged cost with cancel-and-fallback. The two are algebraically identical (`credits*0.30/6.0 == credits*0.05`) — keep them in lockstep; raising one alone either blocks honest routes or leaks margin. **SMS markup went 3× → 6× on 2026-07-25** (divisor 0.10 → 0.05); retail is recomputed from `smoothed_cost_cents` every run, so the whole catalog reprices on the next `sync-prices`.

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

**The cost smoothing is a RATCHET, not a symmetric EWMA.** A cost RISE applies immediately; only falls are smoothed:
```ts
const smoothed = prev == null || cents > prev ? cents : Math.round(A*cents + (1-A)*prev);
```
A plain `0.5*new + 0.5*prev` averages a rise against yesterday's cheaper price and sets retail BELOW what you're about to pay. That shipped once and put **4,384 routes under wholesale** in a single run. All three syncs (`sync-prices`, `sync-smspool`, `sync-esim-plans`) now have the ratchet — if you add a fourth pricing path, give it one too.

**eSIM** plans (`sync-esim-plans`) are priced **separately** at 4× wholesale (raised 3× → 4× on 2026-07-25) — `ESIM_MARGIN = 4`, `CREDIT_VALUE_USD = 0.48`, `retail_credits = ceil(usd * 4 / 0.48)` — NOT via `CREDIT_DIVISOR`, so the two product lines never collide. Inverted, the order-time ceiling in `create-esim-order` is `credits * 0.12`: SMSPool's `/esim/purchase` accepts no price cap and its response reports **no cost at all**, so the function takes a fresh `/esim/plans` quote, blocks above the ceiling, and writes that real number into `actual_cost_cents`. It fails **closed** on a bad price and **open** on a failed lookup — an unreachable SMSPool must not make eSIMs unbuyable. (Before this, `actual_cost_cents` echoed the cached catalog price, so margin analysis over it was circular and could never reveal drift.)

**Credit packs** (`Models/CreditPack.swift` + `Products.storekit` + `_shared/iap.ts` `PRODUCT_TO_CREDITS`): 5/$2.99, 12/$5.99 (MOST POPULAR), 30/$12.99, 60/$22.99, 150/$49.99 (BEST VALUE) — a strictly improving per-credit ladder (each pack beats stacking smaller ones). The per-credit label is computed **live** from the StoreKit price in `IAPStore.perCredit`, so it never drifts; production prices must be set to match in App Store Connect.

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

**The ✕ on the waiting screen destroys a paid order.** It looks like "back" but
calls `cancel-order`, which does a last-chance provider poll and can discard a
code seconds from arriving. It requires an explicit confirmation naming the
refund; don't "simplify" that away.

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

Client side, **colour carries confidence, not magnitude** (`SuccessBadge`): a
seeded rate renders muted whatever it says, green/amber/red are reserved for
measured. A tilde is not a warning — nobody reads a tilde.

## Non-obvious gotchas (real bugs we've hit, do not re-introduce)

- **SMSPVA base URL is `https://api.smspva.com`**, NOT `smspva.com` (the docs spec lies — the marketing site 404s every `/activation/*` path).
- **Edge functions die at ~150s wall clock** — a synchronous long request gets IDLE_TIMEOUT, and `EdgeRuntime.waitUntil` background tasks are killed at the same mark (both verified live 2026-07-21). Any job longer than ~2 minutes must be cursor-chunked across multiple invocations (see `sync-smspva-operators`: 12 countries/run, pg_cron fans 6 slots across a nightly maintenance window). Its public docs describe a *different, older* `priemnik.php` API; the v2 REST surface we use is undocumented but real.
- **Every SMSPVA response is an envelope: `{statusCode, data}`.** The value lives at `r.data.x`, never `r.x`. Reading the wrong level yields `NaN`/`undefined` and, on the balance path, wrote nothing at all — which looks *identical to a healthy provider*. Use `isOk(r)` before touching `r.data`.
- **The Apple receipt verifier must chain to Apple's PINNED root.** `_shared/iap.ts` once took the certificate out of the attacker-supplied JWS header and verified the signature against that same certificate — circular, so anyone with a free Sign-in-with-Apple account could self-sign a payload for `credits.150` and mint credits forever. It now walks every hop of `x5c` and requires termination at **Apple Root CA - G3, matched by SHA-256 thumbprint** (pinning by subject name is defeated by a self-signed cert named "Apple Root CA - G3"), plus Apple's receipt-signing OID `1.2.840.113635.100.6.11.1` on the leaf, and validity checked at `signedDate` not `now()`. **Pin the ROOT ONLY** — the leaf expires 2027-10-13 and Apple rotates intermediates routinely, so pinning anything lower turns a normal rotation into a total purchase outage. No OCSP: a live round-trip to Apple inside checkout would fail every legitimate purchase during an Apple outage.
- **Credits are granted only when `tx.environment === "Production"`.** Sandbox/Xcode receipts are genuine Apple-signed transactions that cost **$0** — any Apple ID can switch to a Sandbox account in Settings and "buy" packs free (this already happened: receipt id 21 credited a real user 12 credits 39s after signup). Non-production receipts are still persisted for the audit trail and still return `ok:true` so the client calls `tx.finish()` and StoreKit stops redelivering — they just move no balance and pay no referral reward. **This gate is worthless without the chain verification above**, because `environment` is just another field a forger sets to `"Production"`.
- **`order_status` cannot grow a value without shipping the app first.** iOS `OrderStatus` (`Components/Pills.swift`) is a plain `String` enum with **no unknown case**, so a status it doesn't recognise throws on decode and breaks the Orders tab for everyone on the released build. This is why `begin_order` writes a pre-reservation row as ordinary `'waiting'` with a null `smspva_id` instead of adding a `'pending'` state.
- **Charge and order row must be written together.** `create-order` used to charge and only insert the row after a provider reservation succeeded, so every failure left a spend+refund pointing at nothing: **258 spends vs 126 orders — 51% of paid attempts invisible**, and the real failure rate unmeasurable. `begin_order()` now does dedupe + insert + charge in one transaction under a per-user advisory lock (the old dedupe `SELECT`ed ~120 lines before the `INSERT`, with a multi-second provider call between, so two concurrent requests both passed it and both charged). A stranded row self-heals: the poller skips it for polling (`smspva_id is not null`) but the expiry sweep still closes and refunds it.
- **Never write a status transition without an atomic claim.** Every `orders` status write is `.eq("status","waiting")` + row-count check. `check-order`'s `received` branch was the one exception and could overwrite a terminal state the expiry cron had already set — handing a user a working code they'd *already been refunded for*.
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
- **Both provider balances are monitored**, written every minute by `poll-active-orders` into `app_config.smspva_health` / `smspool_health`, and reported by the bot labelled with what they fund. A missing reading renders as "no reading", never omitted — an absent line reads as healthy, which is exactly the failure that hid SMSPVA having no monitoring at all while it served 100% of SMS.
- **PostgREST `max_rows` is now `60000`** (`alter role authenticator set pgrst.db_max_rows`). The catalog is ~18.5k routes and moved 6,962 → 16,320 → 18,492 in 36h purely from provider changes. Crossing the cap makes PostgREST **truncate silently** — HTTP 206, no error, the app just gets fewer routes and every missing one renders "Unavailable" or keeps a stale price. That is indistinguishable from "the prices are wrong" from the phone. Keep large headroom; it is nearly free.
- **CatalogAPI fetches only routes where `retail_credits IS NOT NULL OR status != 'active'`**. After sync-prices, all routes have a price → query effectively returns everything. The filter exists so a fresh project without sync data doesn't pull empty rows.
- **Cover/sheet content does NOT inherit `@Observable` env objects from the presenter.** Always wrap sheet/cover content with the `EnvBundle` modifier in `ContentView`.
- **`tint_hex`, not `tint`** — Service column is `tint_hex` (snake) → `tintHex` (Swift). Same casing rule for every Service/Country/Route field. Don't reintroduce shorter names.
- **Cron-secret auth reads from `Deno.env.get("CRON_SECRET")`**, not from `vault.decrypted_secrets`. The vault schema isn't reachable through PostgREST — the function would silently fail. Both `poll-active-orders` and `sync-prices` rely on the env var being mirrored to the vault entry. **CRON_SECRET therefore lives in TWO stores** (edge secrets + vault `cron_secret`, read by `private_cron_secret()`); rotating one without the other 401s every relayed function at once — including telegram-notify, i.e. the alert channel. The watchdog's `relay-http` check catches the 401s within ~25 min, but rotate both together.
- **The watchdog is plain SQL — keep it that way.** `run_watchdog()` (pg_cron `*/10`, migration `20260722050000`) checks job freshness (poller heartbeat, `routes`/`esim_plans.last_checked_at`, digest stamp, sync cursors via `app_config.updated_at` — maintained by the `app_config_touch` trigger, so cursor upserts don't need to set it) plus any non-2xx row in `net._http_response`, and writes its verdict to `app_config.'watchdog'`. `telegram-notify` (minutely) turns that into pages (6h re-alert, ✅ on recovery); `/balance` shows the verdict too. It deliberately uses **no edge function, no CRON_SECRET, no HTTP** so it still evaluates when the whole edge/secret layer is broken. If you add a scheduled job, give it a freshness signal and a check here. Residual blind spot: telegram-notify's own death = digest silence >7h (documented in `docs/autopilot-runbook.md`).
- **IAP environment check constraint must allow `'Xcode'`** for local StoreKit testing alongside `'Sandbox'`/`'Production'`. See migration `..._iap_allow_xcode_env.sql`.
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
- **A git worktree cannot build or type-check until you copy `Secrets.swift` in.**
  `VirtualSIM/Networking/Secrets.swift` is gitignored, so a fresh worktree lacks
  it and both `swiftc -typecheck` and `xcodebuild` fail with `cannot find
  'Secrets' in scope` — which looks like your edit broke the build and is not.
  `cp /Users/adyl/Desktop/VirtualSIM/VirtualSIM/Networking/Secrets.swift
  VirtualSIM/Networking/Secrets.swift` first; it stays ignored, so it will not be
  committed. (This is also why `find VirtualSIM -name '*.swift' | wc -l` reads 73
  in a working checkout but 72 in a bare worktree.)

## Provider switch checklist

Both switches this week broke something that threw no error. If you change the
SMS provider again, walk this list:

1. **Update `providerOrder()`** in `_shared/providers.ts` — the only routing truth.
2. **Re-home `routes`.** One row per (service,country) with `provider` as a column. Hand every combo the new provider can serve back to it, or `sync-prices` will skip those rows and never reprice them — that silently killed leboncoin/nl and /ro, the two best-delivering routes in the app.
3. **Check the crons.** Unscheduling a provider's sync also kills anything else living inside that function. Four maintenance jobs (observed success, service visibility, delivery evidence, catalog ranking) died this way and froze the "self-correcting" catalog for hours with no signal. They now live in `sync-prices` and resolve the provider via `active_sms_provider()`.
4. **Re-price before re-enabling.** A provider switch changes wholesale costs; run `sync-prices` and confirm `count(*) where smoothed_cost_cents < last_cost_cents` is **0** before trusting the catalog.
5. **Classify the new provider's errors.** `create-order` branches on `errorType`, not on the raw error string. If the adapter doesn't set it, *every* failure — dead account, bad key, rate limit, genuine stockout — collapses into "no_numbers_available", so users are told to "try another country" while the whole product is down, and the escalation `console.error` (also gated on `errorType`) never fires.
6. **Point balance monitoring at it** (`app_config.<provider>_health` + the `ROLE` map in `_shared/opsFormat.ts`).
7. **Verify with data, not the deploy log** — per-provider delivery is in `ops_snapshot`'s `by_provider`. A single blended rate averages a dead provider with a live one and describes neither (it read 10% while the live provider was at 43%).

## Current state (2026-07-25)

- **Retention/trust fixes shipped to `main` 2026-07-25 (iOS: NOT yet in a build).**
  The waiting screen no longer strands a user on "Waiting / 00:00" after the
  server expired + refunded (reconcile invariant above); the ✕ needs an explicit
  confirmation before destroying a paid order; refunds are visible both in the
  moment and durably in history; seeded badges are demoted at 2 zero-code
  attempts and never render in measured-green. Server side of Bug 4 is **live**
  (migration `20260725120000`, applied + verified). **The client fixes reach
  users only in the next App Store build** — nothing above is in front of a user
  until then. Verified by `BUILD SUCCEEDED` + `swiftc -typecheck` exit 0; the
  three failure states (502 provider, airplane mode, expiry while foregrounded)
  were reasoned through and covered in code but **not runtime-injected** — that
  needs an authenticated session and a live paid order.
- **Known-not-fixed, found during that work**: measured arrival timing still
  never reaches the client (see the Pricing/arrival section) — three screens
  still quote seed `eta_seconds` as fact.
- **Margins raised today: SMS 3× → 6×, eSIM 3× → 4×.** Deployed and verified live —
  16,303 active routes repriced avg 10.4 → 20.5 credits (max 81), 1,081 eSIM plans
  44.4 → 59.0. `under-margin` and ratchet-violation counts are **0** on both. The
  premium-tier backfill above was required as part of this; don't repeat a divisor
  change without it.
- **Codebase**: `MARKETING_VERSION 1.5`, `CURRENT_PROJECT_VERSION 16`, iOS min
  **18.0**, 73 Swift sources (type-check clean, warnings only), 66 migrations.
  *Store-side state is UNVERIFIED here* — the ASC issuer id isn't on this machine
  (`NO_ISSUER_ID`), so confirm version/IAP status in ASC before assuming. Last
  known-good was 1.4 live with 1.5 in review; commit `a9b92c0` shipped build 16 as 1.5.
- **SMS: SMSPVA $8.65** (alert tier 2, low). **eSIM: SMSPool $1.90** (alert tier 3,
  **critically low — top up or eSIM purchases start failing**). Balance pages
  escalate at $20/$10/$5/$1 crossings.
- **Delivery reality**: 151 lifetime SMS orders / 39 delivered (~26%). Last 7d
  SMSPVA 9/33 (27%); the SMSPool 4/50 (8%) rows are legacy SMS from before the
  cutover — SMSPool is eSIM-only now. **In the 24h to 2026-07-25 every SMS order
  failed: 12 orders, 3 users, 0 codes, all refunded (net credits 0).** Causes were
  route-level, not platform: Betano/BG went 0/7 measured and **auto-hid itself**
  (gambling operators block resale numbers service-side), plus an unproven
  Colombia cluster. Watchdog is clean (`failing: []`) — note it tracks job
  freshness and HTTP errors, **not delivery rate**, so a 0%-delivery day does not
  page. That blind spot is open.
- **Catalog**: 18,492 routes (16,303 active / 2,189 hidden), 1,081 active eSIM
  plans, 268 services, 69 countries. 12 pg_cron jobs, all active.
- Autopilot hardening (2026-07-22, migration `20260722050000`) remains in force:
  SQL watchdog + Telegram paging, fail-streak pager, provider AUTH/BALANCE pager,
  iap-verify no longer eats a payment on `wallet_credit` failure, 24h sweep
  window, dead APNs pruning, winback heartbeat, `job_run_details` 7-day retention,
  migration bookkeeping (**but `db push` is broken again — see the gotcha**). `docs/autopilot-runbook.md`
  is the owner's operations reference.
- **Known-open list cleared 2026-07-25** — every item below is now fixed except
  the two marked OPEN:
  - ✅ watchdog delivery-rate blindness → `20260725140000`. Replayed against the
    2026-07-24 outage: 10 conclusive / 0 delivered → **would have paged**.
  - ✅ double-tap "Install eSIM" burning a single-use LPA → confirm-on-repeat,
    persisted across the trip to Settings.
  - ✅ `pollActiveOrder` swallowing errors → the reconcile invariant above.
  - ✅ in-flight order not resumed after app kill → `resumeInFlightOrder()`.
  - ✅ measured arrival timing never reaching the client → wired + the
    safeupdate bug fixed.
  - ⚠️ **OPEN (deliberately staged): `routes` cost columns readable
    unauthenticated.** The client half shipped (explicit column list, and
    `lastCostCents` deleted from the model — it was decoded and never read).
    Migration `20260725130000` revokes the column grants but is **NOT APPLIED**:
    Postgres needs SELECT on every column to answer `select=*`, so applying it
    before the new build is adopted would make the catalog fail to load and
    every price render "Unavailable" for users on 1.4/1.5. Apply it once the
    build with the explicit-column `CatalogAPI` is out and adopted, then
    re-check with the curl in that file's header.
  - ⚠️ **OPEN: Supabase project is on the FREE plan (no backups).** Owner
    action — recommend Pro.

## Error UX rule

Never display raw API errors. AppState's catch blocks call `APIError.userMessage`, which maps known business-logic codes (`insufficient_credits`, `no_numbers_available`, `route_unavailable`, `provider_unreachable`, `margin_too_low`, etc.) to plain English. `errorDescription` stays for the Xcode console only.

**Keep the Swift map and the backend codes in sync.** The backend was renamed to emit `provider_unreachable` while `APIError` still only matched the old `smspva_unreachable`, so a third-party outage fell through to the 5xx fallback and blamed our own infrastructure. When you add or rename an `{ error: "..." }` literal in any edge function, add the matching case in `Networking/APIError.swift` in the same commit.

## When iOS data looks wrong, check in this order

1. Force-quit the app — `.task` only runs on cold launch (`scenePhase=.active` now also refreshes catalog, but cold start is the cleanest test). **Most "wrong price" reports are this**: the catalog is cached per launch, so any reprice you just ran won't show until a cold start.
2. Xcode console for catalog decode errors (column name mismatches show as `keyNotFound`). A field missing from the Swift model is dropped **silently** by `.convertFromSnakeCase` rather than erroring — that's how the eSIM SIM PIN sat in the database for a day and never reached the screen.
3. `curl` PostgREST directly with the publishable key — if curl returns the data, iOS decoding is the issue. Check the row **count** too, not just the shape (see the `max_rows` truncation gotcha).
4. Function logs in Supabase dashboard → Functions → pick function → Logs.

## Release prep

**Beta-macOS build gotcha (ITMS-90111).** This Mac runs a beta macOS (e.g. `26A5368g`). Every `xcodebuild archive` embeds the host OS build in `BuildMachineOSBuild`, and App Store validation **rejects binaries built on beta macOS** — "Invalid Binary" / ITMS-90111 — regardless of Xcode/SDK (the installed Xcode 26.6 + iOS 26.5 SDK are fine; the `DTSDKBuild` seed suffix is NOT the cause). Established workaround: after `archive`, patch the app `Info.plist` in the `.xcarchive` to a **stable** macOS build before `-exportArchive` (export re-signs, so signatures stay valid):

```bash
/usr/libexec/PlistBuddy -c "Set :BuildMachineOSBuild 25F84" \
  "$ARCH/Products/Applications/VirtualSIM.app/Info.plist"
# then xcodebuild -exportArchive ...  (verify BuildMachineOSBuild in the exported IPA)
```

vSMS is a single-target app, so only one `Info.plist` needs patching. The real fixes are building on stable macOS or Xcode Cloud; patch is the interim path while on the beta.

**Submitting is fully headless via the App Store Connect API** (no Xcode Organizer) — see the `app-store-submission-asc` memory for the exact working pipeline: `xcodebuild archive` with `-allowProvisioningUpdates -authenticationKeyPath/-authenticationKeyID/-authenticationKeyIssuerID` (auto-provisions the Distribution cert; the Mac only has an *Apple Development* cert locally, which is fine) → patch `BuildMachineOSBuild` (above) → `xcodebuild -exportArchive` → `xcrun altool --upload-app` → ASC REST API (`POST /v1/appStoreVersions`, attach build, set `whatsNew`, `reviewSubmissions` submit). ASC API key lives at `~/.appstoreconnect/private_keys/AuthKey_R5ZVLBTUR6.p8`; app id `6774768570`. Store state: the repo is at **`MARKETING_VERSION 1.5` / `CURRENT_PROJECT_VERSION 16`** (build 16 shipped as 1.5 in `a9b92c0`, which also lowered the iOS floor to 18.0); the next build is **17** (bump `CURRENT_PROJECT_VERSION`, and `MARKETING_VERSION` too if the version changes, in `project.pbxproj`). **Verify the live store state in ASC before submitting** — this machine has the `.p8` but no issuer id, so the API check returns `NO_ISSUER_ID` and the notes here can drift. Historical: 1.3 (build 12) released; 1.4 (build 13) submitted 2026-07-19. Submission gotcha: only one review submission can be in flight per platform — standalone IAP submissions (created via ASC UI) block the version submission with an opaque 409 "not in valid state"; cancel them first, submit the version, then resubmit IAPs via `POST /v1/inAppPurchaseSubmissions` (IAPs can NOT be added as `reviewSubmissionItems` through the public API).

`docs/submission-checklist.md` is the source of truth for App Store submission steps. `docs/app-store-listing.md` has all metadata copy + nutrition labels pre-filled. Legal docs (`privacy-policy.md`, `terms.md`, `refund-policy.md`, `help.md`) are written to be pasted into Notion as public pages — URLs then go into `VirtualSIM/LegalLinks.swift`.
