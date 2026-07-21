# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**vSMS** (App Store display name; formerly "vSIM OTP" — the Xcode target/scheme is still `VirtualSIM`) — iOS app selling two products, both paid with in-app **credits**: (1) **temporary phone numbers** for SMS verification codes and (2) **eSIM data plans** priced at 3× wholesale. iOS frontend in SwiftUI + Supabase backend (Postgres + Auth + Edge Functions + pg_cron).

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
  sync-smspva-operators sync-smspva-conversions winback telegram-notify telegram-webhook --no-verify-jwt

# Query the remote DB
supabase db query --linked "select count(*) from public.routes;"

# Trigger any cron-gated function WITHOUT handling the secret yourself. pg_net
# calls it server-side and private_cron_secret() never leaves the database.
# (relay-sync-prices runs hourly at :17; relay-poll-active-orders every minute;
#  relay-sync-esim-plans daily 02:00 UTC; relay-sync-smspool is UNSCHEDULED.)
supabase db query --linked "
  select net.http_post(
    url := 'https://enugzltysdmjzavisloy.supabase.co/functions/v1/sync-prices',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'x-cron-secret', private_cron_secret()),
    body := '{}'::jsonb, timeout_milliseconds := 180000);"
```

There is no test suite. Verify iOS with the `swiftc -typecheck` command above
(exit 0 = all 72 sources compile). Verify backend changes by re-deploying, then
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
iOS (SwiftUI, iOS 26.2 target)            Supabase
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
```

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
                                 (EsimStore, EsimCheckout, EsimDetail = QR + usage)
  Sheets/                        ServiceSheet (search + categories + per-route
                                 price), CountrySheet (sort + per-route price),
                                 CreditsSheet (StoreKit 2)
  Components/                    Theme primitives + ServiceLogo / FlagImage /
                                 FlagCircle — bundle-first via BundledImageStore,
                                 network cascade (DuckDuckGo/FaviconV2, flagcdn) as fallback
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

`sync-prices` formula: `credits = max(1, ceil(price / 0.10))` — 1 credit per started 10¢ of wholesale (`CREDIT_DIVISOR = 0.10`, same in `sync-smspool`; tune it for global margin adjustment). Order-time enforcement matches: `create-order` has `MIN_MARGIN = 3.0` / `NET_USD_PER_CREDIT = 0.30`, so the max we pay a provider is `credits × $0.10`, enforced on the actual charged cost with cancel-and-fallback. The two are algebraically identical (`credits*0.30/3.0 == credits*0.10`) — keep them in lockstep; raising one alone either blocks honest routes or leaks margin.

**The cost smoothing is a RATCHET, not a symmetric EWMA.** A cost RISE applies immediately; only falls are smoothed:
```ts
const smoothed = prev == null || cents > prev ? cents : Math.round(A*cents + (1-A)*prev);
```
A plain `0.5*new + 0.5*prev` averages a rise against yesterday's cheaper price and sets retail BELOW what you're about to pay. That shipped once and put **4,384 routes under wholesale** in a single run. All three syncs (`sync-prices`, `sync-smspool`, `sync-esim-plans`) now have the ratchet — if you add a fourth pricing path, give it one too.

**eSIM** plans (`sync-esim-plans`) are priced **separately** at 3× wholesale — `ESIM_MARGIN = 3`, `CREDIT_VALUE_USD = 0.48`, `retail_credits = ceil(usd * 3 / 0.48)` — NOT via `CREDIT_DIVISOR`, so the two product lines never collide. Inverted, the order-time ceiling in `create-esim-order` is `credits * 0.16`: SMSPool's `/esim/purchase` accepts no price cap and its response reports **no cost at all**, so the function takes a fresh `/esim/plans` quote, blocks above the ceiling, and writes that real number into `actual_cost_cents`. It fails **closed** on a bad price and **open** on a failed lookup — an unreachable SMSPool must not make eSIMs unbuyable. (Before this, `actual_cost_cents` echoed the cached catalog price, so margin analysis over it was circular and could never reveal drift.)

**Credit packs** (`Models/CreditPack.swift` + `Products.storekit` + `_shared/iap.ts` `PRODUCT_TO_CREDITS`): 5/$2.99, 12/$5.99 (MOST POPULAR), 30/$12.99, 60/$22.99, 150/$49.99 (BEST VALUE) — a strictly improving per-credit ladder (each pack beats stacking smaller ones). The per-credit label is computed **live** from the StoreKit price in `IAPStore.perCredit`, so it never drifts; production prices must be set to match in App Store Connect.

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
- **Clients get `UPDATE` on `profiles.display_name` ONLY.** RLS is row-level and cannot restrict columns, so a table-wide UPDATE grant let any user PATCH their own `referred_by` / `referral_rewarded_at` — pointing the referral at themselves and nulling the payout flag to farm 5 credits per purchase forever. The `SECURITY DEFINER` guards *read* those columns to decide, so writable inputs made them decorative.
- **Both provider balances are monitored**, written every minute by `poll-active-orders` into `app_config.smspva_health` / `smspool_health`, and reported by the bot labelled with what they fund. A missing reading renders as "no reading", never omitted — an absent line reads as healthy, which is exactly the failure that hid SMSPVA having no monitoring at all while it served 100% of SMS.
- **PostgREST `max_rows` is now `60000`** (`alter role authenticator set pgrst.db_max_rows`). The catalog is ~18.5k routes and moved 6,962 → 16,320 → 18,492 in 36h purely from provider changes. Crossing the cap makes PostgREST **truncate silently** — HTTP 206, no error, the app just gets fewer routes and every missing one renders "Unavailable" or keeps a stale price. That is indistinguishable from "the prices are wrong" from the phone. Keep large headroom; it is nearly free.
- **CatalogAPI fetches only routes where `retail_credits IS NOT NULL OR status != 'active'`**. After sync-prices, all routes have a price → query effectively returns everything. The filter exists so a fresh project without sync data doesn't pull empty rows.
- **Cover/sheet content does NOT inherit `@Observable` env objects from the presenter.** Always wrap sheet/cover content with the `EnvBundle` modifier in `ContentView`.
- **`tint_hex`, not `tint`** — Service column is `tint_hex` (snake) → `tintHex` (Swift). Same casing rule for every Service/Country/Route field. Don't reintroduce shorter names.
- **Cron-secret auth reads from `Deno.env.get("CRON_SECRET")`**, not from `vault.decrypted_secrets`. The vault schema isn't reachable through PostgREST — the function would silently fail. Both `poll-active-orders` and `sync-prices` rely on the env var being mirrored to the vault entry.
- **IAP environment check constraint must allow `'Xcode'`** for local StoreKit testing alongside `'Sandbox'`/`'Production'`. See migration `..._iap_allow_xcode_env.sql`.
- **APNs `aps-environment` is `production`** in the entitlements file (flipped for archiving; set `APNS_ENV=production` secret to match). Flip back to `development` if you need to test push against a dev-token build from Xcode.
- **`Secrets.swift` is gitignored.** Template in `supabase/README.md`. Just `supabaseURL` + `supabaseAnonKey`. The publishable key (`sb_publishable_*`) is fine in client code — it's the new name for the anon key.
- **Logo loading cascades** in `ServiceLogo`: DuckDuckGo ip3 (`icons.duckduckgo.com/ip3/<domain>.ico`) → Google FaviconV2 → SF Symbol on tinted background. URLCache caches across launches. **Clearbit (`logo.clearbit.com`) was removed** — HubSpot sunset the free Logo API on 2025-12-01 and its host no longer resolves; leaving it as source #1 made every logo eat a DNS failure before falling through. Do not re-add it.
- **Logos + flags are bundled** (`VirtualSIM/BundledLogos/<domain>.png`, `VirtualSIM/BundledFlags/<code>.png`). `ServiceLogo`/`FlagImage`/`FlagCircle` render the bundled PNG **first** (via `BundledImageStore.shared`) and only fall back to the network cascade above for catalog entries not yet bundled. The Xcode file-system-synchronized group **flattens** these into the bundle root, so lookup is by flat filename (`Bundle.main.url(forResource: "<key>.png", withExtension: nil)`) — do NOT expect a `BundledLogos/` subdirectory at runtime. Logo key = `Service.domain`; flag key = `Country.flagImageCode` (`uk`→`gb`). After the catalog grows, regenerate + commit with `scripts/fetch-bundled-assets.sh --refresh`, then ship an app update; new services/countries work via the network fallback in the meantime.
- **Apple Sign-In is iOS-native flow** — no JWT secret needed in Supabase (the apple provider config). The dashboard's secret/services-id fields stay blank.
- **Never present seed data as measured fact.** `Service.successRate` is seed data (86–99% across all 268 services, avg 91%) and `Service.swift` says so explicitly. Show only `AppState.successRate(for:country:)` / `deliveryOdds` / `DeliveryNotice`, which are gated on real observed samples, and show **nothing** when there's no measurement. `WaitingScreen` was the last violator — it promised ~91% right after payment on clusters that actually measure ~9%. Same rule for eSIM coverage: the parser returns `null` rather than guess, because a wrong coverage claim is worse than none since the user acts on it.
- **Review prompt must stay incentive-free (App Store 5.6.4).** `OtpScreen` calls Apple's native `@Environment(\.requestReview)` (needs `import StoreKit`) on code delivery, gated by `AppState.shouldRequestReview(forOrderId:)` — fires only from the 2nd successful code onward, at most once per app version, de-duped per order. **Never** tie credits/rewards to leaving a review, and **never** build a custom review UI that deep-links to the App Store page — both are rejectable. A no-strings welcome/bonus credit is fine as long as it isn't conditioned on a review.

- **`xcodebuild` can refuse to build while the code is perfectly fine.** Symptom:
  `Unable to find a destination matching the provided destination specifier` with
  `iOS 26.5 is not installed. Please download and install the platform from
  Xcode > Settings > Components` — listed against *device* destinations, including
  `Any iOS Device`. This is NOT a code problem and NOT a signing problem:
  - `xcodebuild -showsdks` lists iOS 26.5, and BOTH SDKs are on disk
    (`iPhoneOS26.5.sdk`, `iPhoneSimulator26.5.sdk`).
  - But `xcrun simctl runtime list` shows only **iOS 27.0** installed; the 26.x
    runtimes appear under `Unavailable:` — stale references left behind when
    Xcode updated. Xcode will not offer a simulator destination whose runtime is
    NEWER than its SDK, so with SDK 26.5 + runtime 27.0 there are no eligible
    simulator destinations at all.
  - It cannot be repaired by re-downloading 26.5. Verified live:
    `xcodebuild -downloadPlatform iOS` → `No matching downloadable found`, and
    `xcodebuild -downloadPlatform iOS -buildVersion 26.5` →
    **`iOS 26.5 is not available for download`**. Apple has stopped shipping it,
    so the Components GUI cannot supply it either.
  - The real fix is therefore to **install an Xcode whose SDK matches the
    installed runtime** (iOS 27.0 is already on disk, 7.8 GB, `Ready`), not to
    chase the 26.5 runtime. Until then this Mac can type-check but not archive.
  To verify code WITHOUT fixing any of this, use the `swiftc -typecheck` command
  at the top of this file — the project has zero SwiftPM dependencies, so it
  type-checks all 72 sources against the simulator SDK and needs no runtime.
  Archiving still needs the platform installed, so this blocks shipping a build
  even though it does not block verifying one.

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

## Current state (2026-07-21)

- **SMS: SMSPVA.** Balance is monitored; it was **$11.26** (~22 orders) at last check — `/balance` in Telegram is the fastest way to see it.
- **eSIM: SMSPool**, balance **$3.50** and flagged low. Funds eSIMs only, so a low reading here is NOT an SMS outage.
- Catalog: ~18.5k routes, **0 below the 3× margin floor**; 1081 active eSIM plans, all disclosing coverage as "<Country> only".
- All iOS changes type-check (exit 0) but are **unbuilt and unshipped** — see the `xcodebuild` gotcha. Shipping 1.5 is blocked solely on installing an Xcode whose SDK matches the iOS 27.0 runtime already on disk.
- Known-open, none of them blocking: `check-esim-usage` never sets `expires_at` (eSIM expiry is dead code, so lapsed 1-day plans still show active); no guard against tapping "Install eSIM" twice with a single-use LPA; `pollActiveOrder` swallows every error so "Check now" can look dead during a provider hiccup; an in-flight order isn't auto-resumed after the app is killed; `routes` cost columns are readable unauthenticated (competitor-visible margin book); `cron.job_run_details` has no retention (~2.9k rows/day).

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

**Submitting is fully headless via the App Store Connect API** (no Xcode Organizer) — see the `app-store-submission-asc` memory for the exact working pipeline: `xcodebuild archive` with `-allowProvisioningUpdates -authenticationKeyPath/-authenticationKeyID/-authenticationKeyIssuerID` (auto-provisions the Distribution cert; the Mac only has an *Apple Development* cert locally, which is fine) → patch `BuildMachineOSBuild` (above) → `xcodebuild -exportArchive` → `xcrun altool --upload-app` → ASC REST API (`POST /v1/appStoreVersions`, attach build, set `whatsNew`, `reviewSubmissions` submit). ASC API key lives at `~/.appstoreconnect/private_keys/AuthKey_R5ZVLBTUR6.p8`; app id `6774768570`. Store state: **1.3 (build 12)** approved & released; **1.4 (build 13)** submitted 2026-07-19, WAITING_FOR_REVIEW (release type MANUAL — release it after approval) — the next build is **1.5 (build 14)** (bump `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION` in `project.pbxproj`). Submission gotcha: only one review submission can be in flight per platform — standalone IAP submissions (created via ASC UI) block the version submission with an opaque 409 "not in valid state"; cancel them first, submit the version, then resubmit IAPs via `POST /v1/inAppPurchaseSubmissions` (IAPs can NOT be added as `reviewSubmissionItems` through the public API).

`docs/submission-checklist.md` is the source of truth for App Store submission steps. `docs/app-store-listing.md` has all metadata copy + nutrition labels pre-filled. Legal docs (`privacy-policy.md`, `terms.md`, `refund-policy.md`, `help.md`) are written to be pasted into Notion as public pages — URLs then go into `VirtualSIM/LegalLinks.swift`.
