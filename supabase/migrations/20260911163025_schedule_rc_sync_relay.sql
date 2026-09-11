-- Keep RevenueCat current without anyone opening a dashboard.
--
-- Every 10 minutes, offset off the :00 so it does not land with `watchdog`
-- (*/10) or `relay-sync-5sim` (:07). The steady state is ~2 purchases a day, so
-- this is not about throughput - it is the upper bound on how stale the owner's
-- phone app can be, and on how late RevenueCat's own purchase push arrives.
--
-- The sweep is idempotent by construction: a row is selected only while
-- `rc_synced_at` is null (packs) or `rc_synced_txn` lags `last_transaction_id`
-- (subscriptions), so an overlapping run re-posts nothing. RevenueCat
-- deduplicates on its side as well.
select cron.schedule(
  'relay-rc-sync',
  '6,16,26,36,46,56 * * * *',
  $$
  select net.http_post(
    url := 'https://enugzltysdmjzavisloy.supabase.co/functions/v1/rc-sync',
    headers := jsonb_build_object('Content-Type','application/json','x-cron-secret', private_cron_secret()),
    body := '{}'::jsonb, timeout_milliseconds := 150000);
  $$
);
