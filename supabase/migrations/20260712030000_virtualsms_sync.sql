-- Weekly virtualsms price sync + app maintenance flag.

-- Small key/value config the app + edge functions share. Holds the maintenance
-- banner state (app polls it) and the resumable sync cursor.
create table if not exists public.app_config (
  key        text primary key,
  value      jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.app_config enable row level security;
-- Anyone signed in can read (needed for the maintenance banner); writes are
-- service-role only (edge functions), which bypasses RLS.
drop policy if exists app_config_read on public.app_config;
create policy app_config_read on public.app_config for select to authenticated using (true);

insert into public.app_config(key, value) values
  ('maintenance',    '{"active": false}'::jsonb),
  ('virtualsms_sync','{"index": 0, "running": false}'::jsonb)
on conflict (key) do nothing;

-- Weekly sync: Sundays, fired every minute during the 04:00 UTC hour. The
-- resumable chunked function pages through the virtualsms matrix (~50 combos
-- per run, paced under the 60/min rate limit), flips the maintenance banner on
-- while running, and no-ops once it has completed for the day.
select cron.schedule(
  'relay-virtualsms-sync',
  '* 4 * * 0',
  $cmd$
  select net.http_post(
    url := 'https://enugzltysdmjzavisloy.supabase.co/functions/v1/sync-virtualsms',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', private_cron_secret()
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 120000
  );
  $cmd$
);
