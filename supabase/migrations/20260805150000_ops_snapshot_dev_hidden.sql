-- Make the digest say WHY "Numbers: none ordered" is empty (owner report, 2026-08-05).
--
-- ops_snapshot has always excluded the dev account from every figure, which is
-- correct for an analytics view -- but it means that when the owner tests the
-- app themselves and nobody else orders, /stats reads "Numbers: none ordered"
-- with no hint that an order happened. That is indistinguishable from "the
-- product is dead", and it cost real time today: an owner watching their own
-- test order vanish from /stats while purchases and signups showed up fine.
--
-- Same principle this file already applies to balances: "a missing reading
-- renders as 'no reading', never omitted -- an absent line reads as healthy".
-- Silence that means something must say what it means.
--
-- `dev_hidden` counts dev orders in the window. It is NOT added to any figure;
-- every rate, count and by_provider row is byte-identical to before. Only the
-- formatter changes what it prints.
--
-- Note /orders already includes the dev account and flags it `dev` -- that is
-- the command for "did my test order work". This only fixes the silence in the
-- aggregate view.

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
  -- Orders the dev account placed in this window. EXCLUDED from every figure
  -- above, as they always have been -- but counted, so "none ordered" can say
  -- WHY it is empty instead of reading as "the product is dead".
  devord as (
    select count(*)::int as n from public.orders
    where created_at >= (select t from since) and user_id = (select id from dev)
  ),
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
  -- ── temp EMAIL, same evidence rules as SMS above ────────────────────────
  mail_scoped as (
    select * from public.email_orders
    where created_at >= (select t from since) and user_id <> (select id from dev)
  ),
  mail as (
    select count(*) filter (where status <> 'failed')::int as placed,
           count(*) filter (where code is not null)::int as received,
           count(*) filter (where code is null
                              and status in ('expired','canceled'))::int as failed,
           count(*) filter (where status = 'failed')::int as unprovisioned,
           count(*) filter (where status <> 'failed'
                              and cost_credits = 0)::int as free,
           coalesce(sum(cost_credits),0)::int as credits
    from mail_scoped
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
                      'dev_hidden', (select n from devord),
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
    'emails',       jsonb_build_object(
                      'placed',        (select placed from mail),
                      'received',      (select received from mail),
                      'failed',        (select failed from mail),
                      'unprovisioned', (select unprovisioned from mail),
                      'free',          (select free from mail),
                      'credits',       (select credits from mail),
                      'pct',      case when (select placed from mail) > 0
                                    then round(100.0 * (select received from mail)
                                                     / (select placed from mail))
                                    else null end),
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
$function$;

-- SECURITY DEFINER: keep it off the public API. A bare revoke from
-- anon/authenticated is a no-op while PUBLIC holds the default grant.
revoke execute on function public.ops_snapshot(interval) from public, anon, authenticated;

do $$
declare
  v_leak int;
  v_snap jsonb;
begin
  select count(*) into v_leak
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'ops_snapshot'
     and (has_function_privilege('anon', p.oid, 'execute')
          or has_function_privilege('authenticated', p.oid, 'execute'));
  if v_leak <> 0 then
    raise exception 'ops_snapshot is still callable by anon/authenticated';
  end if;

  v_snap := public.ops_snapshot('12 hours'::interval);

  if (v_snap -> 'orders' ->> 'dev_hidden') is null then
    raise exception 'dev_hidden missing from ops_snapshot';
  end if;
  -- The keys added earlier today must survive this rebuild.
  if (v_snap -> 'emails') is null then
    raise exception 'emails key lost in rebuild';
  end if;
  if (v_snap -> 'esims') is null then
    raise exception 'esims key lost in rebuild';
  end if;

  raise notice 'dev_hidden over 12h = %, real placed = %',
    v_snap -> 'orders' ->> 'dev_hidden', v_snap -> 'orders' ->> 'placed';
end $$;
