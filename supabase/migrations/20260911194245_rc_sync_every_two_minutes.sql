-- Tighten the RevenueCat mirror from every 10 minutes to every 2.
--
-- SUPERSEDED the same minute by `rc_sync_every_minute` (owner: "1 minute max").
-- Kept as a file because it is recorded in `schema_migrations` and a fresh
-- deploy has to replay it to reach the same state; deleting it is how the
-- migration drift this repo already suffers from gets worse.
--
-- The original :6,:16,... schedule was chosen on "~2 purchases a day, so
-- latency is irrelevant". That reasoned about the PURCHASE rate and ignored the
-- READ rate: the owner opens RevenueCat's phone app to look, and a purchase
-- that lands 2 minutes after a tick then sits invisible for 8 more. Measured
-- 2026-09-11: a purchase at 19:37:55 against a sweep at 19:36:00. The number was
-- never wrong, it was just late, which on a glance surface is the same
-- complaint.
--
-- Affordable because an idle sweep is one indexed query per family and returns
-- in ~266ms - it is a no-op by construction, since a row is selected only while
-- `rc_synced_at` is null (packs) or `rc_synced_txn` lags `last_transaction_id`
-- (subscriptions). Overlapping runs are safe for the same reason, and
-- `purge-job-run-details` already prunes the extra cron rows.
--
-- Not done instead, deliberately: a trigger on `iap_receipts` posting to the
-- sweep on insert. It would be near-instant, but it puts a statement that can
-- raise inside the transaction that records a purchase - and a receipt row
-- failing to commit because a dashboard integration hiccuped is a real money
-- bug traded for a cosmetic win. The sweep stays the only writer.
select cron.unschedule('relay-rc-sync');

select cron.schedule(
  'relay-rc-sync',
  '*/2 * * * *',
  $$
  select net.http_post(
    url := 'https://enugzltysdmjzavisloy.supabase.co/functions/v1/rc-sync',
    headers := jsonb_build_object('Content-Type','application/json','x-cron-secret', private_cron_secret()),
    body := '{}'::jsonb, timeout_milliseconds := 150000);
  $$
);
