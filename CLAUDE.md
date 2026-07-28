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
  smspool-catalog daily-credit --no-verify-jwt
# daily-credit (cron relay-daily-credit, 11 16 * * *) sends the "claim your free
# credit" push. It is cron-gated, so it MUST stay in this --no-verify-jwt group.
# sync-virtualsms still exists on disk but virtualsms is RETIRED — do not deploy
# or schedule it; it is kept only so historical orders remain inspectable.
# smspool-catalog is an operator-only read-only dump of SMSPool's service/country
# ids (for mapping unmatched catalog entries); CRON_SECRET-gated like the syncs.
# (The old `list-orders/` leftover directory is GONE as of 2026-07-25 — the two
# lists above plus sync-virtualsms now account for every directory on disk.)

# Query the remote DB
supabase db query --linked "select count(*) from public.routes;"

# Trigger any cron-gated function WITHOUT handling the secret yourself. pg_net
# calls it server-side and private_cron_secret() never leaves the database.
# Live pg_cron schedule (14 jobs, all active — re-verified 2026-07-25 16:50Z):
#   relay-poll-active-orders  * * * * *     relay-telegram-notify  * * * * *
#   watchdog                  */10 * * * *  relay-sync-prices      17 * * * *
#   relay-sync-smspva-conversions 49 * * * *  relay-sync-esim-plans 0 2 * * *
#   relay-sync-smspva-operators 30,32,34,36,38,40 4 * * *  (6 chunked slots)
#   relay-winback             0 15 * * *    relay-daily-credit     11 16 * * *
#   expire-esim-orders        */15 * * * *
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

### Retention — the numbers that decide what's worth building

Measured 2026-07-27, dev account excluded. **Receiving codes IS the retention
mechanic**, and it is not close:

| codes ever received | users | avg lifetime orders |
|---|---|---|
| 0 | 23 | **2.1** |
| 1 | 8 | 4.9 |
| 2+ | 5 | **14.8** |

Funnel: 168 signups → 36 ordered (21%) → 13 got a code → **12 purchased (92%)**,
and 6 of those 12 bought again. There is no monetization problem; delivery *is*
the monetization, and every point of delivery rate compounds into order volume.

Two hard constraints on any lifecycle work:
- **Activation is a single-session event.** Median signup → first order is **2
  minutes**; 35 of 36 order within 24h, and exactly ONE user in the product's
  history first ordered after day one. Corroborated: 89 users winback-nudged, **1
  ordered (1.1%)**. Chasing never-ordered users with push is near-worthless.
- **Every repeat order happens within 5 days.** All 126 observed gaps. A nudge at
  day 30 is talking to someone already gone.

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
- `reorder_candidates` — **users who succeeded.** They were excluded from every
  nudge in the product by construction, despite being the only cohort with proven
  fit. Fires at 3–14 days, inside the observed repeat window.

**The daily credit is granted by `register-push`, not by a button.**
`claim_daily_credit()` reads `auth.uid()`, which is null under the service role,
so only the app could grant it — and the claim UI exists solely in an unreleased
build. Result: 95–104 pushes/day, **zero claims ever**, repeating forever because
the dedupe (`last_daily_credit_on = today`) is something the shipped app can
never set. `claim_daily_credit_for(uuid)` now runs from `register-push`, which
the app calls on every cold launch — so opening the app *is* the trigger, which
was the design intent all along. Both share the same advisory-lock key, so they
cannot double-grant.

### Telegram ops bot

`telegram-notify` (cron, every minute) sweeps new signups / credit purchases /
eSIM purchases and emits a 6-hourly digest; `telegram-webhook` answers `/stats`,
`/today`, `/week`, `/balance`, `/revenue`. Exactly-once is a claim row in `telegram_events`
(`kind`,`ref` PK) written *before* sending, so the instant path in `iap-verify`
and the sweep can never double-send. Secrets: `TELEGRAM_BOT_TOKEN`,
`TELEGRAM_CHAT_ID`, `TELEGRAM_WEBHOOK_SECRET`. The webhook is public and gated
twice — matching `X-Telegram-Bot-Api-Secret-Token` **and** owner chat id — and
returns a silent 200 on every rejection so it isn't an oracle.

**`/revenue [24h|7d|30d|90d|all]`** (default `all`, alias `/profit`) reports gross
→ Apple's cut → wholesale → profit, via `revenue_snapshot(interval)` +
`formatRevenue` in `_shared/opsFormat.ts`.

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

### Pricing model

`AppState.cost(for:country:) -> Int?` uses an O(1) `routeIndex` dict (keyed `"serviceId|countryId"`) built in `loadCatalog`. Returns `nil` when the pair has no active route with a `retail_credits` price — meaning **unavailable to book**; UI shows "Unavailable" (see ServiceSheet/CountrySheet) and disables the Get-number button. It deliberately does **NOT** fall back to the seed `service.cost`, since undercharging vs the live provider price burns margin per order. **Do not** linear-scan `routes` (~17k rows after sync-prices) — that froze the country picker before the index was added.

`sync-prices` formula: `credits = max(1, ceil(price / 0.05))` — 1 credit per started 5¢ of wholesale (`CREDIT_DIVISOR = 0.05`, same in `sync-smspool` **and `sync-smspva-operators`**, which prices the premium tier; tune it for global margin adjustment). Order-time enforcement matches: `create-order` has `MIN_MARGIN = 6.0` / `NET_USD_PER_CREDIT = 0.30`, so the max we pay a provider is `credits × $0.05` **plus `CEILING_HEADROOM_USD` ($0.10)**, enforced on the actual charged cost with cancel-and-fallback. Keep the divisor and the margin pair in lockstep; raising one alone either blocks honest routes or leaks margin.

**The $0.10 headroom is load-bearing — do not "simplify" it away.** Without it the two formulas are exactly inverse (`credits*0.30/6.0 == credits*0.05`), so a route whose wholesale lands on an exact 5¢ boundary has an order-time cap equal to its cost **to the cent**. Measured 2026-07-27: **12,507 of 16,303 active routes (76.7%) sat at exactly zero headroom.** A one-cent rise at SMSPVA then made every order on that route fail `margin_too_low` — charged and instantly refunded — until the next hourly `sync-prices` repriced it. That produced **11 of 22 orders in 24h closing in under a second with no number**, and because those orders were also counted as delivery failures it auto-hid TikTok/Netherlands (see below). The headroom is flat, not proportional, so exposure is bounded at $0.10/order at any price point; the cost is margin on the cheapest routes (a 2-credit route may now pay up to $0.20 against $0.60 of revenue, 3× not 6×), which is strictly better than refunding the order. **SMS markup went 3× → 6× on 2026-07-25** (divisor 0.10 → 0.05); retail is recomputed from `smoothed_cost_cents` every run, so the whole catalog reprices on the next `sync-prices`.

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
A plain `0.5*new + 0.5*prev` averages a rise against yesterday's cheaper price and sets retail BELOW what you're about to pay. That shipped once and put **4,384 routes under wholesale** in a single run. All three syncs (`sync-prices`, `sync-smspool`, `sync-esim-plans`) now have the ratchet — if you add a fourth pricing path, give it one too.

**eSIM** plans (`sync-esim-plans`) are priced **separately** at 4× wholesale (raised 3× → 4× on 2026-07-25) — `ESIM_MARGIN = 4`, `CREDIT_VALUE_USD = 0.48`, `retail_credits = ceil(usd * 4 / 0.48)` — NOT via `CREDIT_DIVISOR`, so the two product lines never collide. Inverted, the order-time ceiling in `create-esim-order` is `credits * 0.12`: SMSPool's `/esim/purchase` accepts no price cap and its response reports **no cost at all**, so the function takes a fresh `/esim/plans` quote, blocks above the ceiling, and writes that real number into `actual_cost_cents`. It fails **closed** on a bad price and **open** on a failed lookup — an unreachable SMSPool must not make eSIMs unbuyable. (Before this, `actual_cost_cents` echoed the cached catalog price, so margin analysis over it was circular and could never reveal drift.)

**Credit packs** (`Models/CreditPack.swift` + `Products.storekit` + `_shared/iap.ts` `PRODUCT_TO_CREDITS`): 5/$2.99, 12/$5.99 (MOST POPULAR), 30/$12.99, 60/**$24.99**, 150/**$59.99** (BEST VALUE) — a strictly improving per-credit ladder (each pack beats stacking smaller ones): $0.598 → $0.499 → $0.433 → $0.417 → $0.400. The per-credit label is computed **live** from the StoreKit price in `IAPStore.perCredit`, so it never drifts; production prices must be set to match in App Store Connect.

**Those figures are the EUR tier, not what a US buyer pays** — measured
2026-07-27 from the signed `price`/`currency` in every stored Apple receipt
(`raw_jws`), i.e. amounts actually billed, not a guess. The US storefront bills
**$2.99 / $4.99 / $11.99** for the 5/12/30 packs while EUR territories bill
**€2.99 / €5.99 / €12.99** (normal Apple tier mapping — EUR prices carry VAT).
So the real US per-credit ladder is **$0.598 → $0.416 → $0.400**, not
$0.598 → $0.499 → $0.433. Still strictly improving, but the 12-pack is a much
better deal in the US than this file implied, and any margin arithmetic done
off the $5.99/$12.99 numbers is ~17% optimistic for US sales. Confirm against
`/v1/apps/6774768570/inAppPurchasesV2` price points before acting on either set.

**The 60 and 150 packs are the LIVE ASC prices, read back from the API on
2026-07-25 — this file previously claimed $22.99/$49.99, which was never what
the store would have billed.** Only the first three packs (`credits.5/12/30`)
are `APPROVED`; `credits.60` and `credits.150` have **never** been approved, so
the two best-value tiers are not purchasable in production no matter what
`CreditPack.swift` defines — StoreKit only returns approved products. Check
`state` on `/v1/apps/6774768570/inAppPurchasesV2` before assuming the ladder the
code defines is the ladder a user sees. (Product-level `state` is unreliable for
*submittability* — see Release prep — but `APPROVED` vs not is trustworthy.)

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
calls `cancel-order`. It requires an explicit confirmation naming the refund;
don't "simplify" that away.

### The 180s minimum hold, and the late-code rescue (2026-07-27)

Cancels landed at a **median of 57s**; codes arrive at a **median of 58s**, p90
134s, and 45% of codes that arrive do so after 60s. Users were destroying orders
one second before the typical code. Two changes, and they compose:

**1. `cancel-order` refuses to destroy an order held under `MIN_HOLD_SECONDS`
(180)**, returning **429 `cancel_too_early`** with `retry_after_seconds`. 180
sits above p90 arrival while leaving 5 minutes of the 8-minute window. It covers
**reroll too** — a reroll releases the number identically, so an early reroll
discards an in-flight code just the same. `WaitingScreen` renders a live
countdown in place of the ✕ and disables both reroll buttons.

**429, not 409, is deliberate:** shipped 1.4 has no case for the error code and
falls back on HTTP status, where 429 reads *"You're going a bit fast — please
wait a moment and try again"* — nearly right by accident, where 409's *"Not
available right now"* would mislead.

**Enforcement is gated on `enforce_min_hold`, sent only by newer clients, and
that gate is load-bearing.** Shipped 1.4's `rerollNumber` does
`if let server = try? await orders.cancel(...)` and then creates the replacement
**regardless of whether the cancel succeeded** — so enforcing for everyone would
leave the original `waiting` AND charge for a second order. Drop the flag only
once 1.4 is off the field. (`rerollNumber` now aborts on a failed cancel.)

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
   `blocked_routes` — without that clause it resurrects `whatsapp|us`, which is
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

### Why a service reads "Unavailable" — the price ceiling

`sync-prices` hides any route whose wholesale cost exceeds `MAX_WHOLESALE_CENTS`,
and a hidden route is exactly what the client renders as **"Unavailable"**
(`cost()` → nil). It was a flat **$4.00** until 2026-07-27, which hid **WhatsApp
across nearly every Western market** — 40 of its 69 routes, including the UK,
France, Netherlands and Poland at $5–6 wholesale — even though those are
comfortably buyable at 100–120 credits. For the most-requested service in the app
that read as "the app is broken", not as a deliberate cap. It is now **750**
(= the largest credit pack, 150 cr × $0.05), making the rule *hide only what a
user literally cannot buy*; that unhid 1,503 routes and took WhatsApp from 29 to
45 countries. Genuinely absurd routes stay hidden (WhatsApp Germany $13, Italy
$14.52, Spain $15, Canada $20).

**`blocked_routes` (app_config) is a separate manual kill-list and still wins at
any price** — `whatsapp|us`, `google|us`, `openai|us`, `twitter-x|us` are hidden
because those numbers don't work, not because they're expensive. So when checking
why something is unavailable, look at three things in order: `blocked_routes`,
then `smoothed_cost_cents > MAX_WHOLESALE_CENTS`, then measured-zero auto-hide.

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
- **`tint_hex`, not `tint`** — Service column is `tint_hex` (snake) → `tintHex` (Swift). Same casing rule for every Service/Country/Route field. Don't reintroduce shorter names.
- **Cron-secret auth reads from `Deno.env.get("CRON_SECRET")`**, not from `vault.decrypted_secrets`. The vault schema isn't reachable through PostgREST — the function would silently fail. Both `poll-active-orders` and `sync-prices` rely on the env var being mirrored to the vault entry. **CRON_SECRET therefore lives in TWO stores** (edge secrets + vault `cron_secret`, read by `private_cron_secret()`); rotating one without the other 401s every relayed function at once — including telegram-notify, i.e. the alert channel. The watchdog's `relay-http` check catches the 401s within ~25 min, but rotate both together.
- **The watchdog is plain SQL — keep it that way.** `run_watchdog()` (pg_cron `*/10`, migration `20260722050000`) checks job freshness (poller heartbeat, `routes`/`esim_plans.last_checked_at`, digest stamp, sync cursors via `app_config.updated_at` — maintained by the `app_config_touch` trigger, so cursor upserts don't need to set it) plus any non-2xx row in `net._http_response`, and writes its verdict to `app_config.'watchdog'`. `telegram-notify` (minutely) turns that into pages (6h re-alert, ✅ on recovery); `/balance` shows the verdict too. It deliberately uses **no edge function, no CRON_SECRET, no HTTP** so it still evaluates when the whole edge/secret layer is broken. If you add a scheduled job, give it a freshness signal and a check here. Residual blind spot: telegram-notify's own death = digest silence >7h (documented in `docs/autopilot-runbook.md`).
- **IAP environment check constraint must allow `'Xcode'`** for local StoreKit testing alongside `'Sandbox'`/`'Production'`. See migration `..._iap_allow_xcode_env.sql`.
- **A status string written from TS is NOT checked against the enum — and the error is discarded.** `create-esim-order`'s failure path wrote `status: "canceled"`, which is a member of `order_status` but **not** of `esim_status` (`provisioning, installed, active, depleted, expired, refunded, failed`). PostgREST rejected the UPDATE with 22P02, the code did `const { data: claimed } = await ...` without destructuring `error`, so `claimed` came back empty and the function **returned without refunding**. Every failed eSIM purchase charged the user and silently kept the money. When you write a status literal from an edge function, check it against `pg_enum` — the two enums share several names and differ in exactly the ones that matter.
- **`supabase-js` RETURNS errors, it does not throw.** Every `await sb.rpc("wallet_credit", …)` that discards `{ error }` is a silent money bug: `wallet_credit` raises on a non-positive amount and on a missing wallet row, so the status claim commits, the balance never moves, and the user gets a push saying "N credits refunded". Four sites had this. Destructure the error at every money call.
- **`revoke execute … from anon, authenticated` IS A NO-OP while PUBLIC holds the grant.** `CREATE FUNCTION` grants EXECUTE to PUBLIC by default, and anon/authenticated are members of PUBLIC — so the revoke line present on ~35 migrations changes nothing on its own, and the function stays callable at `/rest/v1/rpc/<name>`. Read the ACL, not the migration: a secured function is `postgres=X/postgres | service_role=X/postgres`, a leaking one has a **leading `=X/postgres`** (empty grantee = PUBLIC). Caught 2026-07-27 when `revenue_snapshot` — the first function created after the default-privileges hardening — shipped world-callable *with* its revoke line, exposing gross revenue, wholesale cost and profit to anyone holding the publishable key (SECURITY DEFINER, so RLS was no help). `20260727211000` revoked the *default* for anon/authenticated but **not for PUBLIC**, so every future function kept arriving public. Fixed in `20260727240000`: `alter default privileges in schema public revoke execute on functions from public`, plus explicit `from public, anon, authenticated` on the four affected functions. Assert with `has_function_privilege('anon', p.oid,'execute')` — it must be **0 rows** across `pg_proc` in `public`; a passing `revoke` statement proves nothing.
- **`ALTER DEFAULT PRIVILEGES` grants `anon`/`authenticated` rights on every FUTURE object.** Until 2026-07-27 that was `arwdDxtm` on future tables and `EXECUTE` on future functions — so any new table missing `enable row level security` would have been world-**writable** at `/rest/v1/<table>`, and any new SECURITY DEFINER function missing its revoke callable at `/rest/v1/rpc/<name>`. That is how `run_watchdog` became public. The postgres-owned defaults are now revoked (SELECT retained; RLS still governs rows); **the `supabase_admin` half is NOT applied** — it needs membership in that role, which the CLI's postgres connection lacks. Statements are in `20260727211000_default_privileges.sql`. Note this is a backstop, not a licence to skip the explicit `revoke execute` on every new function.
- **A one-line refactor that changes a watchdog threshold is a monitoring outage.** Rebuilding `run_watchdog` for unrelated coverage silently narrowed the delivery check from 24h/≥10 to 6h/≥8 **and deleted its second branch** (≥20 conclusive at <10%). Measured: the max conclusive orders in ANY 6h window over 30 days is 8, against a gate of 8 — the check became effectively unreachable, leaving zero delivery-outcome coverage. When you re-create a function from `pg_get_functiondef`, diff it against the prior definition clause by clause; the dump is also **truncated** by most tooling, which is how a nonexistent `url` column on `net._http_response` got invented in the same rewrite.
- **A constant duplicated across files WILL drift.** `MAX_WHOLESALE_CENTS` lives in three sync functions (and as `MAX_ORDER_COST_USD` in `poll-active-orders`, and as `LOW_BALANCE_USD` in `_shared/opsFormat.ts`). Changing it in one place on 2026-07-27 stripped 1,432 routes of their carrier pin and premium price, and left the digest warning at $20 while the pager fired at $37.50. Same for `CREDIT_DIVISOR` (three copies) and `ESIM_MARGIN`/`CREDIT_VALUE_USD` (two each). Change them in one commit or consolidate them into `_shared/`.
- **Deleting an IAP receipt to force StoreKit redelivery can eat the payment.** `iap-verify` used to delete the row when `wallet_credit` failed, assuming StoreKit would retry. But the client runs **two** paths into that endpoint (`Transaction.updates` and the `Transaction.unfinished` sweep), so a concurrent duplicate may already have been answered `already_credited` and called `finish()` — retiring the transaction forever. It now zeroes `granted_credits` (keeping both the audit trail and the replay guard), and the duplicate branch refuses to confirm a receipt that has no matching `wallet_transactions` row.
- **The signup bonus was farmable through account deletion.** Everything user-scoped cascades from `auth.users`, so delete → sign in again minted a fresh grant (+3, plus a fresh +2 referral because `referred_by` resets). `public.signup_grants` is a tombstone keyed on a **hash of the email**, living outside that cascade — Apple's private-relay address is stable per (user, app), so it survives deletion while storing no address. It fails **open** on a null email: a missed grant on a real signup costs more than a rare duplicate.
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
- **A git worktree is also not linked to Supabase.** `supabase/.temp/` is
  gitignored, so `supabase db query --linked` in a worktree dies with
  *"Cannot find project ref. Have you run supabase link?"* — which looks like a
  broken CLI or expired auth and is neither. Copy the link state in:
  `cp -R /Users/adyl/Desktop/VirtualSIM/supabase/.temp supabase/.temp`. It stays
  ignored. Do **not** re-run `supabase link` in a worktree.
- **Merging a worktree branch into `main` usually needs a real merge, not a
  fast-forward.** `main`'s tip is typically one of the `Merge: …` commits from a
  previous round, so a branch cut from the pre-merge tip has genuinely diverged
  and `git merge --ff-only` aborts with *"Not possible to fast-forward"*. That is
  not a sign the branch is broken — check with
  `git merge-base --is-ancestor main <branch>` and then merge with `--no-ff`.

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

## Current state (2026-07-27)

- **Everything client-side from 2026-07-26/27 is in NO installable build.** 1.4 is
  `READY_FOR_SALE` and is what every user runs. **1.5 / build 18 is
  `WAITING_FOR_REVIEW`, and it was archived from `02e9c4a` — before all of that
  day's client work (9 commits touching `VirtualSIM/`).** So the rescued-code UI,
  the cancel-orphan fix, the 180s countdown, the eSIM terminal card, the corrected
  pack prices and the `creditsShortfall` fixes reach users only in **build 19**.
  The backend half of all of it is live.
- **Backend shipped 2026-07-27** (all live, no review needed): 180s minimum hold
  + late-code rescue; `markDead` reordered to cancel-then-ban; evidence corrected
  (`otp is not null`, numberless filter back-ported, 30-day lookback, conditional
  wipe, reversible auto-hide); premium 20% uplift restored on 16,372 routes; three
  retention cohorts incl. the new `reorder_candidates`; daily credit granted from
  `register-push`; balance ladder derived from the ceiling; alert dedupe reordered
  to send-then-stamp; watchdog staleness + APNs health + eSIM-expiry coverage, and
  the delivery check **restored** after being narrowed into unreachability; four
  eSIM money bugs; schema hardening (FKs, CHECKs, indexes, revoked write grants,
  postgres-owned default privileges); signup-bonus tombstone; `iap-verify`
  rollback no longer eats a payment.
- **Codebase**: `MARKETING_VERSION 1.5`, `CURRENT_PROJECT_VERSION 18` (next build
  is **19**), iOS min **18.0**, 73 Swift sources (BUILD SUCCEEDED), 89 migration
  files.
- **Catalog**: 18,492 routes (17,804 active / 688 hidden), **13 measured routes**
  (was 1 before the lookback fix), 1,081 active eSIM plans, 268 services, 69
  countries. 14 pg_cron jobs, all active.
- **Balances: SMSPVA $3.55 — alert tier 4 (EMPTY on the new ladder)**, SMSPool
  $8.03. The ladder is now derived: `[37.50, 22.50, 11.25, 7.50]` = 5×/3×/1.5×/1×
  the $7.50 order ceiling. At $3.55, **~1,500 routes cannot be funded at all** —
  a WhatsApp order is a guaranteed charge-and-refund. **Top up.**
- **Delivery, 30d, orders that actually got a number**: 38 of 147 (**26%**).
  SMSPVA alone is ~35%; the SMSPool rows are legacy pre-cutover SMS. Watchdog is
  clean (`failing: []`).
- **Retention baseline** (see the Retention section): 168 users, 36 ever ordered,
  13 ever got a code, 12 of those 13 purchased. 100 users hold ≥3 credits and
  haven't ordered in 7 days — 466 idle credits.

### Known-open

- ⚠️ **Build 19 not cut.** Until it ships and is adopted, none of the client
  fixes above exist for users.
- ⚠️ **`20260725130000_hide_route_cost_columns` deliberately NOT applied.**
  Postgres needs SELECT on every column to answer `select=*`, and the shipped
  `CatalogAPI` still sends it — applying this before build 19 is *adopted* makes
  the catalog fail to load and every price render "Unavailable" for the whole
  install base. Client-first, revoke-second, in that order.
- ⚠️ **`esim_plans` publishes the wholesale cost book** to anyone with the
  publishable key (`last_cost_cents`, `smoothed_cost_cents`) — the `routes` leak
  repeated, and **neither half is done**: `EsimPlansAPI.fetch()` still sends
  `select=*`. Needs the same two-phase rollout.
- ⚠️ **`supabase_admin` default privileges not revoked** — needs membership in
  that role. Covers objects created via the dashboard rather than migrations.
  Statements in `20260727211000_default_privileges.sql`.
- ⚠️ **The late-code rescue has never executed in production** (0 rows with
  `late_watch_until`). Deployed and unproven; one deliberate cancel would confirm
  it end-to-end.
- ⚠️ **Migration drift: a fresh deploy would NOT reproduce production.** 43
  recorded versions have no local file, ~29 files aren't recorded, two files share
  version `20260719000000`, five migrations were applied twice, and ~10 functions
  exist only in the live DB (`smspool_hot_combos` appears in zero migration
  files). `db push` remains broken. Recover by writing each missing version out of
  `schema_migrations.statements` — do NOT `migration repair --status reverted`.
- ⚠️ **No test suite, and it shows.** Of ~20 changes made on 2026-07-27, **six
  were regressions introduced that same day** — a disabled watchdog check, a
  wholesale forfeit on every cancel, invisible rescued codes, an orphaned cancel
  path, a stale constant copy, and a timer/hold interaction. All were caught by
  post-hoc review, two only by luck. Until something automated covers the order
  lifecycle and the money paths, assume a similar rate on the next batch.
- ⚠️ **`credits.60` / `credits.150` still unapproved**, so the two best-value packs
  don't exist for users and the largest purchasable pack is 30 credits. `credits.150`
  is `DEVELOPER_REJECTED` and needs the ASC web UI. Note `MAX_WHOLESALE_CENTS = 750`
  is justified as "150 credits × $0.05" — that pack not existing is why ~1,500
  routes in the 80–150 credit band need 3–5 separate purchases.
- ⚠️ **~1,050 lines of removable code identified** and not removed: dead
  virtualsms paths, `sync-smspool` (unscheduled, self-gated AND calling a
  nonexistent RPC), `AppState.routes` (written once, never read, ~3 MB of
  observation-tracked memory), and the duplicated constants above.
- ⚠️ **Supabase project is on the FREE plan (no backups).** Owner action.

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

**Submitting is fully headless via the App Store Connect API** (no Xcode Organizer) — see the `app-store-submission-asc` memory for the exact working pipeline: `xcodebuild archive` with `-allowProvisioningUpdates -authenticationKeyPath/-authenticationKeyID/-authenticationKeyIssuerID` (auto-provisions the Distribution cert; the Mac only has an *Apple Development* cert locally, which is fine) → patch `BuildMachineOSBuild` (above) → `xcodebuild -exportArchive` → `xcrun altool --upload-app` → ASC REST API (`POST /v1/appStoreVersions`, attach build, set `whatsNew`, `reviewSubmissions` submit). ASC API key lives at `~/.appstoreconnect/private_keys/AuthKey_R5ZVLBTUR6.p8` (key id `R5ZVLBTUR6`); app id `6774768570`. **The issuer id IS available: `4644ed13-4d98-489e-a94b-687f63946f46`** — an earlier note here claimed the machine had no issuer id and that API checks return `NO_ISSUER_ID`. That was wrong, and it cost real time: every "verify in ASC first" instruction was being skipped as impossible when the whole REST pipeline in fact works headlessly. The repo is at **`MARKETING_VERSION 1.5` / `CURRENT_PROJECT_VERSION 18`**; the next build is **19** (bump `CURRENT_PROJECT_VERSION`, and `MARKETING_VERSION` too if the version changes, in `project.pbxproj`). **Always verify live store state via the API before submitting** — the notes here drift within hours. Historical: 1.3 (build 12) released; 1.4 (build 13) submitted 2026-07-19; build 16 shipped as 1.5 in `a9b92c0` (which lowered the iOS floor to 18.0); build 17 submitted then cancelled 2026-07-25; build 18 submitted 2026-07-25.

**Finding a just-uploaded build:** use `GET /v1/builds?filter[app]=<id>&filter[version]=<n>`. The version→build *relationship* endpoint reports nothing useful while the build is still processing, which reads as "stuck" and invites a pointless re-upload. Ingestion takes ~2 min before the build is even visible, then `processingState` goes `PROCESSING` → `VALID`.

**In-app purchases are a separate review track from the app version, and the public API can only do half of it.** Verified 2026-07-25 by direct experiment, replacing an earlier guess in this file:
- IAPs **cannot** ride along with the app version. `POST /v1/reviewSubmissionItems` with an `inAppPurchaseV2` relationship returns `ENTITY_ERROR.RELATIONSHIP.UNKNOWN` — *"'inAppPurchaseV2' is not a relationship on the resource 'reviewSubmissionItems'"*. Do not cancel a version submission planning to bundle them; it cannot work, and you lose your place in the queue for nothing.
- The **product-level `state` lies about submittability.** During the 2026-07-25 diagnosis `credits.60` and `credits.150` *both* read `READY_TO_SUBMIT` while being in completely different situations — one already queued for review, the other developer-rejected and unrecoverable. The truth is on the version: `GET /v2/inAppPurchases/<id>/versions`. Always read that before acting on the product state.
- `POST /v1/inAppPurchaseSubmissions` fails with 409 *"has no pending version for submission"* in **two opposite** cases — the version is already `READY_FOR_REVIEW`/`WAITING_FOR_REVIEW` (nothing to submit), or it is `DEVELOPER_REJECTED` (nothing submittable). Read the version state before believing the error means "incomplete metadata".
- An ASC-UI-created review submission can sit at `state: READY_FOR_REVIEW` with **`submittedDate: null`** — staged but never actually sent, so the IAP waits forever. Fix is `PATCH /v1/reviewSubmissions/<id> {"attributes":{"submitted":true}}`; its `platform` resolves from null to IOS on submit. This is how `credits.60` finally entered review, and it did **not** disturb the in-flight version submission.
- **The in-flight cap is exactly TWO per platform, and hitting it looks like a broken submission.** This file previously concluded "two IOS submissions coexisted fine, contradicting the one-in-flight rule" — the real rule is a limit of **2**, which is simply where we stopped. Verified 2026-07-28: `PATCH …{"submitted":true}` on `credits.150`'s staged submission failed with `STATE_ERROR.MAX_IN_REVIEW_SUBMISSIONS_PER_PLATFORM_LIMIT_REACHED` — *"maximum limit of 2 in-flight reviewSubmissions for platform=IOS"* — because both slots were held by the 1.5 app version and `credits.60`. The failed PATCH is a clean no-op; nothing changes. So a staged-unsent submission has **two** possible causes: nobody pressed submit, or the queue is full. Read the `associatedErrors` array, not just the top-level `detail`, which only says "check associated errors".
- **`credits.150` is NOT `DEVELOPER_REJECTED` any more** (this file said it was, and that it needed the ASC web UI). As of 2026-07-28 its version `d934db03-60ec-4a8b-acaf-0bd4ad85d9a6` is `READY_FOR_REVIEW` with a staged submission `0320433d-b4ba-4bd4-83e0-24106d146129` waiting on a free slot. **Submit it the moment 1.5 or `credits.60` clears** — it is the pack that lifts both the ARPU ceiling and the eSIM ceiling (median eSIM plan 25 cr, mean 59, largest approved pack 30).
- **Cancelling an IAP submission is close to a one-way door.** It leaves the IAP version at `DEVELOPER_REJECTED`, and nothing in the public API moves it back: editing `reviewNote` (a product-level field) does not dirty a version, and even a localization write leaves it at version 1. Recovering it requires the ASC **web UI**. Prefer leaving an IAP submission alone over cancelling it.

`docs/submission-checklist.md` is the source of truth for App Store submission steps. `docs/app-store-listing.md` has all metadata copy + nutrition labels pre-filled. Legal docs (`privacy-policy.md`, `terms.md`, `refund-policy.md`, `help.md`) are written to be pasted into Notion as public pages — URLs then go into `VirtualSIM/LegalLinks.swift`.
