-- Schedule `sync-line-countries` (Phase 3 of the international country catalog).
--
-- DAILY, not hourly: the subject is regulatory paperwork and per-country
-- coverage, both of which move on a timescale of weeks. The requirements sweep
-- is chunked (30 reads/run, ~450 ms apart) precisely because it must not be
-- fast — the 2026-08-26 probe took four 429s firing them back to back, and a
-- 429 read as "no requirements" would sell a documented country.
--
-- 03:40 UTC keeps it clear of `relay-sync-esim-plans` (02:00) and the SMSPVA
-- maintenance window (04:29–04:43).
--
-- Cron-gated: the relay sends only `x-cron-secret`, no Authorization header,
-- so the function MUST be deployed `--no-verify-jwt` (and carries
-- `verify_jwt = false` in supabase/config.toml).

select cron.schedule(
  'relay-sync-line-countries',
  '40 3 * * *',
  $$
  select net.http_post(
    url := 'https://enugzltysdmjzavisloy.supabase.co/functions/v1/sync-line-countries',
    headers := jsonb_build_object('Content-Type','application/json','x-cron-secret', private_cron_secret()),
    body := '{}'::jsonb, timeout_milliseconds := 150000);
  $$
);
