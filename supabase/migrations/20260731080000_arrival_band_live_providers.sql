-- Correction to 20260731070000, which over-tightened refresh_arrival_timing.
--
-- That migration replaced the (genuinely wrong) `active_sms_provider()` vote
-- with the owner-scoping predicate used by the route/service/country refreshes:
-- an order counts only if its provider STILL OWNS that service. For delivery
-- evidence that is exactly right. For arrival TIMING it was too strict, and the
-- effect was measured immediately rather than assumed:
--
--   arrivals in the trailing 30 days, dev account excluded
--     total, any provider ....................... 46
--     provider still owns the service ...........  5   ← what 070000 counted
--     provider still has ANY active routes ...... 43
--
-- All 38 SMSPVA arrivals are on services that were RE-HOMED to HeroSMS in the
-- cutover — the high-volume ones (facebook, instagram, leboncoin, tiktok) are
-- exactly the services that moved. So owner-scoping dropped the sample to 5,
-- below p_min_global = 20, and every service went NULL: the app stopped quoting
-- an arrival time anywhere.
--
-- Silence is the correct answer when we know nothing, and this file's standing
-- rule is to show nothing rather than a plausible guess. But we are not in that
-- position — we hold 43 real measurements on the two providers we actually buy
-- from. And the quote is load-bearing: p90 rendered next to a running clock is
-- what stops users destroying a paid order at 57s, one second before the median
-- code. Throwing it away has a measured cost.
--
-- So the two scopes get the two different predicates they always should have:
--
--   'global'  — any order whose provider still has active routes. This is a
--               cross-product claim ("most codes arrive within N"), so the
--               right filter is "a provider we still use", not "this exact
--               service". Retired providers (smspool, virtualsms hold zero
--               active routes) drop out by construction — which was the actual
--               bug, since 3 smspool arrivals were in the old pool too.
--
--   'service' — unchanged from 070000: the provider must still own the service.
--               This one IS a claim about that specific service's record, so a
--               re-homed service must not inherit its old provider's timing.
--
-- Net effect vs. before any of today's work: the global band stops being
-- whichever provider won a route-count vote and becomes every provider we buy
-- from, which is what `arrival_scope = 'global'` has always claimed to mean.
create or replace function public.refresh_arrival_timing(
  p_lookback interval default '30 days'::interval,
  p_hold_seconds integer default 120,
  p_min_service integer default 8,
  p_min_p90 integer default 20,
  p_min_global integer default 20,
  p_provider text default null::text)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  g_n int; g_p50 int; g_p90 int; g_hold int; v_updated int;
begin
  -- Staleness is worse than absence: wipe every row we own before rewriting, so
  -- a provider switch degrades to "say nothing" rather than to yesterday's
  -- numbers describing a provider we no longer use.
  update public.services
     set arrival_p50_seconds = null, arrival_p90_seconds = null,
         arrival_sample = null, arrival_scope = null, arrival_hold_pct = null
   where arrival_scope is not null;

  -- GLOBAL: any provider we still buy from.
  select count(*),
         ceil(percentile_cont(0.5) within group (order by secs))::int,
         ceil(percentile_cont(0.9) within group (order by secs))::int,
         round(100.0 * count(*) filter (where secs <= p_hold_seconds)
               / nullif(count(*), 0))::int
    into g_n, g_p50, g_p90, g_hold
  from (
    select extract(epoch from (o.arrived_at - o.created_at))::numeric as secs
      from public.orders o
     where o.arrived_at is not null
       and o.arrived_at > o.created_at
       and o.created_at >= now() - p_lookback
       and o.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
       and (p_provider is null or o.provider = p_provider)
       and exists (select 1 from public.routes r
                    where r.provider = o.provider and r.status = 'active')
  ) d;

  -- No honest claim available anywhere: leave everything NULL and stay silent.
  if coalesce(g_n, 0) < p_min_global then
    return 0;
  end if;

  update public.services
     set arrival_p50_seconds = g_p50,
         arrival_p90_seconds = case when g_n >= p_min_p90 then g_p90 end,
         arrival_sample      = g_n,
         arrival_scope       = 'global',
         arrival_hold_pct    = g_hold
   where id is not null;   -- deliberate table-wide UPDATE; safeupdate needs a WHERE

  -- PER-SERVICE: the provider must still own the service, so a re-homed service
  -- cannot inherit its previous provider's record as its own.
  with per as (
    select o.service_id,
           count(*) as n,
           ceil(percentile_cont(0.5) within group
                (order by extract(epoch from (o.arrived_at - o.created_at))))::int as p50,
           ceil(percentile_cont(0.9) within group
                (order by extract(epoch from (o.arrived_at - o.created_at))))::int as p90,
           round(100.0 * count(*) filter (
                   where extract(epoch from (o.arrived_at - o.created_at)) <= p_hold_seconds)
                 / count(*))::int as hold
      from public.orders o
     where o.arrived_at is not null
       and o.arrived_at > o.created_at
       and o.created_at >= now() - p_lookback
       and o.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
       and (p_provider is null or o.provider = p_provider)
       and exists (select 1 from public.routes r
                    where r.service_id = o.service_id
                      and r.provider = o.provider
                      and r.status = 'active')
     group by o.service_id
    having count(*) >= p_min_service
  ),
  upd as (
    update public.services s
       set arrival_p50_seconds = per.p50,
           arrival_p90_seconds = case when per.n >= p_min_p90 then per.p90 end,
           arrival_sample      = per.n,
           arrival_scope       = 'service',
           arrival_hold_pct    = per.hold
      from per where s.id = per.service_id
    returning 1
  )
  select count(*) into v_updated from upd;

  return v_updated;
end;
$function$;

revoke execute on function public.refresh_arrival_timing(interval, integer, integer, integer, integer, text)
  from public, anon, authenticated;

select public.refresh_arrival_timing();
