-- ops_snapshot: make the operator digest survive the SMSPVA migration.
--
-- Two things went wrong the moment SMS moved from SMSPool to SMSPVA (2026-07-21):
--
--   1. The only balance reported was SMSPool's. SMSPool now funds eSIMs ONLY,
--      so the digest was simultaneously raising a false alarm ("SMSPool $3.50 —
--      top up", read as "SMS is about to die") and hiding the balance that
--      actually gates SMS. A dry SMSPVA account means 100% order failure with
--      nothing anywhere saying so.
--
--   2. Delivery was a single blended number across providers. During a
--      migration that is exactly the number you cannot act on: dead legacy
--      SMSPool orders (~4% delivery) average with live SMSPVA ones (~50%) into
--      a figure that describes neither, and makes a working switch look broken.
--
-- Both balances are now reported, and orders are broken out per provider while
-- the blended totals are kept so the headline stays comparable over time.

create or replace function public.ops_snapshot(p_window interval default '6 hours')
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
  ord as (
    select count(*)::int as placed,
           count(*) filter (where status = 'received')::int as received,
           count(*) filter (where status in ('expired','canceled'))::int as failed
    from scoped
  ),
  -- Per-provider breakdown. Ordered by volume so the provider we actually
  -- depend on leads, and NULL provider is surfaced rather than silently
  -- dropped (an order with no provider is itself a bug worth seeing).
  by_prov as (
    select coalesce(provider, 'unknown') as provider,
           count(*)::int as placed,
           count(*) filter (where status = 'received')::int as received,
           count(*) filter (where status in ('expired','canceled'))::int as failed
    from scoped group by 1
  ),
  esim as (
    select count(*)::int as n, coalesce(sum(cost_credits),0)::int as credits
    from public.esim_orders
    where created_at >= (select t from since) and user_id <> (select id from dev)
  ),
  bal_pool as (
    select (value->>'balance_usd')::numeric as usd
    from public.app_config where key = 'smspool_health'
  ),
  bal_pva as (
    select (value->>'balance_usd')::numeric as usd
    from public.app_config where key = 'smspva_health'
  )
  select jsonb_build_object(
    'window_hours', round(extract(epoch from p_window) / 3600.0, 1),
    'signups',      (select n from sign),
    'purchases',    jsonb_build_object(
                      'count',   (select n from buys),
                      'credits', (select credits from buys)),
    'orders',       jsonb_build_object(
                      'placed',   (select placed from ord),
                      'received', (select received from ord),
                      'failed',   (select failed from ord),
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
    -- Role-labelled, because which provider funds what changed and will change
    -- again. smspool_usd is retained for any older formatter still deployed.
    'smspva_usd',   (select usd from bal_pva),
    'smspool_usd',  (select usd from bal_pool)
  );
$function$;
