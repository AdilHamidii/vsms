-- The two cron relays for the rented-line janitors.
--
-- Deliberately a SEPARATE migration from 20260806100000, and applied only
-- AFTER both functions were deployed. Scheduling a relay at a URL that 404s
-- writes a non-2xx row into `net._http_response` every run, and `run_watchdog`
-- pages on ANY non-2xx relay inside 25 minutes — so the wrong order turns a
-- correct fix into a permanent false alarm on the only monitoring channel we
-- have. Alert fatigue there is how a real outage later gets missed.
--
-- ⚠️ Both go through `private_cron_secret()` so the secret never leaves the
-- database, and both functions MUST be deployed `--no-verify-jwt`: pg_net
-- sends only `x-cron-secret` and no Authorization header. `config.toml` now
-- records that for both.

-- release-lines: drains `releasing` rows at the provider. `reclaim_lapsed_
-- lines()` (pure SQL, */15) makes the CLAIM; this makes the DELETE. Offset
-- from :00 so it runs a couple of minutes AFTER the sweep that feeds it rather
-- than a couple of minutes before.
select cron.unschedule('relay-release-lines')
 where exists (select 1 from cron.job where jobname = 'relay-release-lines');
select cron.schedule('relay-release-lines', '3,18,33,48 * * * *', $cron$
  select net.http_post(
    url := 'https://enugzltysdmjzavisloy.supabase.co/functions/v1/release-lines',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'x-cron-secret', private_cron_secret()),
    body := '{}'::jsonb, timeout_milliseconds := 120000);
$cron$);

-- sync-telnyx-cdr: settles call minutes against the billing truth. Every 10
-- minutes, comfortably inside the 180-minute lookback so a missed run costs
-- nothing, and well ahead of `settle_stale_calls`' six-hour fallback — which
-- exists precisely so a call is never left reserved forever, and must stay the
-- backstop rather than the normal path.
select cron.unschedule('relay-sync-telnyx-cdr')
 where exists (select 1 from cron.job where jobname = 'relay-sync-telnyx-cdr');
select cron.schedule('relay-sync-telnyx-cdr', '*/10 * * * *', $cron$
  select net.http_post(
    url := 'https://enugzltysdmjzavisloy.supabase.co/functions/v1/sync-telnyx-cdr',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'x-cron-secret', private_cron_secret()),
    body := '{}'::jsonb, timeout_milliseconds := 120000);
$cron$);
