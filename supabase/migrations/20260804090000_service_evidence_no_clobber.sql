-- Service-level evidence: one pass over all CURRENT owners, not one pass per
-- provider that overwrites the last.
--
-- ── The bug ────────────────────────────────────────────────────────────────
--
-- `refresh_evidence_all_providers` loops over every provider with active routes
-- and calls `refresh_service_delivery(lookback, provider)` for each. That is
-- correct for ROUTES, which carry a `provider` column and are therefore
-- naturally disjoint. It is NOT correct for SERVICES: `public.services` has no
-- provider column, so every pass writes the SAME row and the last one wins.
--
-- The wrapper's own comment claimed "`services` is made disjoint by the
-- ownership predicate". That assumed the documented invariant "ownership is per
-- SERVICE, never per route". Measured 2026-08-04, the live catalog does not
-- satisfy it: **109 of 254 visible services have active routes on two
-- providers**, carrying ~80% of all active routes. The loop runs `order by 1`,
-- so alphabetically `smspva` runs last and silently wins every service it
-- co-owns — including the highest-volume ones (facebook: 52 orders across 4
-- historical providers, 2 current owners; leboncoin: 50 across 3).
--
-- ── The fix ────────────────────────────────────────────────────────────────
--
-- Drop the per-provider parameter and filter each ORDER by whether ITS OWN
-- provider still actively serves that service. One pass, no overwriting, and
-- the property that mattered is preserved exactly: an order placed on a
-- provider that no longer serves the service is still excluded, so retired
-- providers drop out by construction. See "Evidence must describe the provider
-- that serves the NEXT order".
--
-- This is the honest aggregate for a service-level roll-up. A service on two
-- providers genuinely has two possible next orders depending on the country the
-- user picks, so describing it with one provider's numbers was never right —
-- it was arbitrary, not conservative.
--
-- ROUTE evidence is untouched: `refresh_route_observed_success` stays
-- per-provider and keeps being called inside the loop, because route rows ARE
-- disjoint by provider and that scoping is what makes them correct.
--
-- All four evidence rules are carried over unchanged and are load-bearing:
--   1. `is_code` is `otp is not null`, never `status = 'received'` — a rescued
--      code lives on a `canceled` row (see the late-code rescue).
--   2. Numberless orders are excluded (`smspva_number is not null`): an order
--      that died inside create-order never reserved anything and is not a
--      delivery failure.
--   3. The wipe is CONDITIONAL — evidence is cleared only when the window
--      genuinely has nothing to say, so a quiet service is not frozen out of
--      re-evaluation.
--   4. The dev account is excluded.

drop function if exists public.refresh_service_delivery(interval, text);

create or replace function public.refresh_service_delivery(
  p_lookback interval default '30 days'::interval
) returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_updated integer;
begin
  -- CONDITIONAL wipe. Only for services we currently sell (any provider), and
  -- only when no qualifying order survives the ownership filter below.
  update public.services s
  set observed_attempts = null, observed_codes = null, observed_orders = null
  where (s.observed_attempts is not null or s.observed_orders is not null)
    and exists (select 1 from public.routes r
                where r.service_id = s.id and r.status = 'active')
    and not exists (
      select 1 from public.orders o
      where o.service_id = s.id
        and o.tier = 'standard'
        and o.created_at >= now() - p_lookback
        and o.closed_at is not null
        and o.smspva_number is not null
        and o.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
        -- the ORDER's own provider must still serve this service
        and exists (select 1 from public.routes r2
                    where r2.service_id = o.service_id
                      and r2.provider = o.provider
                      and r2.status = 'active')
    );

  with classified as (
    select o.service_id,
      (o.otp is not null) as is_code,
      (
        o.otp is not null
        or o.status = 'received'
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
      and o.tier = 'standard'
      and o.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
      and o.smspva_number is not null
      and exists (select 1 from public.routes r
                  where r.service_id = o.service_id
                    and r.provider = o.provider
                    and r.status = 'active')
  ),
  agg as (
    select service_id,
           count(*) filter (where is_conclusive) as attempts,
           count(*) filter (where is_code)       as codes,
           count(*)                              as orders
    from classified group by service_id
  ),
  upd as (
    update public.services s
    set observed_attempts = agg.attempts,
        observed_codes    = agg.codes,
        observed_orders   = agg.orders
    from agg where s.id = agg.service_id
    returning 1
  )
  select count(*) into v_updated from upd;
  return v_updated;
end;
$function$;

revoke execute on function public.refresh_service_delivery(interval) from public, anon, authenticated;

-- Wrapper: routes stay in the per-provider loop, services move OUT of it and
-- run once — exactly the treatment country evidence already gets, and for the
-- same reason (the target table has no provider column).
create or replace function public.refresh_evidence_all_providers(
  p_lookback interval default '30 days'::interval,
  p_min_sample integer default 3
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_provider  text;
  v_out       jsonb := '{}'::jsonb;
  v_routes    integer;
  v_services  integer;
  v_countries integer;
begin
  for v_provider in
    select distinct provider
    from public.routes
    where status = 'active' and provider is not null
    order by 1
  loop
    -- ROUTES only. `routes` carries a provider column, so these passes are
    -- naturally disjoint and the per-provider scoping is what makes them right.
    v_routes := public.refresh_route_observed_success(p_lookback, p_min_sample, v_provider);
    v_out := v_out || jsonb_build_object(v_provider, jsonb_build_object('routes', v_routes));
  end loop;

  -- ONCE, outside the loop. Neither `services` nor `countries` has a provider
  -- column, so a per-provider pass over either one overwrites the previous
  -- provider's numbers instead of adding to them. Both filter to current-owner
  -- orders internally.
  v_services  := public.refresh_service_delivery(p_lookback);
  v_countries := public.refresh_country_delivery(p_lookback);

  return v_out || jsonb_build_object('services', v_services, 'countries', v_countries);
end;
$function$;

revoke execute on function public.refresh_evidence_all_providers(interval, integer) from public, anon, authenticated;

do $$
declare n_bad int;
begin
  -- the two-arg form must be gone, or the wrapper could bind the old one
  select count(*) into n_bad from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'refresh_service_delivery'
     and pg_get_function_identity_arguments(p.oid) <> 'p_lookback interval';
  if n_bad <> 0 then
    raise exception 'stale refresh_service_delivery overload still present (% rows)', n_bad;
  end if;

  select count(*) into n_bad from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname in ('refresh_service_delivery','refresh_evidence_all_providers')
     and has_function_privilege('anon', p.oid, 'execute');
  if n_bad <> 0 then
    raise exception 'evidence functions still executable by anon (% rows)', n_bad;
  end if;
end $$;
