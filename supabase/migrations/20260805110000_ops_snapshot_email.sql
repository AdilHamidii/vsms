-- Add the temp-EMAIL line to ops_snapshot (owner request, 2026-08-05).
--
-- Email has been live since 2026-07-30 and was invisible in every ops surface:
-- the 6-hourly digest, /stats, /today and /week all render formatDigest, which
-- read only `orders` and `esims`. This file's own third-product-line checklist
-- has listed that as outstanding since the line shipped. 29 orders from 10
-- users happened with no operational view of any of it.
--
-- SHAPE MIRRORS `orders` DELIBERATELY, including the part that looks like an
-- oddity: SMS excludes orders that never reserved a number from `placed` and
-- reports them separately as `numberless`, because a charge-and-refund that
-- never held a number is not delivery evidence. Email has the exact analogue --
-- `status = 'failed'` means create-email-order never provisioned a usable
-- address -- so it is excluded from `placed` and surfaced as `unprovisioned`.
-- Folding those into the failure rate would blame the mailbox for something
-- that happened before a mailbox existed.
--
-- That case is NOT hypothetical: 7 of the 29 email orders to date are `failed`,
-- five of them one user retrying TikTok five times between 05:45 and 05:52 on
-- 2026-08-05. Under a naive rate that reads as "email delivers 24%"; separated,
-- it reads as "76% of provisioned mailboxes never got a code AND a quarter of
-- attempts never got a mailbox at all", which are two different problems.
--
-- `received` is `code is not null`, NEVER `status = 'received'` -- the standing
-- rule on both other product lines, and the one that stops a rescued code being
-- scored as a failure.
--
-- `free` is broken out because 28 of the first 29 orders were the free tier, so
-- a bare order count reads as revenue when it is almost entirely cost.
--
-- Everything outside the two new CTEs and the one new jsonb key is byte-identical
-- to the previous definition (diffed clause by clause, per the "a one-line
-- refactor that changes a watchdog threshold is a monitoring outage" rule).

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

-- The function is SECURITY DEFINER and must stay off the public API. A bare
-- `revoke ... from anon, authenticated` is a NO-OP while PUBLIC holds the
-- default grant, so revoke from PUBLIC explicitly and assert it.
revoke execute on function public.ops_snapshot(interval) from public, anon, authenticated;

do $$
declare
  v_leak int;
  v_placed int;
begin
  select count(*) into v_leak
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'ops_snapshot'
     and (has_function_privilege('anon', p.oid, 'execute')
          or has_function_privilege('authenticated', p.oid, 'execute'));
  if v_leak <> 0 then
    raise exception 'ops_snapshot is still callable by anon/authenticated';
  end if;

  -- The key must exist and be an object, or formatDigest silently renders
  -- nothing -- the exact failure mode that made the digest print
  -- "5sim: no reading" for a week.
  if (public.ops_snapshot('720 hours'::interval) -> 'emails') is null then
    raise exception 'ops_snapshot returned no emails key';
  end if;
  select (public.ops_snapshot('720 hours'::interval) -> 'emails' ->> 'placed')::int
    into v_placed;
  raise notice 'ops_snapshot emails.placed over 30d = %', v_placed;
end $$;
