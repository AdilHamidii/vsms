-- 20260808170000_exclude_default_landed_from_evidence.sql
--
-- Completes the `orders.from_default` exclusion (20260808100000 added the
-- column; 20260808110000 taught `run_watchdog` and the bot's snapshot
-- functions to skip it) by applying the same policy to the three CATALOG
-- evidence refreshes: route, service and country.
--
-- WHY. Until 1.9 the app pre-selected a route for brand-new users (the
-- "affordable starter", picked by array position rather than by pool rate).
-- Investigated 2026-08-04: 32 signups clustered on one route with zero codes,
-- which looked coordinated and was not — sabotage was ruled out on six
-- independent checks. The decisive test was manual: a deliveroo/us number
-- cancelled with 15 minutes left on the provider's clock was pasted into a
-- real Deliveroo signup by hand and the code ARRIVED. The pool was never the
-- problem. Those orders were free numbers nobody had a reason to use — the
-- app handed a new user a phone number they never submitted anywhere, so no
-- code was ever requested.
--
-- Scoring them as delivery failures measures our own steering, not delivery.
-- It is the same class of defect as counting impatient cancels: the number
-- moves, and it moves for a reason that has nothing to do with the provider.
--
-- ⚠️ The exclusion is SYMMETRIC. Rows that DID get a code are flagged too
-- (user 45dd50c8 was default-landed on deliveroo/us and did submit the
-- number). Excluding only the failures would be cherry-picking, and an
-- evidence pipeline that filters on outcome is worse than no filter.


-- ── Backfill: the historical default-landed cohort ───────────────────────────
--
-- `from_default` is stamped by 2.0+ clients only, so every pre-2.0 row is NULL
-- and NULL means "not recorded", never false. The cohort below is identified
-- from documented facts rather than inferred: these are the exact (service,
-- country) pairs `bestStarter` resolved to at the grant sizes that were live
-- between 2026-07-26 and 2026-08-04 (1 cr -> olx/us, 2-3 cr -> deliveroo/ge,
-- 3 cr -> deliveroo/us; see CLAUDE.md, "The grant size decides which ONE route
-- new users land on").
--
-- Four conditions, ALL required, deliberately conservative — a false positive
-- here silently deletes real evidence:
--   1. one of the three documented default pairs,
--   2. the user's FIRST order ever (the starter is only ever pre-selected on an
--      empty history),
--   3. placed under 30 minutes after the account was created,
--   4. on or after 2026-07-26, when the grant-cohort era begins.
--
-- `from_default is null` guards a 2.0+ client's own stamp: a client that
-- explicitly recorded false knows something this heuristic does not, and must
-- win. It also makes this statement safe to re-run.
update public.orders o
set from_default = true
where o.from_default is null
  and (o.service_id, o.country_id) in (('olx','us'), ('deliveroo','us'), ('deliveroo','ge'))
  and o.created_at >= timestamptz '2026-07-26'
  and o.created_at = (select min(o2.created_at) from public.orders o2 where o2.user_id = o.user_id)
  and exists (
    select 1 from auth.users u
    where u.id = o.user_id
      and o.created_at - u.created_at < interval '30 minutes'
  );


-- ── The three evidence refreshes ─────────────────────────────────────────────
--
-- Predicate-only change: `and coalesce(o.from_default, false) = false` is added
-- to each function's conditional-wipe test and to its `classified` row source,
-- i.e. everywhere an `orders` row is counted as attempts / codes / conclusive.
-- `coalesce(..., false)` is load-bearing — NULL is "not recorded", so pre-2.0
-- rows keep counting exactly as they do today.
--
-- Deliberately NOT touched: the `orders n` sub-select inside `is_conclusive`.
-- That one asks "did this user re-order within 10 minutes", which is a fact
-- about behaviour, not an evidence row being counted.


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


CREATE OR REPLACE FUNCTION public.refresh_service_delivery(p_lookback interval DEFAULT '30 days'::interval)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
        -- default-landed orders (the app's own pre-selection) are excluded — the
        -- user never chose the service, so the number was never submitted and no
        -- code was requested; counting them measures our steering, not delivery.
        and coalesce(o.from_default, false) = false
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
      -- default-landed orders (the app's own pre-selection) are excluded — the
      -- user never chose the service, so the number was never submitted and no
      -- code was requested; counting them measures our steering, not delivery.
      and coalesce(o.from_default, false) = false
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


CREATE OR REPLACE FUNCTION public.refresh_country_delivery(p_lookback interval DEFAULT '30 days'::interval, p_provider text DEFAULT NULL::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_updated integer;
  -- p_provider is accepted for signature compatibility and deliberately UNUSED.
  -- A country is not owned by a provider, so scoping it to one wiped the
  -- other's evidence on the next pass.
begin
  -- Conditional wipe: only clear a country the new window genuinely has
  -- nothing to say about. An unconditional reset leaves quiet countries NULL
  -- and permanently unrankable.
  update public.countries c
  set observed_attempts = null, observed_codes = null, observed_orders = null
  where (c.observed_attempts is not null or c.observed_orders is not null)
    and not exists (
      select 1 from public.orders o
      where o.country_id = c.id
        and exists (select 1 from public.routes r
                  where r.service_id = o.service_id and r.provider = o.provider
                    and r.status = 'active')
        and o.tier = 'standard'
        and o.created_at >= now() - p_lookback
        and o.closed_at is not null
        and o.smspva_number is not null
        -- default-landed orders (the app's own pre-selection) are excluded — the
        -- user never chose the service, so the number was never submitted and no
        -- code was requested; counting them measures our steering, not delivery.
        and coalesce(o.from_default, false) = false
        and o.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
    );

  with classified as (
    select o.country_id,
      -- A rescued code sits on a `canceled` row, so status is not the signal.
      (o.otp is not null) as is_code,
      (
        o.otp is not null
        or o.status = 'received'
        or o.status = 'expired'
        or (o.status = 'canceled' and o.closed_at - o.created_at >= interval '240 seconds')
        or (o.status = 'canceled' and exists (
              select 1 from public.orders n
              where n.user_id = o.user_id
                and n.country_id = o.country_id
                and n.id <> o.id
                and n.created_at >= o.closed_at
                and n.created_at < o.closed_at + interval '10 minutes'))
      ) as is_conclusive
    from public.orders o
    where o.created_at >= now() - p_lookback
      and o.closed_at is not null
      and exists (select 1 from public.routes r
                  where r.service_id = o.service_id and r.provider = o.provider
                    and r.status = 'active')
      and o.tier = 'standard'
      and o.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
      -- Orders that never held a number are not delivery evidence.
      and o.smspva_number is not null
      -- default-landed orders (the app's own pre-selection) are excluded — the
      -- user never chose the service, so the number was never submitted and no
      -- code was requested; counting them measures our steering, not delivery.
      and coalesce(o.from_default, false) = false
  ),
  agg as (
    select country_id,
           count(*) filter (where is_conclusive) as attempts,
           count(*) filter (where is_code)       as codes,
           count(*)                              as orders
    from classified group by country_id
  ),
  upd as (
    update public.countries c
    set observed_attempts = agg.attempts,
        observed_codes    = agg.codes,
        observed_orders   = agg.orders
    from agg where agg.country_id = c.id
    returning 1
  )
  select count(*) into v_updated from upd;

  return v_updated;
end;
$function$;
