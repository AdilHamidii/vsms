-- Demote a failing seeded route faster than we promote a working one.
--
-- WHY: `success_rate` starts life as SMSPVA's own per-country grade
-- (sync-smspva-conversions: grade 3 -> 90, 2 -> 70, 1 -> 40) written with
-- rate_source='seeded'. That is a vendor's marketing number about a route we
-- may never have sold once. `refresh_route_observed_success` only overrides it
-- at >= 3 conclusive attempts, so a route that has gone 0-for-2 keeps
-- advertising ~90% — which is exactly what leboncoin/PT did while delivering
-- 0 of 2. The badge was most confident precisely where we knew least.
--
-- The fix is ASYMMETRIC, because the two directions carry different risk:
--   * Promoting a route (telling users it works) on thin evidence sells a
--     number that may not deliver. Still needs p_min_sample (3) conclusive.
--   * Demoting a route (removing a claim we cannot support) on thin evidence
--     costs nothing but a little traffic. Needs only MIN_NEGATIVE (2), and
--     only when the route has delivered ZERO codes — an unambiguous signal,
--     not a rate that merely looks bad.
--
-- Deliberately NOT symmetric on `status`: hiding a route removes it from sale
-- entirely, and two misses on a genuinely 90% route happen ~1% of the time. So
-- 2 failures replace the seeded claim with a measured 0% (honest badge, route
-- still buyable); it takes the full 3 to actually hide it. One unlucky miss
-- changes nothing at all.
--
-- Signature is UNCHANGED (interval, integer, text) on purpose: sync-prices
-- calls `sb.rpc('refresh_route_observed_success')` with no arguments, and
-- adding a parameter would create an overload rather than a replacement,
-- making that zero-arg call ambiguous.

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
  -- Conclusive attempts required to strip a seeded rate off a route that has
  -- never delivered. Lower than p_min_sample by design (see header).
  c_min_negative constant integer := 2;
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
      and o.created_at >= now() - p_lookback
      and o.closed_at is not null
  ),
  obs as (
    select service_id, country_id,
      count(*) filter (where is_conclusive) as closed,
      count(*) filter (where is_code)       as received
    from classified
    group by service_id, country_id
    -- Normal gate, OR the asymmetric one: zero codes on >= 2 conclusive.
    having count(*) filter (where is_conclusive) >= p_min_sample
        or (count(*) filter (where is_code) = 0
            and count(*) filter (where is_conclusive) >= c_min_negative)
  ),
  upd as (
    update public.routes r
    set success_rate = round(100.0 * obs.received / obs.closed)::int,
        rate_source = 'measured',
        success_sample = obs.closed,
        -- Hiding still requires the FULL sample. A 0-of-2 route loses its
        -- rosy seeded badge but stays buyable; 0-of-3 gets hidden.
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

revoke execute on function public.refresh_route_observed_success(interval, integer, text)
  from public, anon, authenticated;
