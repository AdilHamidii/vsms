-- Device profiles + first-party behavioural events (owner request 2026-08-28).
--
-- Why: the 08-17 organic signup surge converts at 0.4% against the historical
-- ~5%, and the server is blind to (a) where these users are from and (b) what
-- they do between signup and leaving. Buyer geography exists only for buyers
-- (iap_receipts JWS storefront), i.e. exactly the population we are not
-- diagnosing.
--
-- device_profiles: one row per user, best-effort, two writers:
--   * register-push (server-side `Accept-Language` header — works for SHIPPED
--     builds today, but only users who allowed push notifications);
--   * record-events' optional `profile` field (2.6+ clients: StoreKit
--     storefront — the true payment geography — plus locale/timezone/version,
--     regardless of push permission).
-- Cascades from auth.users ON PURPOSE: this is user data, not a grant
-- tombstone — do not "fix" it to match signup_grants.
--
-- app_events: append-only, written ONLY by the record-events edge function on
-- the service role. No client policy — RLS is enabled with no policies, and a
-- direct PostgREST write must stay impossible (a client that can forge events
-- can poison every funnel read). 90-day retention via pg_cron (analytics, not
-- accounting: the money tables remain the durable record).

create table if not exists public.device_profiles (
  user_id         uuid primary key references auth.users(id) on delete cascade,
  storefront      text,          -- StoreKit Storefront.countryCode, e.g. 'USA' (3-letter)
  device_locale   text,          -- Locale.current identifier, e.g. 'fr_FR'
  timezone        text,          -- TimeZone.current.identifier
  app_version     text,
  accept_language text,          -- first tag of the Accept-Language header
  first_seen      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
alter table public.device_profiles enable row level security;
revoke all on public.device_profiles from anon, authenticated;

create table if not exists public.app_events (
  id         bigint generated always as identity primary key,
  user_id    uuid references auth.users(id) on delete cascade,
  session_id uuid,
  name       text not null check (name ~ '^[a-z0-9_.]{1,64}$'),
  props      jsonb not null default '{}'::jsonb,
  client_ts  timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists app_events_name_time_idx on public.app_events (name, created_at);
create index if not exists app_events_user_time_idx on public.app_events (user_id, created_at);
alter table public.app_events enable row level security;
revoke all on public.app_events from anon, authenticated;

-- Retention: analytics only, 90 days. Pure SQL on pg_cron, same reasoning as
-- purge-job-run-details.
select cron.schedule(
  'app-events-prune', '50 3 * * *',
  $$delete from public.app_events where created_at < now() - interval '90 days'$$);
