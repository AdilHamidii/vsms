-- Winback: a one-time push nudge to users who signed up but never placed an
-- order, so the untouched free signup credit actually gets used. Reuses
-- push_devices + the cron_secret / private_cron_secret() infra from the
-- existing relays (poll-active-orders, sync-prices).

alter table public.profiles
  add column if not exists winback_sent_at timestamptz;

-- Eligible = signed up >= 3 days ago, still holds credit, never ordered, has a
-- registered push device, and not yet winback'd. security definer so the edge
-- function can call it via the service role; capped by p_limit.
create or replace function public.winback_candidates(p_limit int default 200)
returns table (user_id uuid)
language sql
security definer
set search_path = public
as $$
  select p.user_id
  from public.profiles p
  join public.wallets w on w.user_id = p.user_id
  where p.winback_sent_at is null
    and w.balance > 0
    and p.created_at < now() - interval '3 days'
    and not exists (select 1 from public.orders o where o.user_id = p.user_id)
    and exists (select 1 from public.push_devices d where d.user_id = p.user_id)
  order by p.created_at
  limit greatest(p_limit, 0);
$$;

-- Client roles must not enumerate candidate user ids.
revoke all on function public.winback_candidates(int) from anon, authenticated;

-- Daily at 15:00 UTC. The winback_sent_at guard makes it idempotent per user;
-- the daily cadence just picks up newly-eligible signups.
select cron.schedule(
    'relay-winback',
    '0 15 * * *',
    $cmd$
    select net.http_post(
        url := 'https://enugzltysdmjzavisloy.supabase.co/functions/v1/winback',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'x-cron-secret', private_cron_secret()
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 60000
    );
    $cmd$
);
