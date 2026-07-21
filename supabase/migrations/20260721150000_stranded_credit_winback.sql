-- Winback for stranded-credit users: refunded, walked away, wallet still
-- loaded. As of 2026-07-21 that cohort is 15 users / 140 credits — they
-- already went through checkout once, so a single honest nudge ("your
-- credits are still here, delivery improved") is the cheapest possible
-- reactivation.
--
-- The nudge is GATED on measured delivery: it fires only when the active
-- SMS provider's last-48h received rate (conclusive orders only) is >= 40%
-- on a sample of >= 5. Promising "delivery improved" to users we already
-- burned, and then failing them again, would convert soft churn into
-- permanent churn — the gate makes the cron arm itself only when the claim
-- is true. 40% is SMSPVA's measured historical level; the same convention
-- as everywhere else: quick cancels (<90s... here <240s per the newer
-- convention) are inconclusive.

alter table public.profiles
  add column if not exists stranded_nudge_sent_at timestamptz;

comment on column public.profiles.stranded_nudge_sent_at is
  'One-time stranded-credit winback push (winback fn); null = not yet sent.';

-- Last-48h delivery rate of the active provider, or null under min sample.
create or replace function public.recent_sms_delivery_rate(
  p_window interval default '48 hours',
  p_min_sample integer default 5
)
returns numeric
language sql
stable
security definer
set search_path to 'public'
as $function$
  with c as (
    select (o.status = 'received') as is_code
    from public.orders o
    where o.provider = public.active_sms_provider()
      and o.tier = 'standard'
      and o.created_at >= now() - p_window
      and o.closed_at is not null
      and o.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
      and (o.status in ('received', 'expired')
           or (o.status = 'canceled' and o.closed_at - o.created_at >= interval '240 seconds'))
  )
  select case when count(*) >= p_min_sample
              then round(100.0 * count(*) filter (where is_code) / count(*))
              else null end
  from c;
$function$;

revoke execute on function public.recent_sms_delivery_rate(interval, integer)
  from public, anon, authenticated;

-- Users whose LAST SMS order failed (expired/canceled), who never came back,
-- still hold credits, and can actually be reached (have a push device).
-- Returns nothing while the delivery gate is closed, so the daily cron can
-- call it unconditionally.
create or replace function public.stranded_credit_candidates(p_limit integer default 100)
returns table (user_id uuid, balance integer)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select w.user_id, w.balance
  from public.wallets w
  join lateral (
    select o.status
    from public.orders o
    where o.user_id = w.user_id
    order by o.created_at desc
    limit 1
  ) last_order on true
  join public.profiles p on p.user_id = w.user_id
  where coalesce(public.recent_sms_delivery_rate(), 0) >= 40
    and w.balance > 0
    and last_order.status in ('expired', 'canceled')
    and p.stranded_nudge_sent_at is null
    and w.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
    -- Not mid-session: give them 24h of quiet before nudging.
    and not exists (
      select 1 from public.orders o2
      where o2.user_id = w.user_id
        and o2.created_at >= now() - interval '24 hours'
    )
    and exists (select 1 from public.push_devices d where d.user_id = w.user_id)
  limit p_limit;
$function$;

revoke execute on function public.stranded_credit_candidates(integer)
  from public, anon, authenticated;
