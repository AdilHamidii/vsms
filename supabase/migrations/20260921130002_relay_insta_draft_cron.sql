-- Daily at 08:00 UTC (10:00 Paris in summer, 09:00 in winter): one Instagram
-- draft to the owner's Telegram for approval. Same relay shape as
-- relay-reddit-scan — pg_net + x-cron-secret via private_cron_secret(), so the
-- secret never leaves the database. insta-draft must be deployed
-- --no-verify-jwt: this relay sends no Authorization header.
--
-- Like every pg_cron job it fires at second :00, inside the PostgREST herd
-- (see CLAUDE.md, "Non-obvious gotchas"); insta-draft wraps its first reads in
-- readWithRetry for that reason.
select cron.schedule(
  'relay-insta-draft',
  '0 8 * * *',
  $$
  select net.http_post(
    url := 'https://enugzltysdmjzavisloy.supabase.co/functions/v1/insta-draft',
    headers := jsonb_build_object('Content-Type','application/json','x-cron-secret', private_cron_secret()),
    body := '{}'::jsonb, timeout_milliseconds := 150000);
  $$
);
