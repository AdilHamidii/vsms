-- Operator alerting to Telegram: an instant ping on signup / credit purchase /
-- eSIM purchase, plus a 6-hourly digest. Before this there was no way to know
-- any of it without running SQL by hand.

-- Exactly-once claim table. Both the instant path (iap-verify,
-- create-esim-order) and the per-minute sweep insert-on-conflict-do-nothing and
-- only send if they won the row. Same atomic-claim idiom poll-active-orders
-- already uses for push, and it survives a race between the two paths.
create table if not exists public.telegram_events (
  kind    text not null check (kind in ('signup','purchase','esim')),
  ref     text not null,
  sent_at timestamptz not null default now(),
  primary key (kind, ref)
);
alter table public.telegram_events enable row level security;
-- No policies: service-role (edge functions) only. Nothing user-facing.
create index if not exists telegram_events_sent_idx on public.telegram_events (sent_at);

-- One definition of the business numbers, shared by the 6h digest and the
-- /stats command so the two can never drift. Returns a single JSONB blob to
-- keep it to one round trip.
--
-- "failed" counts expired + canceled, matching how the observed-success work
-- already defines a non-delivery. The developer's own test account is excluded
-- throughout — it holds a 99,999-credit grant and dev orders.
create or replace function public.ops_snapshot(p_window interval default interval '6 hours')
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with dev as (select '825688de-6117-4251-9f90-93b83b41b572'::uuid as id),
  since as (select now() - p_window as t),
  sign as (
    select count(*)::int as n from auth.users
    where created_at >= (select t from since) and id <> (select id from dev)
  ),
  buys as (
    select count(*)::int as n, coalesce(sum(granted_credits),0)::int as credits
    from public.iap_receipts
    where created_at >= (select t from since) and user_id <> (select id from dev)
  ),
  ord as (
    select count(*)::int as placed,
           count(*) filter (where status = 'received')::int as received,
           count(*) filter (where status in ('expired','canceled'))::int as failed
    from public.orders
    where created_at >= (select t from since) and user_id <> (select id from dev)
  ),
  esim as (
    select count(*)::int as n, coalesce(sum(cost_credits),0)::int as credits
    from public.esim_orders
    where created_at >= (select t from since) and user_id <> (select id from dev)
  ),
  bal as (
    select (value->>'balance_usd')::numeric as usd
    from public.app_config where key = 'smspool_health'
  )
  select jsonb_build_object(
    'window_hours', round(extract(epoch from p_window) / 3600.0, 1),
    'signups',      (select n from sign),
    'purchases',    jsonb_build_object(
                      'count',   (select n from buys),
                      'credits', (select credits from buys)),
    'orders',       jsonb_build_object(
                      'placed',   (select placed from ord),
                      'received', (select received from ord),
                      'failed',   (select failed from ord),
                      'pct',      case when (select placed from ord) > 0
                                    then round(100.0 * (select received from ord)
                                                     / (select placed from ord))
                                    else null end),
    'esims',        jsonb_build_object(
                      'count',   (select n from esim),
                      'credits', (select credits from esim)),
    'smspool_usd',  (select usd from bal)
  );
$$;

revoke execute on function public.ops_snapshot(interval) from public, anon, authenticated;

-- Cursor for the digest cadence.
insert into public.app_config (key, value)
values ('telegram_bot', jsonb_build_object('last_digest_at', (now() - interval '6 hours')))
on conflict (key) do nothing;

-- Mark everything that already happened as "alerted", so the first sweep after
-- deploy is silent. The sweep only looks back 30 minutes so the blast radius
-- was 1 message, not 142 — but this makes it exactly zero, and stops a future
-- widening of that window from replaying months of history into the chat.
insert into public.telegram_events (kind, ref)
select 'signup', user_id::text from public.profiles
union all
select 'purchase', id::text from public.iap_receipts
union all
select 'esim', id::text from public.esim_orders
on conflict do nothing;

-- Per-minute sweep + 6-hourly digest, same relay shape as every other job.
select cron.schedule(
    'relay-telegram-notify',
    '* * * * *',
    $cmd$
    select net.http_post(
        url := 'https://enugzltysdmjzavisloy.supabase.co/functions/v1/telegram-notify',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'x-cron-secret', private_cron_secret()
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 30000
    );
    $cmd$
);

select cron.schedule(
    'telegram-events-prune',
    '30 4 * * *',
    $$ delete from public.telegram_events where sent_at < now() - interval '30 days' $$
);
