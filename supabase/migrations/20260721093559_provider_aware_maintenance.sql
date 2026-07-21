-- Make the catalog-maintenance functions follow whichever provider is actually
-- serving users, and stop them dying with a provider's sync job.
--
-- Four maintenance jobs lived inside sync-smspool: observed success rates,
-- service visibility, per-service delivery evidence, and the self-correcting
-- catalog ranking. None of them are SMSPool-specific work — but when
-- relay-sync-smspool was (correctly) unscheduled on the move to SMSPVA, all
-- four stopped. No error, no alert. The result is that the "self-correcting"
-- catalog froze: 6 of 268 services carry any delivery evidence at all, dated
-- 07:07 UTC on 2026-07-21, and a service whose route recovers never becomes
-- visible again.
--
-- Worse, two of them hardcode `provider = 'smspool'`, so simply rescheduling
-- them would have measured a provider that now serves zero traffic while
-- SMSPVA serves all of it — producing confident numbers about nothing.
--
-- Fix: derive the provider from the data instead of hardcoding it, so the NEXT
-- provider switch cannot silently break this again. The calls move to
-- sync-prices, which owns SMSPVA pricing and already runs hourly.

-- Which provider is actually serving users right now? Defined by where the
-- bookable catalog lives, so it follows a provider switch automatically.
create or replace function public.active_sms_provider()
returns text
language sql
stable
security definer
set search_path to 'public'
as $function$
  select provider
  from public.routes
  where status = 'active' and provider is not null
  group by provider
  order by count(*) desc
  limit 1;
$function$;

revoke execute on function public.active_sms_provider() from public, anon, authenticated;

-- ── Per-service delivery evidence ────────────────────────────────────────
-- Dropped and recreated rather than overloaded: two versions both having
-- defaults would make a no-argument call ambiguous.
drop function if exists public.refresh_service_delivery(interval);

create or replace function public.refresh_service_delivery(
  p_lookback interval default '30 days',
  p_provider text default null
)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_updated integer;
  v_provider text := coalesce(p_provider, public.active_sms_provider());
begin
  update public.services
  set observed_attempts = null, observed_codes = null
  where observed_attempts is not null;

  with classified as (
    select o.service_id,
      (o.status = 'received') as is_code,
      (
        o.status = 'received'
        or o.status = 'expired'
        or (o.status = 'canceled' and o.closed_at - o.created_at >= interval '240 seconds')
        or (o.status = 'canceled' and exists (
              select 1 from public.orders n
              where n.user_id = o.user_id
                and n.service_id = o.service_id
                and n.id <> o.id
                and n.created_at >= o.closed_at
                and n.created_at < o.closed_at + interval '10 minutes'))
      ) as is_conclusive
    from public.orders o
    where o.created_at >= now() - p_lookback
      and o.closed_at is not null
      -- Follows the live provider. Evidence from a retired provider describes
      -- numbers no user can be sold any more.
      and o.provider = v_provider
      and o.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
  ),
  agg as (
    select service_id,
           count(*) filter (where is_conclusive) as attempts,
           count(*) filter (where is_code)       as codes
    from classified group by service_id
  ),
  upd as (
    update public.services s
    set observed_attempts = agg.attempts,
        observed_codes    = agg.codes
    from agg where s.id = agg.service_id
    returning 1
  )
  select count(*) into v_updated from upd;
  return v_updated;
end;
$function$;

revoke execute on function public.refresh_service_delivery(interval, text) from public, anon, authenticated;

-- ── Per-route observed success ───────────────────────────────────────────
-- New generic name; refresh_smspool_observed_success stays untouched so
-- sync-smspool keeps working if it is ever rescheduled. The two are disjoint —
-- each only nulls and writes rows for its own provider — so both running does
-- not corrupt anything.
create or replace function public.refresh_route_observed_success(
  p_lookback interval default '3 days',
  p_min_sample integer default 3,
  p_provider text default null
)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_hidden integer;
  v_provider text := coalesce(p_provider, public.active_sms_provider());
begin
  update public.routes set success_rate = null where provider = v_provider;

  with classified as (
    select o.service_id, o.country_id,
      (o.status = 'received') as is_code,
      (
        o.status = 'received'
        or o.status = 'expired'
        or (o.status = 'canceled' and o.closed_at - o.created_at >= interval '240 seconds')
        or (o.status = 'canceled' and exists (
              select 1 from public.orders n
              where n.user_id = o.user_id
                and n.service_id = o.service_id
                and n.id <> o.id
                and n.created_at >= o.closed_at
                and n.created_at < o.closed_at + interval '10 minutes'))
      ) as is_conclusive
    from public.orders o
    where o.provider = v_provider
      and o.created_at >= now() - p_lookback
      and o.closed_at is not null
  ),
  obs as (
    select service_id, country_id,
      count(*) filter (where is_conclusive) as closed,
      count(*) filter (where is_code)       as received
    from classified
    group by service_id, country_id
    having count(*) filter (where is_conclusive) >= p_min_sample
  ),
  upd as (
    update public.routes r
    set success_rate = round(100.0 * obs.received / obs.closed)::int,
        status = case when obs.received = 0 then 'hidden' else r.status end
    from obs
    where r.service_id = obs.service_id
      and r.country_id = obs.country_id
      and r.provider = v_provider
    returning (obs.received = 0) as was_hidden
  )
  select count(*) filter (where was_hidden) into v_hidden from upd;
  return v_hidden;
end;
$function$;

revoke execute on function public.refresh_route_observed_success(interval, integer, text) from public, anon, authenticated;
