# Relay backend — Supabase

This directory holds the SQL migrations and Deno edge functions backing the
Relay iOS app. The corresponding iOS source lives at `../VirtualSIM/`.

## Architecture

```
                                  ┌─────────────────────┐
                ┌──── REST ──────▶│ catalog / wallet /  │
                │                 │ profiles / orders   │
  ┌──────────┐ │  Apple ID JWT   │ (Postgres + RLS)    │
  │ iOS app  │─┼────────────────▶│                     │
  │ (SwiftUI)│ │                 └─────────────────────┘
  └──────────┘ │                 ┌─────────────────────┐
       ▲       └── edge funcs ──▶│ create-order        │
       │                         │ check-order          │──▶ SMSPVA
       │                         │ cancel-order         │     priemnik.php
       │                         │ register-push        │
       │                         │ iap-verify           │
       │                         │ poll-active-orders   │──▶ APNs
       │                         └─────────────────────┘
       │                                  ▲
       │      every 60s (pg_cron)         │
       └──────────────────────────────────┘
       APNs push when OTP arrives
```

## Phases shipped

| Phase | Adds                                                                 |
|-------|----------------------------------------------------------------------|
| A     | profiles, wallets, wallet_transactions, signup-bonus trigger         |
| B     | services, countries, routes (catalog seeded)                         |
| C     | orders, SMSPVA proxy module, create/check/cancel-order               |
| D     | push_devices, register-push, pg_cron poll-active-orders, APNs sender |
| E     | iap_receipts, iap-verify (StoreKit 2 JWS verification)               |
| F     | iOS polish: error banner, push deep-link, foreground refresh         |

## First-time deployment

Install the Supabase CLI: `brew install supabase/tap/supabase`

```bash
# 1. Create a project at https://supabase.com/dashboard, then link.
supabase login
supabase link --project-ref <YOUR_PROJECT_REF>

# 2. Push every migration.
supabase db push

# 3. Wire Sign in with Apple (no JWT secret needed — native iOS flow only).
#    a) developer.apple.com → Identifiers → com.anthersystems.VirtualSIM →
#       enable the "Sign In with Apple" capability → Save.
#    b) Supabase dashboard → Authentication → Providers → Apple:
#       - Toggle Enable
#       - Client IDs (For iOS): com.anthersystems.VirtualSIM
#       - Leave Services ID + Secret blank (only needed for web OAuth)
#       - Skip nonce checks: off

# 4. Set the function secrets.
supabase secrets set SMSPVA_API_KEY=<your-smspva-key>

# APNs (.p8 from developer.apple.com → Keys → Sign in with Apple key)
supabase secrets set APNS_KEY_ID=<10-char-key-id>
supabase secrets set APNS_TEAM_ID=<10-char-team-id>
supabase secrets set APNS_KEY_P8="$(cat AuthKey_XXXXXXXXXX.p8)"
supabase secrets set APNS_BUNDLE_ID=com.anthersystems.VirtualSIM
supabase secrets set APNS_ENV=sandbox    # flip to "production" for App Store builds

# 5. Deploy every edge function.
supabase functions deploy create-order check-order cancel-order register-push iap-verify
supabase functions deploy poll-active-orders --no-verify-jwt

# 6. iOS: paste the Supabase URL and publishable (anon) key into
#    VirtualSIM/Networking/Secrets.swift. Template lives below.
```

`Secrets.swift` template (gitignored):

```swift
import Foundation
enum Secrets {
    static let supabaseURL: URL = URL(string: "https://<ref>.supabase.co")!
    static let supabaseAnonKey: String = "<publishable_key>"
}
```

## App Store Connect setup (Phase E — IAP)

Create three **Consumable** in-app purchase products with these exact IDs:

| Product ID                                       | Price  | Credits |
|--------------------------------------------------|--------|---------|
| `com.anthersystems.VirtualSIM.credits.5`         | $2.99  | 5       |
| `com.anthersystems.VirtualSIM.credits.12`        | $5.99  | 12      |
| `com.anthersystems.VirtualSIM.credits.30`        | $12.99 | 30      |

For local sandbox testing without going through App Store Connect:
File → New → File → StoreKit Configuration File. Add the three products
with the same IDs. Then in your scheme: Edit Scheme → Run → Options →
StoreKit Configuration → select the file.

## Important schema details

- `handle_new_user` trigger seeds every new auth.users row with a profile,
  a wallet, and 5 signup-bonus credits.
- All wallet movement goes through `wallet_spend()` / `wallet_credit()`
  SECURITY DEFINER RPCs. Direct UPDATEs are blocked by RLS.
- The cron job's shared secret lives in `vault.secrets` under
  `cron_secret` — auto-generated on first migration, reused thereafter.
  The `poll-active-orders` function reads it back from vault to validate
  incoming calls.
- The SMSPVA service codes in the catalog (`opt29`, `opt0`, etc.) are
  best-effort guesses. **Verify against your SMSPVA dashboard** before
  going live with real users — wrong codes mean `create-order` will get
  `response: 2` (no numbers) and refund the user every time.

## Local development

```bash
supabase start              # spins up local Postgres + Auth + Studio + edge runtime
supabase db reset           # re-apply migrations from scratch
supabase functions serve    # hot-reload all edge functions
```

To point the iOS app at the local stack: edit `Secrets.swift` to use the
local URLs printed by `supabase start`.

## Cron job admin

```sql
-- Inspect the cron schedule
select * from cron.job where jobname = 'relay-poll-active-orders';

-- See recent runs
select * from cron.job_run_details
where jobid = (select jobid from cron.job where jobname = 'relay-poll-active-orders')
order by start_time desc limit 20;

-- Disable temporarily
select cron.alter_job(
  job_id := (select jobid from cron.job where jobname = 'relay-poll-active-orders'),
  active := false
);
```
