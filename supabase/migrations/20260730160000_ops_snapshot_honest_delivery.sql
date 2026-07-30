-- ops_snapshot: count codes the way everything else does, stop counting
-- price-rejections as delivery failures, and report the live SMS provider.
--
-- Three corrections, all of which made the digest misreport delivery.
--
-- 1. `received` was `status = 'received'`. Every other consumer was moved to
--    `otp is not null` on 2026-07-27 because a RESCUED code lives on a row the
--    user already cancelled — cancel-order stops releasing the number and
--    poll-active-orders keeps polling to the original deadline, so a code that
--    lands after a cancel is delivered to the user while the row stays
--    'canceled'. ops_snapshot was missed in that pass, so it scores exactly the
--    late-code rescues we built as failures. Confirmed live: one such order
--    exists (tinder/co, cancelled at 119s, OTP at 132s).
--
-- 2. `placed` counted EVERY row, including orders that never got a number.
--    Those close in under a second with no reservation — margin_too_low,
--    stockout, provider fault — and are not delivery evidence; the same rule
--    was already applied to routes/services/countries in 20260727120000. Twelve
--    such orders exist. Left in, a provider whose prices sit above our ceiling
--    reads as a DELIVERY collapse rather than a PRICING problem, which is
--    exactly the wrong diagnosis to hand someone during a provider cutover.
--    They are now reported separately as `numberless` so the pricing failure is
--    visible in its own right instead of being hidden.
--
-- 3. `herosms_usd` was absent. HeroSMS serves SMS for the 150 services carrying
--    99.4% of order volume as of the 2026-07-30 cutover; the digest reported
--    only SMSPVA and SMSPool. An absent balance line reads as healthy.

create or replace function public.ops_snapshot(p_window interval default '06:00:00'::interval)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  with dev as (select '825688de-6117-4251-9f90-93b83b41b572'::uuid as id),
  since as (select now() - p_window as t),
  sign as (
    select count(*)::int as n from auth.users
    where created_at >= (select t from since) and id <> (select id from dev)
  ),
  buys as (
    select count(*)::int as n, coalesce(sum(granted_credits),0)::int as credits
    from public.iap_receipts
    where created_at >= (select t from since) and user_id <> (select id from dev)
  ),
  scoped as (
    select * from public.orders
    where created_at >= (select t from since) and user_id <> (select id from dev)
  ),
  -- Only orders that actually reserved a number are delivery evidence.
  numbered as (select * from scoped where smspva_number is not null),
  ord as (
    select count(*)::int as placed,
           count(*) filter (where otp is not null)::int as received,
           count(*) filter (where otp is null and status in ('expired','canceled'))::int as failed
    from numbered
  ),
  nonum as (select count(*)::int as n from scoped where smspva_number is null),
  by_prov as (
    select coalesce(provider, 'unknown') as provider,
           count(*)::int as placed,
           count(*) filter (where otp is not null)::int as received,
           count(*) filter (where otp is null and status in ('expired','canceled'))::int as failed
    from numbered group by 1
  ),
  esim as (
    select count(*)::int as n, coalesce(sum(cost_credits),0)::int as credits
    from public.esim_orders
    where created_at >= (select t from since) and user_id <> (select id from dev)
  ),
  -- A balance reading is only a fact while the poller that wrote it is alive.
  bal_pool as (
    select case when (value->>'checked_at')::timestamptz >= now() - interval '10 minutes'
                then (value->>'balance_usd')::numeric end as usd
    from public.app_config where key = 'smspool_health'
  ),
  bal_pva as (
    select case when (value->>'checked_at')::timestamptz >= now() - interval '10 minutes'
                then (value->>'balance_usd')::numeric end as usd
    from public.app_config where key = 'smspva_health'
  ),
  bal_hero as (
    select case when (value->>'checked_at')::timestamptz >= now() - interval '10 minutes'
                then (value->>'balance_usd')::numeric end as usd
    from public.app_config where key = 'herosms_health'
  )
  select jsonb_build_object(
    'window_hours', round(extract(epoch from p_window) / 3600.0, 1),
    'signups',      (select n from sign),
    'purchases',    jsonb_build_object(
                      'count',   (select n from buys),
                      'credits', (select credits from buys)),
    'orders',       jsonb_build_object(
                      'placed',     (select placed from ord),
                      'received',   (select received from ord),
                      'failed',     (select failed from ord),
                      'numberless', (select n from nonum),
                      'pct',      case when (select placed from ord) > 0
                                    then round(100.0 * (select received from ord)
                                                     / (select placed from ord))
                                    else null end,
                      'by_provider', coalesce((
                        select jsonb_agg(jsonb_build_object(
                                 'provider', provider,
                                 'placed',   placed,
                                 'received', received,
                                 'failed',   failed,
                                 'pct', case when placed > 0
                                          then round(100.0 * received / placed)
                                          else null end)
                               order by placed desc)
                        from by_prov), '[]'::jsonb)),
    'esims',        jsonb_build_object(
                      'count',   (select n from esim),
                      'credits', (select credits from esim)),
    'herosms_usd',  (select usd from bal_hero),
    'smspva_usd',   (select usd from bal_pva),
    'smspool_usd',  (select usd from bal_pool)
  );
$function$;

-- Same rule as every other SECURITY DEFINER function here: a passing `revoke`
-- from anon proves nothing while PUBLIC still holds the grant.
revoke execute on function public.ops_snapshot(interval) from public, anon, authenticated;
