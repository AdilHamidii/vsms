-- 20260808190000_route_wipe_dev_filter.sql
--
-- One predicate. `refresh_route_observed_success`'s conditional-wipe
-- `not exists` did not exclude the dev account, while its `classified` CTE —
-- the half that actually COUNTS evidence — always has. The two halves must
-- agree, and `refresh_service_delivery` and `refresh_country_delivery` already
-- carry the filter in both places. Route was the odd one out.
--
-- THE FAILURE IS SILENT AND IT IS STALENESS, NOT A WRONG NUMBER. When every
-- non-dev order on a route drops out of the window (or, after 20260808170000,
-- gets excluded as default-landed), `classified` produces no row, so `obs` has
-- nothing and the UPDATE touches nothing — and the wipe that should have
-- cleared the route is held open by the dev account's own orders. The route
-- keeps whatever the PREVIOUS run wrote, forever, with `rate_source` still
-- reading 'measured'.
--
-- Caught 2026-08-08 on deliveroo/us: 0 non-dev evidence-eligible orders, 3 dev
-- orders keeping the wipe shut, and the route still advertising "Worked 0 of 5
-- times" from five orders that had just been excluded from evidence. Every
-- other measured route in the catalog had 2-4 real orders behind it, so the
-- measured blast radius of this fix is exactly ONE route, which correctly
-- becomes "Not tested".
--
-- Note the asymmetry is what makes it dangerous rather than merely wrong: a
-- route the dev account touches is precisely a route someone was debugging.


CREATE OR REPLACE FUNCTION public.refresh_route_observed_success(p_lookback interval DEFAULT '30 days'::interval, p_min_sample integer DEFAULT 3, p_provider text DEFAULT NULL::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_measured integer;
  v_provider text := coalesce(p_provider, public.active_sms_provider());
  c_min_negative constant integer := 2;
  c_dev_user constant uuid := '825688de-6117-4251-9f90-93b83b41b572';
begin
  -- Evidence has aged out of the window: drop the measured rate AND give the
  -- route its shelf space back, so it can be re-measured. The un-hide is kept
  -- even though we no longer hide, because routes hidden by the OLD behaviour
  -- must still be able to come back.
  update public.routes r
  set success_rate = null,
      rate_source = null,
      success_sample = null,
      success_codes = null,
      status = case when r.status = 'hidden' and r.retail_credits is not null
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
        -- default-landed orders (the app's own pre-selection) are excluded — the
        -- user never chose the service, so the number was never submitted and no
        -- code was requested; counting them measures our steering, not delivery.
        and coalesce(o.from_default, false) = false
        -- must match `classified`'s dev exclusion, or a route whose only surviving
        -- orders are the dev account's never wipes and freezes at stale numbers
        and o.user_id <> c_dev_user
    );

  with classified as (
    select o.service_id, o.country_id,
      -- A rescued code lives on a CANCELED row (late-code rescue), so the
      -- test is "is there an otp", never status = 'received'.
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
      -- Orders that never reserved a number are not evidence about delivery.
      and o.smspva_number is not null
      -- default-landed orders (the app's own pre-selection) are excluded — the
      -- user never chose the service, so the number was never submitted and no
      -- code was requested; counting them measures our steering, not delivery.
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
        -- NO auto-hide. A route that delivers zero now keeps its shelf space
        -- and carries an honest "worked 0 of N" label instead of vanishing.
        -- Recovery un-hide is retained for routes hidden by the old rule.
        status = case
                   when obs.received > 0 and r.status = 'hidden'
                        and r.retail_credits is not null then 'active'
                   else r.status
                 end
    from obs
    where r.service_id = obs.service_id
      and r.country_id = obs.country_id
      and r.provider = v_provider
    returning 1 as touched
  )
  select count(*) into v_measured from upd;
  -- Return value changed meaning: was "routes hidden", now "routes measured".
  -- sync-prices only logs it, so no caller depends on the old semantics.
  return v_measured;
end;
$function$;
