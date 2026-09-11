-- Every minute, not every two (owner, 2026-09-11: "1 minute max").
--
-- Supersedes `rc_sync_every_two_minutes` from minutes earlier. The ceiling the
-- owner cares about is how long a purchase can be invisible on the phone app,
-- and two minutes was still a compromise chosen for tidiness rather than for
-- any measured cost.
--
-- There is precedent and it is the busiest job in the product:
-- `relay-poll-active-orders` has run `* * * * *` since launch. An idle rc-sync
-- is one indexed query per family returning in ~266ms, and it is a no-op by
-- construction - a row is selected only while `rc_synced_at` is null (packs) or
-- `rc_synced_txn` lags `last_transaction_id` (subscriptions) - so overlapping
-- runs re-post nothing and `purge-job-run-details` prunes the extra rows.
--
-- Still NOT a trigger on `iap_receipts`. Instant would mean a statement that
-- can raise inside the transaction that records a purchase, and a receipt
-- failing to commit because a dashboard integration hiccuped is a real money
-- bug traded for a cosmetic win. One minute is close enough to instant.
select cron.unschedule('relay-rc-sync');

select cron.schedule(
  'relay-rc-sync',
  '* * * * *',
  $$
  select net.http_post(
    url := 'https://enugzltysdmjzavisloy.supabase.co/functions/v1/rc-sync',
    headers := jsonb_build_object('Content-Type','application/json','x-cron-secret', private_cron_secret()),
    body := '{}'::jsonb, timeout_milliseconds := 150000);
  $$
);
