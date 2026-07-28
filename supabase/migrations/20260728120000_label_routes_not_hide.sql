-- Label every route instead of hiding the bad ones (owner decision 2026-07-28).
--
-- Two changes:
--   1. refresh_route_observed_success no longer HIDES a route for delivering
--      zero. It still measures, still un-hides on recovery, still un-hides when
--      evidence ages out. Hiding for PRICE (sync-prices, > MAX_WHOLESALE_CENTS)
--      and for blocked_routes is untouched — those are "you literally cannot
--      buy this", not "this performed badly", and 472 of the 688 currently
--      hidden routes are the price kind.
--   2. routes.success_codes records the NUMERATOR, so the UI can say
--      "worked 2 of 7" exactly rather than reconstructing it from a rounded
--      percentage (round(100*2/7) = 29, and round(29*7/100) = 2 only by luck —
--      at 1 of 3 it round-trips to 0.99 -> 1, at 5 of 6 to 4.98 -> 5, but the
--      general case is not safe and an off-by-one in "worked N times" is the
--      kind of wrong number that destroys trust in the whole label).
--
-- WHY UN-HIDING IS SAFE: sync-prices re-evaluates blocked_routes and the price
-- ceiling hourly and re-hides anything genuinely unsellable, so this cannot
-- resurrect a route the user can't actually buy.
--
-- WHY IT IS ALSO NOT MUCH: exactly 4 routes are hidden for measured-zero right
-- now. The value of this change is the label, not the un-hiding — 17,471 of
-- 17,804 active routes have NO evidence of any kind, and today the UI renders
-- that absence as a missing badge, which reads as "fine" rather than "unknown".

alter table public.routes
  add column if not exists success_codes integer;

comment on column public.routes.success_codes is
  'Codes actually delivered within the measurement window — the numerator behind success_rate. NULL when rate_source is not ''measured''. Paired with success_sample (the denominator) so the client can render "worked X of Y" without recomputing from a rounded percentage.';

-- Backfill the handful of currently-measured routes so the label is correct
-- immediately rather than after the next sync-prices run.
update public.routes
set success_codes = round(success_rate * success_sample / 100.0)::int
where rate_source = 'measured'
  and success_rate is not null
  and success_sample is not null
  and success_codes is null;

-- Give back the routes hidden purely for delivering zero. Scoped tightly:
-- must be measured-zero, must still have a price, must be within the ceiling,
-- and must NOT be on the manual kill-list.
--
-- That last clause is not theoretical: without it this statement un-hides
-- whatsapp|us, which is in blocked_routes precisely because those numbers do
-- not work at all. "Never hide a route for poor delivery" and "never show a
-- route we know is broken" are different rules, and blocked_routes wins.
update public.routes r
set status = 'active'
where r.status = 'hidden'
  and r.rate_source = 'measured'
  and r.success_rate = 0
  and r.retail_credits is not null
  and coalesce(r.smoothed_cost_cents, 0) <= 750
  and not exists (
    select 1 from public.app_config c,
           lateral jsonb_array_elements_text(c.value) as x
    where c.key = 'blocked_routes'
      and split_part(x, '|', 1) = r.service_id
      and split_part(x, '|', 2) = r.country_id
  );

create or replace function public.refresh_route_observed_success(
  p_lookback interval default '30 days'::interval,
  p_min_sample integer default 3,
  p_provider text default null
) returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
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

revoke execute on function public.refresh_route_observed_success(interval, integer, text)
  from public, anon, authenticated;
