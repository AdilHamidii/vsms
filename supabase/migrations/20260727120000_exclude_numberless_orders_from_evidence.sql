-- A route that never issued a number cannot have failed to deliver on it.
--
-- `refresh_route_observed_success` classified every closed order as evidence,
-- with no check that we ever actually got a number. Orders that die inside
-- create-order — margin_too_low, provider out of stock, provider unreachable —
-- close in under a second with `smspva_number is null`, and were being counted
-- as delivery failures against the route.
--
-- That is not a subtle miscount, it is self-reinforcing. One of the
-- `is_conclusive` clauses counts a cancel when the same user reorders the same
-- service within 10 minutes — which is exactly what a user does when the
-- button keeps failing. So:
--
--   1. a route's live price ticks 1c above the order-time ceiling
--   2. every attempt is refused before a number is ever reserved
--   3. the user retries; each retry marks the PREVIOUS one "conclusive"
--   4. the route reaches received=0 over >= p_min_sample and AUTO-HIDES
--
-- Observed live 2026-07-26: user e72a3b1e tapped TikTok/Netherlands 8 times in
-- 90 seconds. All 8 closed in 0s with no number. The route now reads
-- success_rate 0, rate_source 'measured', success_sample 8, status 'hidden' —
-- and has ZERO orders in the lookback that ever held a real number. It was
-- removed from the catalog for failing a test it was never given. One
-- frustrated user deleted a route by tapping retry.
--
-- Fix is one predicate: only orders that actually reserved a number are
-- evidence about delivery. Supply and pricing failures are real problems, but
-- they belong to create-order and the price ceiling, not to a route's
-- delivery rate.
--
-- Everything else in this function is preserved verbatim from the live
-- definition (dumped with pg_get_functiondef before editing): the asymmetric
-- demotion (promote at p_min_sample, demote a zero-code route at 2), the
-- dev-account exclusion, standard-tier-only, and the provider default via
-- active_sms_provider().

create or replace function public.refresh_route_observed_success(
  p_lookback interval default '3 days'::interval,
  p_min_sample integer default 3,
  p_provider text default null::text)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_hidden integer;
  v_provider text := coalesce(p_provider, public.active_sms_provider());
  c_min_negative constant integer := 2;
  c_dev_user constant uuid := '825688de-6117-4251-9f90-93b83b41b572';
begin
  update public.routes
  set success_rate = null, rate_source = null, success_sample = null
  where provider = v_provider and rate_source = 'measured';

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
      and o.tier = 'standard'
      and o.user_id <> c_dev_user
      and o.created_at >= now() - p_lookback
      and o.closed_at is not null
      -- THE FIX: no number was ever issued, so this order says nothing about
      -- whether the route delivers. It failed in create-order (price ceiling,
      -- stockout, provider fault) before delivery was ever on the table.
      and o.smspva_number is not null
  ),
  obs as (
    select service_id, country_id,
      count(*) filter (where is_conclusive) as closed,
      count(*) filter (where is_code)       as received
    from classified
    group by service_id, country_id
    having count(*) filter (where is_conclusive) >= p_min_sample
        or (count(*) filter (where is_code) = 0
            and count(*) filter (where is_conclusive) >= c_min_negative)
  ),
  upd as (
    update public.routes r
    set success_rate = round(100.0 * obs.received / obs.closed)::int,
        rate_source = 'measured',
        success_sample = obs.closed,
        status = case
                   when obs.received = 0 and obs.closed >= p_min_sample then 'hidden'
                   else r.status
                 end
    from obs
    where r.service_id = obs.service_id
      and r.country_id = obs.country_id
      and r.provider = v_provider
    returning (obs.received = 0 and obs.closed >= p_min_sample) as was_hidden
  )
  select count(*) filter (where was_hidden) into v_hidden from upd;
  return v_hidden;
end;
$function$;

-- Repair the route this already destroyed. The function clears measured rates
-- on every run but NEVER sets status back to 'active', so a wrongly-hidden
-- route stays hidden forever — the damage does not self-heal once the cause is
-- fixed. Restore only routes whose hiding rests entirely on numberless orders:
-- measured 0% with no order in the lookback that ever held a number.
update public.routes r
set status = 'active', success_rate = null, rate_source = null, success_sample = null
where r.status = 'hidden'
  and r.rate_source = 'measured'
  and r.success_rate = 0
  and r.retail_credits is not null
  and not exists (
    select 1 from public.orders o
    where o.service_id = r.service_id
      and o.country_id = r.country_id
      and o.closed_at is not null
      and o.smspva_number is not null
      and o.created_at >= now() - interval '3 days'
  );
