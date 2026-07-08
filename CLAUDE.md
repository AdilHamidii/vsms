# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**vSMS** (App Store display name; formerly "vSIM OTP" — the Xcode target/scheme is still `VirtualSIM`) — iOS app that rents temporary phone numbers from SMSPVA and delivers SMS verification codes. iOS frontend in SwiftUI + Supabase backend (Postgres + Auth + Edge Functions + pg_cron).

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
supabase functions deploy create-order check-order cancel-order register-push iap-verify delete-account
supabase functions deploy poll-active-orders sync-prices --no-verify-jwt

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
ContentView (tabs + flow cover)             routes, orders, push_devices, iap_receipts
  ↓ APIClient (URLSession + apikey hdr)
  REST  → /rest/v1/...  (PostgREST)       Edge Functions (Deno):
  RPC   → /functions/v1/...                  create-order   — wallet_spend → SMSPVA
                                             check-order    — poll one order
SMSPVA                                       cancel-order   — refund + SMSPVA denial
  ←── api.smspva.com/activation/...          poll-active-orders (cron, every 1 min)
       (apikey HEADER, not query string)     sync-prices    — refresh route prices
                                                            (cron 'relay-sync-prices',
                                                             daily 04:00 UTC)
                                             register-push  — store APNs token
APNs                                         iap-verify     — StoreKit 2 JWS verify
  ←── token-auth (.p8) HTTP/2               delete-account — auth.admin.deleteUser
```

### iOS source layout

```
VirtualSIM/
  VirtualSIMApp.swift            App entry; resizes URLCache (32MB mem / 64MB disk
                                 for brand logos + flag PNGs); installs AppDelegate
  ContentView.swift              Tab routing + fullScreenCover for Checkout/Waiting/
                                 OTP flow; EnvBundle ViewModifier re-injects every
                                 @Observable env object into sheet/cover content
                                 (covers don't inherit reliably)
  Auth/                          AuthGate (3-state: bootstrap/signedOut/signedIn),
                                 SignInScreen, Session (@Observable, Keychain-backed)
  Networking/                    APIClient + per-resource APIs (CatalogAPI, OrdersAPI,
                                 WalletAPI, ProfileAPI, IAPAPI, AccountAPI, PushAPI,
                                 AuthAPI). Secrets.swift is gitignored
  State/AppState.swift           Single @Observable source of truth — services,
                                 countries, routes, orders, prefs (UserDefaults-
                                 backed via didSet), checkout/flow machine
  Models/                        Plain Codable structs mirroring DB column names via
                                 .convertFromSnakeCase
  Screens/                       Home, Checkout, Waiting (+ WaitingAnimations),
                                 OTP (fires native review prompt on code
                                 delivery), Orders, Account
  Sheets/                        ServiceSheet (search + categories + per-route
                                 price), CountrySheet (sort + per-route price),
                                 CreditsSheet (StoreKit 2)
  Components/                    Theme primitives + ServiceLogo (DuckDuckGo ip3 icon
                                 with Google FaviconV2 fallback), FlagImage (flagcdn.com)
  Push/, IAP/, Onboarding/, DesignSystem/  Self-explanatory
  Localizable.xcstrings          String Catalog: en source + de/es/fr/it/ja/pt-BR
  Products.storekit              Local IAP test config (enable via scheme)
  VirtualSIM.entitlements        Sign in with Apple + aps-environment
```

### Backend layout

- `supabase/migrations/` — chronological SQL, each phase ships its own file
- `supabase/functions/_shared/` — `smspva.ts` (v2 REST wrapper), `apns.ts` (HTTP/2 + JWT), `cors.ts`, `iap.ts`, `supabaseAdmin.ts`
- `supabase/functions/<name>/index.ts` — one per endpoint, all Deno.serve
- `supabase/README.md` — deployment + secret setup walkthrough

### Pricing model

`AppState.cost(for:country:) -> Int?` uses an O(1) `routeIndex` dict (keyed `"serviceId|countryId"`) built in `loadCatalog`. Returns `nil` when the pair has no active route with a `retail_credits` price — meaning **unavailable to book**; UI shows "Unavailable" (see ServiceSheet/CountrySheet) and disables the Get-number button. It deliberately does **NOT** fall back to the seed `service.cost`, since undercharging vs the live SMSPVA price burns margin per order. **Do not** linear-scan `routes` (~17k rows after sync-prices) — that froze the country picker before the index was added.

`sync-prices` formula: `credits = max(1, ceil(price / 0.15))`. Tune `CREDIT_DIVISOR` in `supabase/functions/sync-prices/index.ts` for global margin adjustment. Currently anchors: 15 EUR → 100 cr, ≤ 5¢ → 1 cr.

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

`docs/submission-checklist.md` is the source of truth for App Store submission steps. `docs/app-store-listing.md` has all metadata copy + nutrition labels pre-filled. Legal docs (`privacy-policy.md`, `terms.md`, `refund-policy.md`, `help.md`) are written to be pasted into Notion as public pages — URLs then go into `VirtualSIM/LegalLinks.swift`.
