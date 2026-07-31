# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**vSMS** (App Store display name; formerly "vSIM OTP" — the Xcode target/scheme is still `VirtualSIM`) — iOS app selling two products, both paid with in-app **credits**: (1) **temporary phone numbers** for SMS verification codes and (2) **eSIM data plans** priced at 4× wholesale. iOS frontend in SwiftUI + Supabase backend (Postgres + Auth + Edge Functions + pg_cron).

**Provider split as of 2026-07-30 — HeroSMS + SMSPVA for SMS (split per
SERVICE), SMSPool for eSIMs only, virtualsms and SMSPool-SMS deleted.**

SMS-Activate — the one provider we had flagged as defensible — **closed
2025-12-22** (API hostnames NXDOMAIN), and on its closure page it names
**HeroSMS** as the successor. HeroSMS runs SMS-Activate's `handler_api`
protocol, and its `getPrices` exposes **`physicalCount`** — real-SIM stock per
(service, country), which SMSPVA never gave us. That matters because Meta's
properties reject VoIP ranges and are ~53% of order volume at ~12% delivery: on
SMSPVA we could only *guess* VoIP by regex-matching operator names against
`^(Donor|Other_|MVNO_|Total_)`.

**Ownership is per SERVICE, never per route** (owner decision): a service
HeroSMS carries goes entirely to HeroSMS; one it doesn't stays entirely on
SMSPVA. That keeps 265 services instead of the ~148 HeroSMS maps, without ever
splitting one service across two providers — which is what keeps per-service
evidence meaningful. **There is no fallback between providers**: `providerOrder()`
returns exactly one, so a HeroSMS stockout fails as a stockout rather than
silently re-reserving at SMSPVA under a different price and delivery profile.
SMSPVA stays fully wired as the rollback target and its routes are never deleted.

`providerOrder()` in `_shared/providers.ts` is the single source of truth for SMS
routing; order/poll functions call the router, never a provider.

The provider has now changed three times, and every switch broke something that
threw no error, because **`routes` is ONE row per (service_id, country_id) with
`provider` as a column** — re-homing rows strands any combo the new provider
can't serve. If you switch again, re-read the "provider switch checklist" below;
it has a new entry that the HeroSMS cutover added.

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
supabase functions deploy poll-active-orders sync-prices sync-herosms sync-esim-plans \
  sync-smspva-operators sync-smspva-conversions winback telegram-notify telegram-webhook \
  daily-credit --no-verify-jwt
# daily-credit (cron relay-daily-credit, 11 16 * * *) sends the "claim your free
# credit" push. It is cron-gated, so it MUST stay in this --no-verify-jwt group.
# sync-herosms (cron relay-sync-herosms, 37 * * * *) records HeroSMS's real
# per-route cost + physicalCount and hides what HeroSMS cannot serve. It does
# NOT touch retail_credits — see "Why sync-herosms exists" below.
# DELETED 2026-07-30: sync-virtualsms/, sync-smspool/, smspool-catalog/ — all
# three are gone from disk AND undeployed.
# ⚠️ The two lists above do NOT cover everything: there are 24 function
# directories besides _shared, and `telegram-setup` appears in NEITHER list. It
# is cron-gated and fails closed so there is no exposure, but rotating
# TELEGRAM_WEBHOOK_SECRET requires re-running it — deploy it --no-verify-jwt.
# (This comment previously claimed the lists covered "every directory … 19
# functions total". Both halves were wrong.)

# Query the remote DB
supabase db query --linked "select count(*) from public.routes;"

# Trigger any cron-gated function WITHOUT handling the secret yourself. pg_net
# calls it server-side and private_cron_secret() never leaves the database.
# Live pg_cron schedule (15 jobs, all active — re-verified 2026-07-30 15:12Z):
#   relay-poll-active-orders  * * * * *     relay-telegram-notify  * * * * *
#   watchdog                  */10 * * * *  relay-sync-prices      17 * * * *
#   relay-sync-herosms        37 * * * *    (offset from sync-prices on purpose)
#   relay-sync-smspva-conversions 49 * * * *  relay-sync-esim-plans 0 2 * * *
#   relay-sync-smspva-operators 30,32,34,36,38,40 4 * * *  (6 chunked slots)
#   relay-winback             0 15 * * *    relay-daily-credit     11 16 * * *
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
(exit 0 = all 84 sources compile). It does NOT catch everything — a missing
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
  SMS  → HeroSMS (hero-sms.com), for       create-esim-order/check-esim-usage
         every service it carries          sync-prices (hourly :17, + catalog
  SMS  → SMSPVA (api.smspva.com), for        maintenance) / sync-esim-plans (daily)
         services HeroSMS lacks            sync-herosms (hourly :37)
         + the rollback target             telegram-notify (cron 1 min) /
  eSIM → SMSPool (api.smspool.net)         telegram-webhook (public, 2-gate)
  Split is per SERVICE, no fallback        redeem-referral / winback
  smspool-SMS + virtualsms DELETED         register-push / iap-verify / delete-account
                                            sync-smspva-operators (nightly, chunked)
APNs ←── token-auth (.p8) HTTP/2            sync-smspva-conversions (hourly :49)
Telegram ←── ops alerts + 6h digest         daily-credit (cron 11 16)
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
- `supabase/functions/_shared/` — `providers.ts` (unified router; per-SERVICE split HeroSMS/SMSPVA with NO cross-provider fallback — order/poll functions call this, NOT a specific provider), `herosms.ts` (SMS-Activate `handler_api` wrapper), `smspva.ts` (v2 REST wrapper), `smspool.ts` (eSIM + balance ONLY — the SMS surface was deleted 2026-07-30), `apns.ts` (HTTP/2 + JWT), `cors.ts`, `iap.ts` (Apple receipt chain verification), `telegram.ts`, `opsFormat.ts`, `supabaseAdmin.ts`. `virtualsms.ts` is **gone**.
- `supabase/functions/<name>/index.ts` — one per endpoint, all Deno.serve
- `supabase/README.md` — deployment + secret setup walkthrough

**Key SQL functions** (all `SECURITY DEFINER`, all revoked from `anon`/`authenticated` — clients reach them only through edge functions on the service role):
- `begin_order(user, service, country, credits)` — dedupe + insert order + charge, in ONE transaction under `pg_advisory_xact_lock(user)`. See the gotcha below; do not go back to charging before the row exists.
- `wallet_spend` / `wallet_credit` — atomic single-statement balance moves. Always pass `p_order` so the ledger reconciles.
- `credit_iap_purchase(user, receipt, amount, transaction_id, original_transaction_id)` — **the only way to credit an Apple purchase.** Tombstones `transaction_id` in `iap_grants` and credits in ONE transaction under an advisory lock, returning `granted` / `already_granted` / `invalid_amount`. Idempotent, so a caller that is unsure whether a previous attempt landed simply calls it again — that is both the duplicate check and the recovery. Never call `wallet_credit` directly for an IAP; it has no replay guard.
- `active_sms_provider()` — returns whichever provider owns the most `active` routes. Maintenance functions default to it so a provider switch can't silently orphan them again. **⚠️ It is WRONG as of 2026-07-30 and returns `smspva`.** It was written for a winner-take-all world; the HeroSMS cutover deliberately made the catalog a per-service *split*, and then `sync-herosms` hid 4,849 routes HeroSMS cannot serve — so SMSPVA now owns **7,757** active routes against HeroSMS's **5,198** and wins a vote it should not be in. It is still the wrong metric. **This file claimed on 2026-07-30 that it was "no longer load-bearing". That was FALSE, and the audit on 2026-07-31 found two live consumers it had missed** — `refresh_evidence_all_providers()` fixed only the three refreshes it wraps:
  - **`refresh_arrival_timing`** is a SEPARATE entry in `sync-prices`' maintenance list, outside the wrapper. It measured SMSPVA only (38 of 46 arrivals) and stamped that band onto all 268 services, so every "most codes arrive within N" quote in the app described the retired provider. Fixed in `20260731070000`/`20260731080000`.
  - **`recent_sms_delivery_rate()`** still scopes to the vote, returned NULL on a 4-order SMSPVA sample, and through it `stranded_credit_candidates` was permanently empty. Fixed by deleting that cohort's gate; **the rate function itself still uses the vote and is still wrong** — it is only no longer load-bearing because nothing gates on it now. If you add a consumer, scope it per-provider.

  Before assuming a consumer is safe, grep for it: `select proname from pg_proc where prosrc like '%active_sms_provider%'`. Do not wire anything new to it.
- `refresh_evidence_all_providers()` — **the only evidence entry point `sync-prices` calls.** Runs the route + service refreshes once per provider that owns active routes, then country evidence once. See "Evidence must describe the provider that serves the NEXT order" below.
- `refresh_route_observed_success` / `refresh_service_delivery` / `refresh_country_delivery` / `sync_service_visibility` / `apply_measured_service_ranking` — catalog self-correction. The first three are now called **through the wrapper**, not directly.
- `ops_snapshot(interval)` — one JSONB blob powering both the Telegram digest and `/stats`.

### HeroSMS API — what cost us time (probed live 2026-07-30)

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

`sync-prices` formula: `credits = max(1, ceil(price / 0.05))` — 1 credit per started 5¢ of wholesale (`CREDIT_DIVISOR = 0.05`, duplicated in exactly **two** files as of 2026-07-30 — `sync-prices` and `sync-smspva-operators`, which prices the premium tier; tune it for global margin adjustment). Order-time enforcement matches: `create-order` has `MIN_MARGIN = 6.0` / `NET_USD_PER_CREDIT = 0.30`, so the max we pay a provider is `credits × $0.05` **plus `CEILING_HEADROOM_USD` ($0.10)**, enforced on the actual charged cost with cancel-and-fallback. Keep the divisor and the margin pair in lockstep; raising one alone either blocks honest routes or leaks margin.

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
A plain `0.5*new + 0.5*prev` averages a rise against yesterday's cheaper price and sets retail BELOW what you're about to pay. That shipped once and put **4,384 routes under wholesale** in a single run. Both retail-setting syncs (`sync-prices`, `sync-esim-plans`) have the ratchet — if you add another pricing path, give it one too. `sync-herosms` deliberately has none: it records the **raw** observed cost and never derives retail, so smoothing there would only blur the number the margin gate reads.

**eSIM** plans (`sync-esim-plans`) are priced **separately** at 4× wholesale (raised 3× → 4× on 2026-07-25) — `ESIM_MARGIN = 4`, `CREDIT_VALUE_USD = 0.48`, `retail_credits = ceil(usd * 4 / 0.48)` — NOT via `CREDIT_DIVISOR`, so the two product lines never collide. Inverted, the order-time ceiling in `create-esim-order` is `credits * 0.12`: SMSPool's `/esim/purchase` accepts no price cap and its response reports **no cost at all**, so the function takes a fresh `/esim/plans` quote, blocks above the ceiling, and writes that real number into `actual_cost_cents`. It fails **closed** on a bad price and **open** on a failed lookup — an unreachable SMSPool must not make eSIMs unbuyable. (Before this, `actual_cost_cents` echoed the cached catalog price, so margin analysis over it was circular and could never reveal drift.)

**The divisor is PER PROVIDER as of 2026-07-31 — HeroSMS 0.025 (12×), SMSPVA
0.05 (6×) — and `sync-herosms` now sets `retail_credits`.**

| provider | priced by | divisor | `MIN_MARGIN` | `0.30 / MARGIN` |
|---|---|---|---|---|
| herosms | `sync-herosms` | **0.025** | **12.0** | 0.025 ✓ |
| smspva | `sync-prices` | 0.05 | 6.0 | 0.05 ✓ |

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

### Why `sync-herosms` exists (hourly :37)

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
product**, out-earning everything else in the 24h to 2026-07-30. So four packs
(`credits.5/12/30/60`) are live; only `credits.150` is not, and it was
**submitted for review 2026-07-30 06:53Z** once `credits.60` cleared a slot in
Apple's 2-in-flight cap.

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

Route-level evidence covers **3 of 12,900 active routes**, so essentially every
route still falls through to the tie-break — and until 1.7 that tie-break was
price. `public.service_country_ranks` (387 rows / 80 services, fed by the manual
collection loop above) is what replaces it.

The case in one line: for `google` the cheapest bookable route was **Kenya at 1
credit, which has delivered 0 of 9**, while **Cameroon costs 2 credits and the
provider reports 59.3%**. Price picked Kenya every time.

- **`AppState.rankedUntestedKey`** orders untested routes by *(country tier,
  vendor score, country score, price)*. Wired into `bestCountry` and
  `affordableFallbackCountry`; `CountrySheet`'s "Best success" sort uses the same
  ordering, so the default sort finally leads with countries that deliver.
- **A MISSING rank scores 0 — neutral, never a penalty.** This is the single
  easiest way to poison the whole thing. The source is a top-10 gated at 50+
  activations, so absence means "did not rank or lacked traffic", never "bad".
  leboncoin returns **2** countries against **33** active routes; treating
  absence as a low score would wrongly demote 31 good routes.
- **Our own measurement always outranks theirs.** A measured route wins outright,
  and `RecoveryScreen` only offers a ranked country when we have measured nothing
  — and never the country that just failed.
- **It is NEVER a badge.** `SuccessBadge`/`DeliveryRecord` state what happened to
  orders WE placed ("Worked 3 of 7 times"). This is a third party reporting on
  its own inventory across all its customers. The UI keeps them apart: a separate
  captioned "Top success rates" section, rows worded **"reports 36%"** rather
  than a bare percentage, and no borrowing of `theme.live`. Collapsing the two is
  precisely what made SMSPVA's seeded grade rank never-sold routes as "proven"
  until it had to be demoted to `.notTested`.
- **Exposure, accepted knowingly:** rendering these figures publishes HeroSMS's
  quality data to anyone holding the publishable key. Inherent to showing a
  number. Mitigated to four columns, and the table is `authenticated`-only with
  no anon policy — stricter than `routes`, which has a `public read` policy.
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
**up** ("Most codes arrive within 3 min"), which also lines up with the 180s
minimum hold. `typicalWaitShort` keeps p50 for browse/compare surfaces, where
there is no clock and no destructive button.

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
Measured 2026-07-30: **all 265 visible services are bookable in at least one
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
**"Cancel & refund N cr"** lower down the screen, still gated by the 180s hold.
A named destructive action does not need a confirmation dialog the way a ✕ did.

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

### Evidence must describe the provider that serves the NEXT order

Two bugs, both silent, both fixed 2026-07-30 (`20260730220000`, `20260730230000`).

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
- **A constant duplicated across files WILL drift.** `MAX_WHOLESALE_CENTS` lives in three sync functions (and as `MAX_ORDER_COST_USD` in `poll-active-orders`, and as `LOW_BALANCE_USD` in `_shared/opsFormat.ts`). Changing it in one place on 2026-07-27 stripped 1,432 routes of their carrier pin and premium price, and left the digest warning at $20 while the pager fired at $37.50. Same for `CREDIT_DIVISOR` (**two** copies since `sync-smspool` was deleted — `sync-prices` and `sync-smspva-operators`) and `ESIM_MARGIN`/`CREDIT_VALUE_USD` (two each). `MAX_WHOLESALE_CENTS`'s three syncs are now `sync-prices`, `sync-smspva-operators` and `sync-herosms`. Change them in one commit or consolidate them into `_shared/`.
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
  committed. (This is also why `find VirtualSIM -name '*.swift' | wc -l` reads 75
  in a working checkout but 74 in a bare worktree.)
- **`isOk()` from `_shared/smspva.ts` dereferences its argument and callers pass
  it `null`.** `providers.ts` does `smsGetBalance().catch(() => null)` and then
  `isOk(before)` / `isOk(after)`; `isOk` reads `r.statusCode`, so a thrown
  balance call makes it a `TypeError` **after the number is already reserved** —
  charge, refund, and forfeited wholesale on a number we abandon. Live on the
  SMSPVA path (7,757 active routes). Caught by `deno check` 2026-07-30, present
  since `91dc756`, **not yet fixed**; the fix is `before && isOk(before)`.
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
8. **Re-check `active_sms_provider()` AFTER the dust settles, not just after the re-home.** Added 2026-07-30, learned the hard way. It picks by *active route count*, which silently assumed one provider owns the catalog. A per-service split plus a sync that hides unfulfillable rows can leave the **retired** provider holding more rows than the live one — which is exactly what happened (SMSPVA 7,757 vs HeroSMS 5,198), pointing all five `refresh_*` evidence functions at the wrong provider with no error anywhere. Assert it returns what you expect, and re-assert it after the first sync run, not before.
9. **Give the new provider its own cost column, and scope every cached-cost fallback to the provider that owns the row.** `sync-prices` only maintains SMSPVA's `last_cost_cents`, so any other provider's rows carry a frozen number from a provider you are no longer buying from. A `??` onto that stale value passes the margin gate and then fails at reservation — a charge-and-refund that looks like a stockout. See `sync-herosms`.

## Current state (2026-07-31, end of session)

**1.6 (build 19) went `READY_FOR_SALE` on 2026-07-31** — so the splash, the
wordmark, System/Light/Dark, the service-picker fix, temp e-mail, support chat,
the non-destructive ✕ + `ResumeBar`, `PurchaseIntent` and the `real_sim_only`
Route field are all LIVE to users. The long backlog of "client-side work in no
installable build" is finally cleared.

**1.7 (build 20) is `WAITING_FOR_REVIEW`**, submitted 2026-07-31 20:05Z. It
carries the provider-deliverability steering, the "Top success rates" list and
the ranked retry prompt. Two review slots are used (1.7 + the `credits.150` IAP
from 2026-07-30), which is Apple's per-platform cap.

### What 2026-07-31 changed (all backend halves LIVE)

- **A red-team audit found four jobs silently doing nothing**, each reporting
  success: `refresh_arrival_timing` measuring only SMSPVA and stamping that band
  on all 268 services; `stranded_credit_candidates` structurally closed by a SQL
  gate whose "replacement" only ever landed in TypeScript; `begin_email_order`
  counting FAILED free orders against the daily cap; and `email_orders` having no
  expiry sweep at all. Plus three edge-function bugs — an SMSPVA timeout that
  bought the number TWICE, a pre-reservation cancel that forfeited wholesale for
  free, and `delete-account` leaking every number the late-code rescue was
  watching. All fixed and deployed (`20260731070000`, `20260731080000`).
- **Per-provider pricing.** `CREDIT_DIVISOR` is now 0.025 (12×) for HeroSMS and
  stays 0.05 (6×) for SMSPVA, with `create-order` resolving `MIN_MARGIN` per
  provider. `sync-herosms` sets `retail_credits` for the first time. HeroSMS
  median retail **15 → 6 credits**, mean realised margin **97× → 14×**.
- **`real_sim_only` routes are SOLD again, at the standard price** with the real
  carrier pinned strictly, and `real_sim_only_sellable` is flipped **true**.
  facebook/instagram/whatsapp went from **one bookable route each** to 49/50/49.
- **The provider's deliverability data is now collected and used.** Endpoint
  found (session-scoped, see above), `vendor_deliverability` + the mapper +
  `service_country_ranks` (387 rows / 80 services), a browser collector, and
  client steering that finally replaces price as the tie-break between untested
  routes.
- **HeroSMS cutover shipped 2026-07-30** (backend, live): `_shared/herosms.ts`;
  per-SERVICE `providerOrder()` with no cross-provider fallback; `sync-herosms`
  (hourly :37) recording real cost + `physicalCount` and hiding 4,849
  unfulfillable routes; provider-scoped cached-cost fallback in `create-order`;
  premium hard-refused on HeroSMS routes; `smspool.ts` trimmed to eSIM + balance
  with its `errors[]` shape finally parsed; `sync-virtualsms`/`sync-smspool`/
  `smspool-catalog` deleted; `config.toml` `max_rows` 1000 → **60000** (it did not
  match the live value, so any config push would have hidden 94.6% of routes);
  `/revenue` split from `/profit`.
- **First HeroSMS order delivered** — 2026-07-30 13:40Z, alibaba/mx, standard,
  `received`. **1 of 1.** $0.10 wholesale against 4 credits = **12.0× realised**
  (with `MIN_MARGIN` still 6.0 — see the pricing note).
- **Temporary EMAIL shipped 2026-07-30** (backend live, client in build 19):
  `_shared/heromail.ts` + `emailStatus.ts`, `email_orders` schema with the free
  daily cap, `create-email-order` / `check-email-order` / `email-domains`, and the
  iOS Numbers/E-mails toggle with a live-stock domain picker. **First activation
  delivered**: leboncoin, free tier, `received`. See the section above.
- **Live support chat shipped 2026-07-30** (backend live, client in build 19):
  `support_threads`/`support_messages`, `support-send`, and `telegram-webhook`
  widened to handle the [Accept] button and the owner's replies. **Never
  exercised end to end** — the round trip needs the bot secrets.
- **Also 2026-07-30**: the waiting-screen ✕ made non-destructive + `ResumeBar`;
  `PurchaseIntent` replacing the `creditsShortfall` inference; email orders added
  to history (`loadEmailOrders` had had NO caller); and the `isOk(null)`
  charge-and-forfeit bug in `providers.ts` fixed.
- **Codebase**: `MARKETING_VERSION 1.7`, `CURRENT_PROJECT_VERSION 21`, iOS min
  **18.0**, **96** Swift sources (Release BUILD SUCCEEDED on iPhone 17 Pro /
  iOS 26.5, zero warnings), **117** migration files, **24** edge functions.
  Localizable.xcstrings: 342 strings, **0 untranslated** across all 6 locales.
- **Catalog**: 18,492 routes, **12,900 active**. **HeroSMS 5,143 / SMSPVA 7,757**.
  Only **3 measured routes** — HeroSMS volume is still tiny, see Known-open. 265
  visible services, 69 countries, 1,081 eSIM plans (all `hidden`, line paused).
  **16** pg_cron jobs, all active (+`expire-email-orders`). Watchdog `failing: []`.
  `service_country_ranks`: 387 rows / 80 services.
- **Balances (2026-07-31): HeroSMS $10.36, SMSPVA $5.26, SMSPool $7.23.** All
  `low`; ladder `[37.50, 22.50, 11.25, 7.50]` = 5×/3×/1.5×/1× the $7.50 ceiling.
  **SMSPVA is now BELOW the single-order ceiling**, so a max-price order on an
  SMSPVA route cannot be funded at all. **Top up HeroSMS — it serves the demand.**
- **Delivery, orders that got a number, live providers only** (measured
  2026-07-31): last 7d **15/57 = 26%**, the 8–30d window before it **28/82 =
  34%**. Excluding the US from BOTH windows the decline persists (38% → 29%), so
  the honest statement is **"not measurably improved"**, not "worse" — n is too
  small to separate those. **HeroSMS all-time is 5/24 = 21%** against SMSPVA's
  frozen 34% baseline: see the rollback checkpoint in Known-open. US is ~10-11%
  against 29-38% elsewhere but is only 14% of volume, so it is not the cause.
  Never quote a blended rate — it averages retired providers with live ones.
- **Retention re-measured 2026-07-31**: **203** users, **44** ever ordered
  (21.7%, flat), **20** ever got a code, **14** ever purchased. The old "13 got a
  code → 12 purchased (92%)" does NOT survive: of the 20 who received a code only
  8 purchased, and 6 buyers never received one. See the Retention section, which
  now records that purchase PRECEDES delivery and that cross-day retention is 5
  people.

### Known-open

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

- 🔴 **LIVE INCIDENT (2026-07-31): the Meta services have ONE bookable route
  each.** Gating `real_sim_only_sellable = false` to protect build 18 from the
  `real_sim_required` dead-end had a side effect nobody measured: facebook is
  **1 active route at 38 credits** (47 gated), instagram **1 at 10 cr** (48
  gated), whatsapp **1 at 149 cr** (50 gated). Those three are **85 of 190
  orders ever — ~45% of all demand** — and a new user with the 3-credit grant
  cannot order any of them. WhatsApp at 149 credits exceeds the largest
  *approved* pack (60), so it needs three stacked purchases. The gated routes
  carry 56–153× margin, so there is no cost reason for the price.
  **The fix that does not wait for build 19 adoption:** in `create-order`, when
  `real_sim_only` is true and the client sends `standard`, pin the real carrier
  **strictly** and charge `retail_credits` — premium behaviour at the standard
  price, trivially affordable at that margin — then flip the flag. That is a
  pricing decision, hence not taken unilaterally. Revert is one UPDATE; the next
  hourly `sync-herosms` re-hides.

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

- ✅ **RESOLVED 2026-07-31: 1.6 (build 19) is `READY_FOR_SALE`** and 1.7 (build
  20) is `WAITING_FOR_REVIEW`. The client backlog is cleared. Note the
  distinction that still matters below: RELEASED is not ADOPTED — users on 1.4
  and 1.5 exist for weeks, which is what the deferred column revokes wait on.
- ✅ **RESOLVED 2026-07-31: real_sim_only routes are SOLD, not gated.**
  `create-order` now serves a standard-tier request on such a route by pinning
  the real carrier **strictly** and charging `retail_credits` — premium
  behaviour at the standard price, which forgoes the 20% uplift on routes
  running 56–153× margin. That removes the dead end for every shipped client
  with no client change and no new error code, so
  `real_sim_only_sellable` is now **true** and 0 routes are gated.
  facebook/instagram/whatsapp went from **1 bookable route each** to 49/50/49,
  and the 3-credit grant now reaches 17 facebook and 25 instagram routes where
  it reached none. Two properties are load-bearing: the pin is forced to
  `premiumPin` (not `standardCarrier`, which goes null when the cached operator
  cost misses the ceiling and would leave the order filled from the VoIP pool
  the route exists to avoid), and `strictPin` is true (a fallback fill on a
  VoIP-rejecting service is a number certain to be refused — failing as a
  stockout is correct, charging for it is not). The 409 survives only for a
  strict service with no carrier at all. Revert = flag false + one hourly run.
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
- ✅ **RESOLVED — the late-code rescue HAS executed in production.** This file
  said it never had; two independent audits found the same counter-example on
  2026-07-31. Order `ea7c0ddb-3331-41cf-be3c-420a1809e10d`, SMSPVA, cancelled
  2026-07-28 21:50:47Z, OTP `377647` written onto the `canceled` row **14
  seconds later** and pushed. It works exactly as designed. Zero rows currently
  carry `late_watch_until`, which means the sweep is draining, not that it has
  never fired — do not read an empty column as "unproven" again.
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

- ✅ **RESOLVED 2026-07-31: the relay/function budget mismatch WAS biting, and
  it could strand a refund.** `relay-poll-active-orders` granted 30s while
  `poll-active-orders` sizes `limit(200)`/`limit(50)`/`limit(50)` against the
  ~150s edge limit. Found by chasing a watchdog `relay-http` alert: **2 pg_net
  timeouts in 6 hours against 739 successful relays, both exactly 30000 ms**,
  after five clean hours — so it is rare, real, and was invisible until the
  watchdog said so.

  The rate was not the problem. The **expiry sweep claimed the order terminal
  and refunded it in two separate round-trips**, and a worker killed between
  them left the order `expired` with the charge never refunded — terminal rows
  are never revisited, so nothing would ever retry it. A TypeScript rollback
  cannot cover that case, because the process is gone. `check-order` already
  had it right: `expire_order()` locks the row, re-checks `waiting`, flips the
  status and refunds in ONE transaction.

  Fixed in `20260731140000`: **`expire_order_claim(uuid) returns boolean`** holds
  the single implementation and the sweep calls it (it needs the boolean to push
  and count exactly once); `expire_order(uuid) returns void` is now a thin
  wrapper so `check-order` is untouched and the two bodies cannot drift. Relay
  timeout raised **30000 → 120000**, matching `daily-credit` and
  `sync-esim-plans` and staying under the ~150s ceiling. Overlapping runs were
  already safe — every status write is an atomic claim, which the function's own
  comments give as the reason two sweeps cannot both refund one order.

  **The general rule:** a status claim and its refund must be ONE transaction,
  never two round-trips. Anywhere those are split, a killed worker is an
  unrefundable charge, and no timeout value fixes it.
- ⚠️ **Route-level evidence is 3 rows, for an honest reason.** A route needs 3
  conclusive attempts and HeroSMS has ~24 orders total. Service and country
  evidence rebuild first. Nothing to do but let volume accumulate — it is now
  *capable* of accumulating, which it was not. **This is exactly the gap the
  provider deliverability data fills** (see the steering section): until our own
  measurement exists, the vendor's ranking is the only thing standing between an
  untested route and a price-based tie-break.
- ✅ **RESOLVED 2026-07-30: `physicalCount` now gates the Meta services.**
  `voip_strict_services` + `sync-herosms` hid **62** VoIP-only routes; every
  active facebook/instagram/whatsapp route now has real SIMs (69→47, 69→48,
  64→45). Stamped on each order as `route_physical_count` so the effect is
  measurable — **run that query in ~2 weeks before trusting the change.**
- 🔴 **HeroSMS is at 5 of 24 (21%) and APPROACHING THE ROLLBACK CHECKPOINT.**
  This file said "proven by exactly ONE order, 1/1" — that is stale. The
  pre-registered trigger is *"conclusive delivery over the first 40 orders
  materially below SMSPVA's frozen baseline"*; SMSPVA's baseline is **34%** and
  HeroSMS is running **21%** at 24 orders. **Re-evaluate at 40.**
  `providerOrder()` back to `["smspva"]` is still a one-line revert — but note
  SMSPVA's balance is $5.26, below the single-order ceiling, so a rollback needs
  a top-up first.
- ✅ **RESOLVED 2026-07-31: repricing shipped, per-provider.** `CREDIT_DIVISOR`
  0.025 (12×) for HeroSMS via `sync-herosms`, 0.05 (6×) unchanged for SMSPVA via
  `sync-prices`, with `create-order` resolving `MIN_MARGIN` per provider. The
  originally-agreed UNIFORM 0.025 was modelled first and rejected: it doubles
  SMSPVA, taking its 3-credit reach from 729 routes to 16. See the pricing
  section for the comparison table.
- ✅ **RESOLVED 2026-07-30: the `isOk(null)` TypeError on the SMSPVA order path.**
  Now `before && isOk(before)`, and `create-order` HAS since been redeployed
  (2026-07-31), so production runs the fix.
- 🔴 **Nothing in the email or support paths has been used by a real person
  through the app.** The client for both ships in build 19 and Apple Sign In does
  not work in the simulator, so every screen is verified by build + screenshot
  only. The email money path is proven at SQL level and one activation was
  bought via the API; the support round trip (send → Accept → reply → push) has
  **never run**, because it needs `TELEGRAM_BOT_TOKEN` / `TELEGRAM_WEBHOOK_SECRET`.
- ✅ **RESOLVED 2026-07-31: `expire_email_orders()` (pg_cron `*/5`).** The gap
  was worse than "the refund waits for a poll", which is why it is worth
  recording how it actually failed: `check-email-order` deliberately refuses to
  invent a terminal state on a provider fault and delegates expiry to "the cron
  sweep" — so for an activation the provider had already forgotten (404), the
  local 22-minute expiry sat BEHIND a successful provider read and was
  unreachable for exactly the rows that needed it. Meanwhile `ResumeBar`'s email
  branch has no age bound (the SMS branch does), so one abandoned order pinned
  "Waiting for a code" above the tab bar on every tab, forever.

  Two things that would have made a copied `expire_esim_orders()` look like a
  working deploy while matching nothing: **`email_orders.expires_at` is a dead
  column** — nothing has ever written it, so keying on it matches zero rows —
  and the terminal status must be **cast** (`::email_status`), because a CASE
  yields `text` and the UPDATE raises 42804 without it. Both were hit for real.
  It keys on `created_at + 22 minutes` (== `EMAIL_WINDOW_SECONDS`), promotes
  `code is not null` to `received` and never refunds it, refunds only paid
  codeless rows, and writes `app_config.email_expiry_heartbeat` so the watchdog
  can see it. It calls no provider: HeroSMS auto-refunds us at ~21 min, so there
  is nothing to reclaim and no reason to make it an edge function.
- ⚠️ **Email is absent from `ops_snapshot` / `revenue_snapshot` /
  `_shared/opsFormat.ts`.** Per the third-product-line checklist it must be added
  to all three or it is invisible in the digest, `/stats` and `/profit`.
- ⚠️ **The HeroSMS API key passed through a chat transcript and should be
  rotated.** It lives only as the `HEROSMS_API_KEY` Supabase secret and appears in
  no commit (verified), but rotate it.
- ✅ **RESOLVED 2026-07-30: `credits.60` is `APPROVED` and selling** ($24.99 USD
  ×2 in one morning — the top revenue product). `credits.150` was submitted
  2026-07-30 06:53Z (`WAITING_FOR_REVIEW`, IOS) the moment `credits.60` freed a
  slot in the 2-in-flight cap. `MAX_WHOLESALE_CENTS = 750` is justified as
  "150 credits × $0.05", so until 150 clears, routes in the 80–150 credit band
  still need 2+ separate purchases.
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

**Beta-macOS build gotcha (ITMS-90111).** This Mac runs a beta macOS (e.g. `26A5368g`). Every `xcodebuild archive` embeds the host OS build in `BuildMachineOSBuild`, and App Store validation **rejects binaries built on beta macOS** — "Invalid Binary" / ITMS-90111 — regardless of Xcode/SDK (the installed Xcode 26.6 + iOS 26.5 SDK are fine; the `DTSDKBuild` seed suffix is NOT the cause). Established workaround: after `archive`, patch the app `Info.plist` in the `.xcarchive` to a **stable** macOS build before `-exportArchive` (export re-signs, so signatures stay valid):

```bash
/usr/libexec/PlistBuddy -c "Set :BuildMachineOSBuild 25F84" \
  "$ARCH/Products/Applications/VirtualSIM.app/Info.plist"
# then xcodebuild -exportArchive ...  (verify BuildMachineOSBuild in the exported IPA)
```

vSMS is a single-target app, so only one `Info.plist` needs patching. The real fixes are building on stable macOS or Xcode Cloud; patch is the interim path while on the beta.

**Submitting is fully headless via the App Store Connect API** (no Xcode Organizer) — see the `app-store-submission-asc` memory for the exact working pipeline: `xcodebuild archive` with `-allowProvisioningUpdates -authenticationKeyPath/-authenticationKeyID/-authenticationKeyIssuerID` (auto-provisions the Distribution cert; the Mac only has an *Apple Development* cert locally, which is fine) → patch `BuildMachineOSBuild` (above) → `xcodebuild -exportArchive` → `xcrun altool --upload-app` → ASC REST API (`POST /v1/appStoreVersions`, attach build, set `whatsNew`, `reviewSubmissions` submit). ASC API key lives at `~/.appstoreconnect/private_keys/AuthKey_R5ZVLBTUR6.p8` (key id `R5ZVLBTUR6`); app id `6774768570`. **The issuer id IS available: `4644ed13-4d98-489e-a94b-687f63946f46`** — an earlier note here claimed the machine had no issuer id and that API checks return `NO_ISSUER_ID`. That was wrong, and it cost real time: every "verify in ASC first" instruction was being skipped as impossible when the whole REST pipeline in fact works headlessly. The repo is at **`MARKETING_VERSION 1.7` / `CURRENT_PROJECT_VERSION 21`**. **Always verify live store state via the API before submitting** — the notes here drift within hours, and did twice on 2026-07-31 alone. Historical: 1.3 (build 12) released; 1.4 (build 13) submitted 2026-07-19; build 16 shipped as 1.5 in `a9b92c0` (which lowered the iOS floor to 18.0); build 17 submitted then cancelled 2026-07-25; build 18 submitted 2026-07-25 and released as **1.5**; build 19 submitted 2026-07-31 13:56Z and released as **1.6** the same day; build 20 submitted 2026-07-31 20:05Z as **1.7**, then **cancelled and replaced by build 21** (submitted 21:26Z) to strip the word "supplier" from shipped copy — cancelling an app-version submission is NOT the one-way door an IAP cancellation is: the version simply goes `DEVELOPER_REJECTED`, and re-attaching a build plus a fresh `reviewSubmission` recovers it in about a minute.

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
