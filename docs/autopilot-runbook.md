# vSMS autopilot runbook

Written 2026-07-22 after a five-dimension autonomy audit. Goal: the app keeps
generating revenue with **no intervention beyond topping up the two provider
balances** — everything else either self-heals or pages the Telegram bot.

## The only recurring human actions

| Action | Cadence | Trigger |
|---|---|---|
| Top up **SMSPVA** (funds ALL SMS) | when paged | Telegram pages at $20 / $10 / $5 / $1 crossings; balance in every 6h digest and `/balance` |
| Top up **SMSPool** (funds eSIMs only) | when paged | same ladder. A low reading here is NOT an SMS outage |
| **Apple Developer Program** renewal ($99/yr) | yearly | Apple emails; set a calendar reminder. A lapse REMOVES the app from the App Store and kills APNs |
| Apple **Paid Apps agreement / tax / banking** | rare | Apple emails warnings; if IAP revenue stops with no other symptom, check App Store Connect → Business first |
| **Supabase billing** | monthly card charge | see "Upgrade to Pro" below — currently on FREE plan |

One-time items still open:
- **Submit the 60-credit pack**: App Store Connect → Monetization → In-App
  Purchases → `credits.60` → Submit for Review (it is `READY_TO_SUBMIT`; the
  150cr pack is already `WAITING_FOR_REVIEW`). Until approved the price
  ladder tops out at $12.99.
- **Upgrade Supabase to Pro (~$25/mo)**: the project is on the FREE plan —
  **zero backups**. The wallet ledger (who owns how many credits) is
  unrecoverable after corruption or a bad migration. Pro adds daily backups
  and removes the 500 MB cliff worry. This is the single cheapest insurance
  available for this business.

## What pages you (Telegram, instant)

| Message | Meaning | What to do |
|---|---|---|
| 🚨 **Watchdog: N jobs unhealthy** | a scheduled backend job stopped producing evidence of life (list included, with per-check detail) | Dashboard → Edge Functions → that function → Logs. Most common causes: a deploy flipped `verify_jwt` back on for a cron function (redeploy with `--no-verify-jwt`), or `CRON_SECRET` was rotated in only one of its TWO stores (edge secrets AND vault `cron_secret` — they must match) |
| ✅ **Watchdog: all clear** | the failing jobs recovered | nothing |
| ⚠️/🚨 **balance low/EMPTY** | provider balance crossed $20/$10/$5/$1 | top up that provider |
| 🚨 **N consecutive SMS order failures** | users are being charged+refunded with nothing delivered | check SMSPVA status/balance; the message names the failing route and error |
| 🚨 **provider account fault (AUTH/BALANCE)** | SMSPVA/SMSPool key revoked or wallet empty at the provider | log into the provider, fix the account |
| 🚨 **IAP verification rejected / credit FAILED / unknown product** | a real payment did not turn into credits | message says whether it self-heals (StoreKit retries) or needs a manual credit; `unknown product` means a pack exists in ASC that `PRODUCT_TO_CREDITS` doesn't know |

## The one remaining silent failure

Every page above travels through the Telegram bot. If the bot token dies or
`telegram-notify` itself stops, pages stop — **and so does the 6-hourly
digest**. That silence is the signal:

> **No digest for more than ~7 hours ⇒ the alert layer itself is down.**
> Open the Supabase dashboard and check Edge Functions → telegram-notify logs.

Optional hardening (5 min, free): create a check at healthchecks.io and add a
pg_cron ping — then a dead Postgres/pg_cron also alerts, via email, with no
dependency on Telegram or the edge layer:

```sql
select cron.schedule('deadman-ping', '*/10 * * * *',
  $$select net.http_get('https://hc-ping.com/YOUR-UUID-HERE')$$);
```

## How the watchdog works

`run_watchdog()` — plain SQL, pg_cron, every 10 min, **no edge function, no
CRON_SECRET, no HTTP** — so it keeps working even when the entire edge/secret
layer is broken. It checks freshness of: the minutely balance heartbeat
(poll-active-orders), newest route price (sync-prices, 3h), eSIM catalog
(26h), last digest (7h), operator-pin cursor (30h), conversions cursor (24h),
winback heartbeat (26h) — plus any non-2xx relay response in pg_net's history
(catches 401s from a `verify_jwt`/CRON_SECRET regression, and the syncs'
fail-loud 502s). Verdict lands in `app_config.'watchdog'`;
`telegram-notify` (minutely) turns it into pages with a 6h re-alert cadence.
`/balance` in Telegram also shows the current watchdog verdict.

## Residual risks accepted (know they exist, no action needed)

- **Single SMS provider.** SMSPVA account ban or API break stops all SMS
  revenue until fixed. Detection is now instant (fault alert + watchdog +
  failure streak); recovery is manual by design — see the provider-switch
  checklist in CLAUDE.md before re-homing routes.
- **No forced-upgrade mechanism** in shipped clients. Never make a breaking
  backend change for old app versions; the maintenance flag is the only kill
  switch. (Candidate for build 1.6: a `min_build` config check.)
- **This Mac cannot archive iOS builds** (SDK 26.5 vs installed runtime 27.0 +
  beta-macOS ITMS-90111). Backend fixes deploy in minutes, but an emergency
  *client* fix requires the documented archive workaround plus App Review
  (~24h). Fix permanently by installing an Xcode whose SDK matches iOS 26.x
  runtime availability, or building on stable macOS / Xcode Cloud.
- **Store listing dependencies**: the Notion-hosted legal URLs must stay up
  (matters at review time), and the App Store version 1.5 auto-releases on
  approval (`AFTER_APPROVAL`).

## Verified working as of 2026-07-22

- Ledger reconciles (every wallet balance equals the sum of its transactions);
  refund uniqueness is a DB invariant; IAP chain pinned to Apple Root CA-G3.
- Watchdog loop proven end-to-end with an injected failure → real Telegram
  page → auto all-clear.
- Migration bookkeeping reconciled: `supabase db push` is safe again.
- cron.job_run_details capped at 7 days (was 63% of the whole database).
