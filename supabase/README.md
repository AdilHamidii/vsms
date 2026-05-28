# Supabase backend — VirtualSIM / Relay

This directory holds the Supabase schema, edge functions, and CLI config for the
Relay backend. Build phases align with the iOS phases:

| Phase | Status | Adds                                                                 |
|-------|--------|----------------------------------------------------------------------|
| A     | ✅      | profiles, wallets, wallet_transactions, sign-up bonus trigger        |
| B     | ⏳     | services, countries, routes, /catalog edge function                  |
| C     | ⏳     | orders, SMSPVA proxy module, create/check/cancel-order functions     |
| D     | ⏳     | push_devices, register-push, pg_cron poll-active-orders, APNs        |
| E     | ⏳     | iap_receipts, /iap-verify, App Store Server API integration          |

## First-time setup

Install the Supabase CLI: `brew install supabase/tap/supabase`

```bash
# 1. Create a project at https://supabase.com/dashboard, then link this folder
supabase login
supabase link --project-ref <YOUR_PROJECT_REF>

# 2. Push the schema
supabase db push

# 3. Wire Sign in with Apple (no JWT secret needed — native iOS flow only).
#    a) developer.apple.com → Identifiers → com.anthersystems.VirtualSIM →
#       enable the "Sign In with Apple" capability → Save.
#    b) Supabase dashboard → Authentication → Providers → Apple:
#       - Toggle Enable
#       - Client IDs (For iOS): com.anthersystems.VirtualSIM
#       - Leave Services ID + Secret blank (only needed for web OAuth)
#       - Skip nonce checks: off

# 4. Add the SMSPVA key as a function secret (used from Phase C onward)
supabase secrets set SMSPVA_API_KEY=<your-smspva-key>

# 5. Grab the project URL and publishable (anon) key from the dashboard,
#    paste them into VirtualSIM/Networking/Secrets.swift (gitignored).
#    Template:
#
#    import Foundation
#
#    enum Secrets {
#        static let supabaseURL: URL = URL(string: "https://<ref>.supabase.co")!
#        static let supabaseAnonKey: String = "<publishable_key>"
#    }
```

## Local development

```bash
supabase start          # spins up local Postgres + Auth + Storage + edge runtime
supabase db reset       # re-apply migrations from scratch
supabase functions serve <name>  # hot-reload an edge function
```

## Phase A schema notes

- Every new `auth.users` row triggers `handle_new_user()` which creates a profile,
  a wallet seeded with 5 credits, and logs a `signup_bonus` transaction.
- All wallet movement goes through `wallet_spend()` / `wallet_credit()` SECURITY
  DEFINER functions. Direct UPDATEs on `public.wallets` are blocked by RLS —
  only the trigger and these RPCs can write.
- iOS hits Postgres directly via Supabase's auto-generated REST endpoints. The
  `select` policies let users read only their own rows; writes happen exclusively
  through edge functions or RPCs.
