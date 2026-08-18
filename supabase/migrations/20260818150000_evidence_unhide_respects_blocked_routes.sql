-- ─────────────────────────────────────────────────────────────────────────────
-- refresh_route_observed_success(): the un-hide must respect blocked_routes
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Found by the 2026-08-18 orders/money audit. CLAUDE.md's own text says
-- "the un-hide statement must exclude blocked_routes — without that clause it
-- resurrects whatsapp|us, which was blocked because those numbers don't work
-- at all." Both un-hide branches in this function (evidence aged out; newly
-- measured with a code) flipped `hidden -> active` with NO reference to
-- app_config.blocked_routes.
--
-- Today that is latent: `select … from blocked_routes join routes where
-- status='active'` returns 0 rows because sync-5sim (:07) and sync-herosms
-- (:37) re-apply the block every hour and sync-prices (:17) — which calls this
-- — sits between them. But a blocked route could flip active for up to ~50
-- minutes an hour, and create-order gates only on `status = 'active'`. Worse:
-- blocked_routes now carries all 6,392 SMSPVA combos (the retired-provider
-- kill list). This function loops `distinct provider from routes where
-- status='active'`, so SMSPVA is currently never in the loop — but a single
-- SMSPVA row re-activated by hand would put it back in, and this un-hide
-- would then resurrect the whole retired catalog. That is the exact
-- mechanism that produced the 39%-unfillable outage on 2026-08-17.
--
-- Fix: both un-hide branches now require the route NOT be in blocked_routes.
-- Everything else — the evidence maths, the wipe, the numerator/denominator —
-- is byte-identical to the live definition (regenerated from
-- pg_get_functiondef and diffed: exactly two hunks differ, both the added
-- predicate).
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.refresh_route_observed_success(
  p_lookback interval default '30 days'::interval,
  p_min_sample integer default 3,
  p_provider text default null::text)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_measured integer;
  v_provider text := coalesce(p_provider, public.active_sms_provider());
  c_min_negative constant integer := 2;
  c_dev_user constant uuid := '825688de-6117-4251-9f90-93b83b41b572';
  -- Read once per call. `blocked_routes` is a JSON array of "service|country".
  v_blocked jsonb := coalesce(
    (select value from public.app_config where key = 'blocked_routes'), '[]'::jsonb);
begin
  update public.routes r
  set success_rate = null,
      rate_source = null,
      success_sample = null,
      success_codes = null,
      status = case when r.status = 'hidden' and r.retail_credits is not null
                     -- ⚠️ never un-hide a blocked route
                     and not (v_blocked ? (r.service_id || '|' || r.country_id))
                    then 'active' else r.status end
  where r.provider = v_provider
    and r.rate_source = 'measured'
    and not exists (
      select 1 from public.orders o
      where o.service_id = r.service_id
        and o.country_id = r.country_id
        and o.provider = v_provider
        and o.created_at >= now() - p_lookback
        and o.closed_at is not null
        and o.smspva_number is not null
        and coalesce(o.from_default, false) = false
        and o.user_id <> c_dev_user
    );

  with classified as (
    select o.service_id, o.country_id,
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
    where o.provider = v_provider
      and o.tier = 'standard'
      and o.user_id <> c_dev_user
      and o.created_at >= now() - p_lookback
      and o.closed_at is not null
      and o.smspva_number is not null
      and coalesce(o.from_default, false) = false
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
    set success_rate   = round(100.0 * obs.received / obs.closed)::int,
        rate_source    = 'measured',
        success_sample = obs.closed,
        success_codes  = obs.received,
        status = case
                   when obs.received > 0 and r.status = 'hidden'
                        and r.retail_credits is not null
                        -- ⚠️ never un-hide a blocked route
                        and not (v_blocked ? (r.service_id || '|' || r.country_id))
                   then 'active'
                   else r.status
                 end
    from obs
    where r.service_id = obs.service_id
      and r.country_id = obs.country_id
      and r.provider = v_provider
    returning 1 as touched
  )
  select count(*) into v_measured from upd;
  return v_measured;
end;
$function$;

revoke execute on function public.refresh_route_observed_success(interval, integer, text)
  from public, anon, authenticated;
