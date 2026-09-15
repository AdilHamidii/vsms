-- Hourly at :26. Offset off the top of the hour on purpose — :00 is where the
-- minutely relays herd and PostgREST answers ~1% of that burst with a 504, and
-- :07/:17/:37/:40 are already taken by the pricing and catalog syncs.
--
-- Hourly is 168× finer than the search window reddit-scan reads (sort=new,
-- t=week), so a missed run cannot lose a thread — it is picked up next hour.
select cron.schedule(
  'relay-reddit-scan',
  '26 * * * *',
  $$
  select net.http_post(
    url := 'https://enugzltysdmjzavisloy.supabase.co/functions/v1/reddit-scan',
    headers := jsonb_build_object('Content-Type','application/json','x-cron-secret', private_cron_secret()),
    body := '{}'::jsonb, timeout_milliseconds := 150000);
  $$
);
