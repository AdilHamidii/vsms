-- Late-code rescue: stop throwing away codes that arrive just after a cancel.
--
-- Measured over the 30 days to 2026-07-27: cancels land at a median of 57s and
-- codes arrive at a median of 58s. 45% of codes that arrive do so after 60s and
-- 29% after 90s. `cancel-order` refunded AND called release(), killing the
-- number at the provider — so a code landing seconds later was discarded.
-- Estimated ~30 codes forfeited per 30 days against 38 actually delivered.
--
-- Owner decision 2026-07-27: keep watching after a cancel and hand the code
-- over for free. The user keeps the refund; we eat the wholesale cost. That is
-- a deliberate giveaway, not an accounting error — a delivered code is worth
-- far more than the ~$0.05-$3.50 of provider spend, because 92% of users who
-- ever receive a code go on to purchase.
--
-- Mechanics: cancel-order stops releasing the number and instead stamps
-- late_watch_until (the original reservation deadline). poll-active-orders
-- sweeps canceled orders still inside that window, and on a hit writes the code
-- onto the row and pushes it. Status STAYS 'canceled' and the refund stands —
-- deliberately, because `order_status` cannot grow a value without shipping the
-- app first (iOS OrderStatus is a plain String enum with no unknown case, so an
-- unrecognised status breaks the Orders tab for everyone on the released
-- build). Once the window passes with no code, the poller releases the number
-- to reclaim what it can.

alter table public.orders
  add column if not exists late_watch_until timestamptz;

comment on column public.orders.late_watch_until is
  'Set by cancel-order when a canceled order should keep being polled for a '
  'late-arriving SMS. Cleared by poll-active-orders once the code lands or the '
  'window closes. Status stays canceled and the refund stands throughout.';

-- Partial index: the sweep only ever wants canceled rows still being watched.
create index if not exists orders_late_watch_idx
  on public.orders (late_watch_until)
  where late_watch_until is not null and otp is null;

-- Delivery evidence must count a late code as a code. Both refresh functions
-- keyed on `status = 'received'`, which a rescued order never reaches — so
-- without this a route that DID deliver would be recorded as having failed,
-- and could auto-hide itself for succeeding.
--
-- `otp is not null` is the honest predicate for "did this route produce a
-- code?" and is true for both normal and rescued deliveries.
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
  v_hidden integer;
  v_provider text := coalesce(p_provider, public.active_sms_provider());
  c_min_negative constant integer := 2;
  c_dev_user constant uuid := '825688de-6117-4251-9f90-93b83b41b572';
begin
  -- Only clear a measured rate when the new window has something to say about
  -- that route. The unconditional wipe meant a 3-day window plus ~10 orders/day
  -- left exactly ONE measured route in a catalog of 17,807: facebook/dk was
  -- measured at 80% on 2026-07-25 and deleted three days later.
  update public.routes r
  set success_rate = null, rate_source = null, success_sample = null
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
      -- An order that never got a number says nothing about delivery.
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

-- Same two corrections for the service-level rollup, which never received the
-- numberless predicate at all. Live consequence on 2026-07-27: TikTok reported
-- 29% (9 of its 15 orders never got a number) against a true 67%, leaving it one
-- bad day from crossing the <20% auto-demotion threshold.
-- Preserved verbatim from pg_get_functiondef (2026-07-27) — same return type,
-- same wipe predicate, same four is_conclusive clauses. ONLY the two evidence
-- corrections are applied.
create or replace function public.refresh_service_delivery(
  p_lookback interval default '30 days'::interval,
  p_provider text default null::text)
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
  set observed_attempts = null, observed_codes = null, observed_orders = null
  where observed_attempts is not null or observed_orders is not null;

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
      and o.provider = v_provider
      and o.tier = 'standard'
      and o.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
      -- An order that never got a number says nothing about delivery.
      and o.smspva_number is not null
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
