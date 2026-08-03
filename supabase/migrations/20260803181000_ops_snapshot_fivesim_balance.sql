-- ops_snapshot must emit fivesim_usd, or the digest lies by omission.
--
-- I changed _shared/opsFormat.ts's formatDigest to print balanceLine("5sim",
-- s.fivesim_usd) when the balance block was trimmed to the two providers that
-- still fund something -- but ops_snapshot never emitted that key. The result
-- is a permanent "5sim (SMS): no reading" on the one channel that reports
-- whether the provider buying every SMS order can still pay for numbers.
-- Regression introduced the same day; one hunk, sourced exactly like the other
-- three balances.
CREATE OR REPLACE FUNCTION public.ops_snapshot(p_window interval DEFAULT '06:00:00'::interval)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      -- 5sim buys every SMS order. Added 2026-08-03: formatDigest was changed
      -- to read s.fivesim_usd before this key existed, so the 6-hourly digest
      -- printed '5sim: no reading' permanently -- an absent balance line is
      -- exactly the failure that once hid SMSPVA having no monitoring at all.
      'fivesim_usd',  (select (value->>'balance_usd')::numeric
                         from public.app_config where key = '5sim_health'),
    'smspool_usd',  (select usd from bal_pool)
  );
$function$
;
