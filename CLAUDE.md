# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**vSMS** (App Store display name; formerly "vSIM OTP" — the Xcode target/scheme is still `VirtualSIM`) — iOS app selling two products, both paid with in-app **credits**: (1) **temporary phone numbers** for SMS verification codes, sourced from multiple providers with failover — **SMSPool (primary) → SMSPVA (fallback) → virtualsms (degraded)** via `_shared/providers.ts`; and (2) **eSIM data plans** (SMSPool) priced at 3× wholesale. iOS frontend in SwiftUI + Supabase backend (Postgres + Auth + Edge Functions + pg_cron).

Bundle ID: `com.anthersystems.VirtualSIM` · Supabase ref: `enugzltysdmjzavisloy` · Project root holds `Appidea.md` (original product brief).

## Common commands

```bash
# iOS build (verify compilation; no simulator launch)
xcodebuild -project VirtualSIM.xcodeproj -scheme VirtualSIM \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' build 2>&1 \
  | grep -E "(error:|warning: |BUILD)" | grep -v "Metadata extraction" | tail -10

# Push DB migrations to the linked Supabase project
supabase db push

# Deploy edge functions (each runs independently)
supabase functions deploy create-order check-order cancel-order register-push iap-verify delete-account \
  create-esim-order check-esim-usage redeem-referral winback
supabase functions deploy poll-active-orders sync-prices sync-smspool sync-esim-plans --no-verify-jwt

# Query the remote DB
supabase db query --linked "select count(*) from public.routes;"

# Manually trigger sync-prices (rare; pg_cron 'relay-sync-prices' runs it daily
# at 04:00 UTC — see migration 20260602200000_schedule_sync_prices.sql)
CRON=$(supabase db query --linked --output json \
  "select decrypted_secret from vault.decrypted_secrets where name='cron_secret';" \
  | grep -o '"decrypted_secret":"[^"]*"' | cut -d'"' -f4)
curl -X POST \
  -H "Authorization: Bearer sb_publishable_IfwQ5IduTyVNawl7jiFA7A_aqJ-qqbk" \
  -H "apikey: sb_publishable_IfwQ5IduTyVNawl7jiFA7A_aqJ-qqbk" \
  -H "x-cron-secret: $CRON" \
  https://enugzltysdmjzavisloy.supabase.co/functions/v1/sync-prices
```

There is no test suite. Verification is via `xcodebuild` for iOS, and for backend changes — re-deploy then hit the function with curl or trigger from the running app.

## Architecture

```
iOS (SwiftUI, iOS 26.2 target)            Supabase
─────────────────────────────             ──────────────────────────────────────────
AuthGate                                  Postgres tables: profiles, wallets,
  ↓ Sign in with Apple (native)             wallet_transactions, services, countries,
ContentView (4 tabs: home / esim /          routes, orders, esim_plans, esim_orders,
  orders / account + flow cover)             referrals, push_devices, iap_receipts
  ↓ APIClient (URLSession + apikey hdr)
  REST  → /rest/v1/...  (PostgREST)       Edge Functions (Deno):
  RPC   → /functions/v1/...                  create-order/check-order/cancel-order
                                             poll-active-orders (cron, every 1 min)
Providers — _shared/providers.ts routes      create-esim-order/check-esim-usage
  + fails over across:                       sync-prices / sync-smspool /
    SMSPool  (primary, api.smspool.net)        sync-esim-plans  (crons, daily)
    SMSPVA   (fallback, api.smspva.com)      redeem-referral / winback
    virtualsms (last; degraded)             register-push / iap-verify / delete-account
APNs ←── token-auth (.p8) HTTP/2
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
- `supabase/functions/_shared/` — `providers.ts` (unified router + SMSPool→SMSPVA→virtualsms failover; order/poll functions call this, NOT a specific provider), `smspool.ts` (numbers + eSIM), `smspva.ts` (v2 REST wrapper), `virtualsms.ts`, `apns.ts` (HTTP/2 + JWT), `cors.ts`, `iap.ts`, `supabaseAdmin.ts`
- `supabase/functions/<name>/index.ts` — one per endpoint, all Deno.serve
- `supabase/README.md` — deployment + secret setup walkthrough

### Pricing model

`AppState.cost(for:country:) -> Int?` uses an O(1) `routeIndex` dict (keyed `"serviceId|countryId"`) built in `loadCatalog`. Returns `nil` when the pair has no active route with a `retail_credits` price — meaning **unavailable to book**; UI shows "Unavailable" (see ServiceSheet/CountrySheet) and disables the Get-number button. It deliberately does **NOT** fall back to the seed `service.cost`, since undercharging vs the live provider price burns margin per order. **Do not** linear-scan `routes` (~17k rows after sync-prices) — that froze the country picker before the index was added.

`sync-prices` formula: `credits = max(1, ceil(price / 0.10))` — 1 credit per started 10¢ of wholesale (`CREDIT_DIVISOR = 0.10`, same in `sync-smspool`; tune it for global margin adjustment). It **EWMA-smooths** each route's cost (`smoothed_cost_cents`) so `retail_credits` stops flapping day-to-day. `sync-smspool` refreshes SMSPool routes + provider success rates (used for primary-provider routing). Order-time enforcement matches: `create-order` has `MIN_MARGIN = 3.0` / `NET_USD_PER_CREDIT = 0.30`, so the max we pay a provider is `credits × $0.10` — sent to SMSPool as `max_price` (its cheapest-pool quote does NOT bind the fill price) and enforced on the actual charged cost with cancel-and-fallback. Keep the divisor and the gate in lockstep: raising one without the other either blocks honest routes or leaks margin.

**eSIM** plans (`sync-esim-plans`) are priced **separately** at 3× wholesale — `ESIM_MARGIN = 3`, `CREDIT_VALUE_USD = 0.48`, `retail_credits = ceil(usd * 3 / 0.48)` — NOT via `CREDIT_DIVISOR`, so the two product lines never collide.

**Credit packs** (`Models/CreditPack.swift` + `Products.storekit` + `_shared/iap.ts` `PRODUCT_TO_CREDITS`): 5/$2.99, 12/$5.99 (MOST POPULAR), 30/$12.99, 60/$22.99, 150/$49.99 (BEST VALUE) — a strictly improving per-credit ladder (each pack beats stacking smaller ones). The per-credit label is computed **live** from the StoreKit price in `IAPStore.perCredit`, so it never drifts; production prices must be set to match in App Store Connect.

## Non-obvious gotchas (real bugs we've hit, do not re-introduce)

- **SMSPVA base URL is `https://api.smspva.com`**, NOT `smspva.com` (the docs spec lies — the marketing site 404s every `/activation/*` path).
- **PostgREST default `max_rows = 1000`** — bumped to 25000 via migration `20260601200000_bump_max_rows.sql`. The catalog fetch needs all ~18k routes.
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
- **Review prompt must stay incentive-free (App Store 5.6.4).** `OtpScreen` calls Apple's native `@Environment(\.requestReview)` (needs `import StoreKit`) on code delivery, gated by `AppState.shouldRequestReview(forOrderId:)` — fires only from the 2nd successful code onward, at most once per app version, de-duped per order. **Never** tie credits/rewards to leaving a review, and **never** build a custom review UI that deep-links to the App Store page — both are rejectable. A no-strings welcome/bonus credit is fine as long as it isn't conditioned on a review.

## Error UX rule

Never display raw API errors. AppState's catch blocks call `APIError.userMessage`, which maps known business-logic codes (`insufficient_credits`, `no_numbers_available`, `route_unavailable`, `smspva_error`, etc.) to plain English. `errorDescription` stays for the Xcode console only.

## When iOS data looks wrong, check in this order

1. Force-quit the app — `.task` only runs on cold launch (`scenePhase=.active` now also refreshes catalog, but cold start is the cleanest test).
2. Xcode console for catalog decode errors (column name mismatches show as `keyNotFound`).
3. `curl` PostgREST directly with the publishable key — if curl returns the data, iOS decoding is the issue.
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
