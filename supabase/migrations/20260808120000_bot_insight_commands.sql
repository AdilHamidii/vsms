-- Telegram ops bot: three new read-only snapshot functions (/funnel, /delivery,
-- /subs) plus measurement repairs to the two the existing commands already read.
--
-- ── WHAT WAS WRONG, and it was wrong in the same way three times ────────────
--
-- 1. `ops_snapshot.buys` did NOT filter `environment = 'Production'`, so the
--    6-hourly digest and /stats counted Sandbox receipts as purchases. Sandbox
--    receipts are genuine Apple-signed transactions that cost $0 — there is one
--    in the table right now (12 credits, no money) and every digest has been
--    reporting it as a sale. `revenue_snapshot` has always filtered it; the two
--    surfaces disagreed about what a purchase is.
--
-- 2. Both `ops_snapshot` and `orders_recent` computed their delivery rate over
--    EVERY numbered order, cancels included. Measured repeatedly in this repo:
--    ~59-74% of numbered orders are cancelled by the user at a median of 57s
--    while codes land at a median of 58s, and cancelled orders deliver ~1%. So
--    the published rate was mostly a measure of user impatience. This is the
--    same defect that fired the `delivery-collapse` watchdog check on
--    2026-08-01 ("14 conclusive orders, ZERO codes") while non-cancelled
--    delivery was ~73%, and it was fixed there and nowhere else. The cohort is
--    now `status in ('received','expired')`, exactly as `run_watchdog` uses.
--
-- 3. Neither excluded DEFAULT-LANDED orders (`orders.from_default`). Those are
--    the app's own pre-selection: the user never chose that service, never
--    pasted the number anywhere, and no code was ever requested. Settled by
--    hand on 2026-08-04 — a cancelled deliveroo/us number was used manually and
--    the code arrived. Scoring them as failures measures our steering, not the
--    provider. `20260808110000` excluded them from the watchdog; this excludes
--    them from the two surfaces a human actually reads.
--
-- Rules preserved deliberately, do not "simplify" them away:
--   * a delivered code is `otp is not null`, NEVER `status = 'received'` — a
--     rescued code lives on a `canceled` row (there is one in the table today),
--   * orders that never reserved a number are REFUSALS and are counted apart,
--     never inside a delivery rate,
--   * the dev account is excluded from every analytics figure and INCLUDED and
--     flagged in `orders_recent`, because "did my own test order work" is
--     precisely the question /orders answers.
--
-- Everything here is read-only. No UPDATE anywhere: an unqualified UPDATE
-- inside a SECURITY DEFINER function fails over RPC under safeupdate, and a
-- snapshot function has no business writing.

-- ═══════════════════════════════════════════════════════════════════════════
-- ops_snapshot — the digest + /stats + /today + /week
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.ops_snapshot(p_window interval default '06:00:00'::interval)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  with dev as (select '825688de-6117-4251-9f90-93b83b41b572'::uuid as id),
  since as (select now() - p_window as t),
  sign as (
    select count(*)::int as n from auth.users
    where created_at >= (select t from since) and id <> (select id from dev)
  ),
  -- ⚠️ `environment = 'Production'` is MANDATORY and was missing until
  -- 2026-08-08. A Sandbox or Xcode receipt is a real Apple-signed transaction
  -- that moved $0 — any Apple ID can switch to a Sandbox account in Settings
  -- and "buy" a pack free. Counting one as a purchase is how the digest
  -- reported revenue that does not exist. Mirrors revenue_snapshot exactly.
  buys as (
    select count(*)::int as n, coalesce(sum(granted_credits),0)::int as credits
    from public.iap_receipts
    where created_at >= (select t from since) and user_id <> (select id from dev)
      and environment = 'Production'
  ),
  -- Counted, not silently dropped: a burst of Sandbox receipts means somebody
  -- is buying for free, which is worth seeing rather than hiding.
  sandbox as (
    select count(*)::int as n
    from public.iap_receipts
    where created_at >= (select t from since) and user_id <> (select id from dev)
      and environment <> 'Production'
  ),
  scoped as (
    select * from public.orders
    where created_at >= (select t from since) and user_id <> (select id from dev)
  ),
  -- Only orders that actually reserved a number are delivery evidence.
  numbered as (select * from scoped where smspva_number is not null),
  -- THE DELIVERY-RATE COHORT. A user cancel measures impatience, not the
  -- provider; a default-landed order measures our own steering. Both are
  -- reported on their own lines instead.
  settled as (
    select * from numbered
    where status in ('received','expired')
      and coalesce(from_default, false) = false
  ),
  ord as (
    select
      (select count(*) from numbered)::int as placed,
      (select count(*) from settled)::int as settled,
      (select count(*) filter (where otp is not null) from settled)::int as received,
      (select count(*) filter (where otp is null) from settled)::int as failed,
      (select count(*) from numbered where status = 'canceled')::int as cancelled,
      -- A code that landed AFTER the user cancelled. The refund stands and the
      -- code is given away free, so it is a delivery we made and deliberately
      -- not part of the rate.
      (select count(*) from numbered
         where status = 'canceled' and otp is not null)::int as rescued,
      (select count(*) from numbered where status = 'waiting')::int as waiting,
      (select count(*) from numbered
         where coalesce(from_default, false))::int as default_landed
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
           count(*) filter (where status in ('received','expired')
                              and coalesce(from_default,false) = false)::int as settled,
           count(*) filter (where status in ('received','expired')
                              and coalesce(from_default,false) = false
                              and otp is not null)::int as received,
           count(*) filter (where status in ('received','expired')
                              and coalesce(from_default,false) = false
                              and otp is null)::int as failed,
           count(*) filter (where status = 'canceled')::int as cancelled
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
           count(*) filter (where status in ('received','expired'))::int as settled,
           count(*) filter (where status in ('received','expired')
                              and code is not null)::int as received,
           count(*) filter (where status in ('received','expired')
                              and code is null)::int as failed,
           count(*) filter (where status = 'canceled')::int as cancelled,
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
  ),
  -- 5sim buys every SMS order. It was the ONE balance here read without the
  -- freshness gate above, so a dead poller printed its last figure as current
  -- next to two that correctly went blank — the exact "confidently wrong 'all
  -- is well'" failure 20260722050000 fixed for the others.
  bal_five as (
    select case when (value->>'checked_at')::timestamptz >= now() - interval '10 minutes'
                then (value->>'balance_usd')::numeric end as usd
    from public.app_config where key = '5sim_health'
  )
  select jsonb_build_object(
    'window_hours', round(extract(epoch from p_window) / 3600.0, 1),
    'signups',      (select n from sign),
    'purchases',    jsonb_build_object(
                      'count',   (select n from buys),
                      'credits', (select credits from buys),
                      'sandbox', (select n from sandbox)),
    'orders',       jsonb_build_object(
                      'placed',         (select placed from ord),
                      'settled',        (select settled from ord),
                      'received',       (select received from ord),
                      'failed',         (select failed from ord),
                      'cancelled',      (select cancelled from ord),
                      'rescued',        (select rescued from ord),
                      'waiting',        (select waiting from ord),
                      'default_landed', (select default_landed from ord),
                      'numberless',     (select n from nonum),
                      'dev_hidden',     (select n from devord),
                      'pct',      case when (select settled from ord) > 0
                                    then round(100.0 * (select received from ord)
                                                     / (select settled from ord))
                                    else null end,
                      'by_provider', coalesce((
                        select jsonb_agg(jsonb_build_object(
                                 'provider',  provider,
                                 'placed',    placed,
                                 'settled',   settled,
                                 'received',  received,
                                 'failed',    failed,
                                 'cancelled', cancelled,
                                 'pct', case when settled > 0
                                          then round(100.0 * received / settled)
                                          else null end)
                               order by placed desc)
                        from by_prov), '[]'::jsonb)),
    'emails',       jsonb_build_object(
                      'placed',        (select placed from mail),
                      'settled',       (select settled from mail),
                      'received',      (select received from mail),
                      'failed',        (select failed from mail),
                      'cancelled',     (select cancelled from mail),
                      'unprovisioned', (select unprovisioned from mail),
                      'free',          (select free from mail),
                      'credits',       (select credits from mail),
                      'pct',      case when (select settled from mail) > 0
                                    then round(100.0 * (select received from mail)
                                                     / (select settled from mail))
                                    else null end),
    'esims',        jsonb_build_object(
                      'count',   (select n from esim),
                      'credits', (select credits from esim)),
    'herosms_usd',  (select usd from bal_hero),
    'smspva_usd',   (select usd from bal_pva),
    'fivesim_usd',  (select usd from bal_five),
    'smspool_usd',  (select usd from bal_pool)
  );
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- orders_recent — /orders. The ONE surface that INCLUDES the dev account.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.orders_recent(p_window interval default '24:00:00'::interval)
returns jsonb
language sql
security definer
set search_path to 'public'
as $function$
  with o as (
    select
      o.created_at,
      o.status::text                                  as status,
      o.service_id,
      o.country_id,
      coalesce(o.provider, '?')                       as provider,
      o.tier::text                                    as tier,
      o.cost_credits,
      o.actual_cost_cents,
      (o.otp is not null)                             as got_code,
      (o.smspva_number is not null)                   as got_number,
      coalesce(o.from_default, false)                  as from_default,
      (o.user_id = '825688de-6117-4251-9f90-93b83b41b572'::uuid) as is_dev,
      extract(epoch from (coalesce(o.closed_at, now()) - o.created_at))::int as held_s
    from public.orders o
    where o.created_at >= now() - p_window
  )
  select jsonb_build_object(
    'total',      (select count(*) from o),
    'numbered',   (select count(*) from o where got_number),
    'delivered',  (select count(*) from o where got_code),
    'waiting',    (select count(*) from o where status = 'waiting'),
    'cancelled',  (select count(*) from o where status = 'canceled'),
    'expired',    (select count(*) from o where status = 'expired'),
    -- THE RATE COHORT, and it is not `numbered`. A user cancel measures
    -- impatience (median 57s against a median 58s arrival, ~1% delivery), and a
    -- default-landed order measures our own pre-selection rather than the
    -- provider. Both are reported separately below.
    'settled',    (select count(*) from o
                    where got_number and status in ('received','expired')
                      and not from_default),
    'settled_codes', (select count(*) from o
                    where got_number and status in ('received','expired')
                      and not from_default and got_code),
    -- A code that arrived after the user cancelled. Refund stood, code given
    -- away free. A delivery we made, deliberately outside the rate.
    'rescued',    (select count(*) from o
                    where got_number and status = 'canceled' and got_code),
    'default_landed', (select count(*) from o where got_number and from_default),
    -- Orders that never held a number closed inside create-order (stockout,
    -- margin_too_low, provider fault). They are charge-and-refund events, not
    -- delivery failures, and must be counted apart or they drag the rate down.
    'no_number',  (select count(*) from o where not got_number and status <> 'waiting'),
    'spend_cents',(select coalesce(sum(actual_cost_cents), 0) from o),
    'rows',       (select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb)
                     from o x),
    'email',      (select jsonb_build_object(
                     'total', count(*),
                     'received', count(*) filter (where code is not null))
                   from public.email_orders where created_at >= now() - p_window),
    'esim',       (select jsonb_build_object('total', count(*))
                   from public.esim_orders where created_at >= now() - p_window)
  );
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- ops_funnel — /funnel [7d|14d|30d]
--
-- Per-day activity plus the two cohort rates that actually decide whether the
-- product is working. Both rates are COHORT rates over the signups in the
-- window (did the people who arrived go on to order / to pay), not
-- ratio-of-totals — a window containing yesterday's buyers and today's signups
-- would otherwise report a made-up number. Activation is a single-session
-- event here (median signup -> first order 123s), so "ever ordered" and
-- "ordered in the window" are the same population in practice.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.ops_funnel(p_window interval default '7 days')
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  with dev as (select '825688de-6117-4251-9f90-93b83b41b572'::uuid as id),
  -- Whole UTC days, so a row is always a full day and the newest row is today
  -- so far. Clamped to 1..90 days: /funnel prints one line per day.
  ndays as (
    select least(90, greatest(1,
      round(extract(epoch from p_window) / 86400.0)::int)) as n
  ),
  days as (
    select generate_series(
             (current_date - ((select n from ndays) - 1)),
             current_date, interval '1 day')::date as d
  ),
  t0 as (select (select min(d) from days)::timestamptz as t),
  -- The cohort: everyone who signed up inside the window.
  cohort as (
    select id as user_id from auth.users
    where created_at >= (select t from t0) and id <> (select id from dev)
  ),
  per_day as (
    select d,
      (select count(*)::int from auth.users u
         where u.created_at >= d and u.created_at < d + 1
           and u.id <> (select id from dev))                        as signups,
      (select count(distinct o.user_id)::int from public.orders o
         where o.created_at >= d and o.created_at < d + 1
           and o.user_id <> (select id from dev))                   as users_ordering,
      (select count(*)::int from public.orders o
         where o.created_at >= d and o.created_at < d + 1
           and o.user_id <> (select id from dev))                   as orders,
      (select count(*)::int from public.orders o
         where o.created_at >= d and o.created_at < d + 1
           and o.user_id <> (select id from dev)
           and o.smspva_number is not null)                         as numbered,
      -- `otp is not null` is the only authority on "a code arrived" — a rescued
      -- code lives on a canceled row, so status would score it a failure.
      (select count(*)::int from public.orders o
         where o.created_at >= d and o.created_at < d + 1
           and o.user_id <> (select id from dev)
           and o.otp is not null)                                   as codes,
      -- Production only. A Sandbox receipt is Apple-signed and cost $0.
      (select count(*)::int from public.iap_receipts r
         where r.created_at >= d and r.created_at < d + 1
           and r.user_id <> (select id from dev)
           and r.environment = 'Production')                        as buys,
      (select coalesce(sum(r.granted_credits),0)::int from public.iap_receipts r
         where r.created_at >= d and r.created_at < d + 1
           and r.user_id <> (select id from dev)
           and r.environment = 'Production')                        as credits
    from days
  ),
  activated as (
    select count(*)::int as n from cohort c
    where exists (select 1 from public.orders o where o.user_id = c.user_id)
  ),
  buyers as (
    select count(*)::int as n from cohort c
    where exists (select 1 from public.iap_receipts r
                   where r.user_id = c.user_id and r.environment = 'Production'
                     and coalesce(r.granted_credits, 0) > 0)
  ),
  -- Read LIVE, never hardcoded. The grant has been 5, 0, 1, 3, 0 and 2 within
  -- days, and every client constant derived from it has been wrong at least
  -- once. A MISSING row is reported as missing, not as zero.
  grant_cfg as (
    select case
             when jsonb_typeof(value) = 'number' then (value::text)::int
             when value ? 'credits'              then (value->>'credits')::int
             else null
           end as credits
    from public.app_config where key = 'signup_bonus_credits'
  ),
  dflt as (
    select count(*)::int as n from public.orders
    where created_at >= (select t from t0)
      and user_id <> (select id from dev)
      and coalesce(from_default, false)
  )
  select jsonb_build_object(
    'days',    (select n from ndays),
    'since',   (select t from t0),
    'rows',    coalesce((select jsonb_agg(jsonb_build_object(
                  'd', d, 'signups', signups, 'users_ordering', users_ordering,
                  'orders', orders, 'numbered', numbered, 'codes', codes,
                  'buys', buys, 'credits', credits) order by d)
                from per_day), '[]'::jsonb),
    'totals',  jsonb_build_object(
                  'signups',        (select count(*)::int from cohort),
                  'activated',      (select n from activated),
                  'buyers',         (select n from buyers),
                  'orders',         (select coalesce(sum(orders),0)::int from per_day),
                  'numbered',       (select coalesce(sum(numbered),0)::int from per_day),
                  'codes',          (select coalesce(sum(codes),0)::int from per_day),
                  'buys',           (select coalesce(sum(buys),0)::int from per_day),
                  'credits',        (select coalesce(sum(credits),0)::int from per_day),
                  'default_landed', (select n from dflt)),
    'signup_grant', (select credits from grant_cfg)
  );
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- ops_delivery — /delivery [24h|7d|30d]
--
-- Per provider, because a blended rate averages a dead provider with a live one
-- and describes neither (it read 10% while the live provider was at 43%).
-- Every rate here is over non-cancelled, non-default-landed numbered orders.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.ops_delivery(p_window interval default '7 days')
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  with dev as (select '825688de-6117-4251-9f90-93b83b41b572'::uuid as id),
  since as (select now() - p_window as t),
  scoped as (
    select * from public.orders
    where created_at >= (select t from since) and user_id <> (select id from dev)
  ),
  by_prov as (
    select coalesce(provider, 'unknown') as provider,
      count(*) filter (where smspva_number is not null)::int as numbered,
      count(*) filter (where smspva_number is not null
                         and status in ('received','expired')
                         and coalesce(from_default,false) = false)::int as settled,
      count(*) filter (where smspva_number is not null
                         and status in ('received','expired')
                         and coalesce(from_default,false) = false
                         and otp is not null)::int as codes,
      count(*) filter (where smspva_number is not null
                         and status = 'canceled')::int as cancelled,
      count(*) filter (where smspva_number is not null
                         and status = 'canceled' and otp is not null)::int as rescued,
      count(*) filter (where smspva_number is not null
                         and status = 'waiting')::int as waiting,
      count(*) filter (where smspva_number is not null
                         and coalesce(from_default,false))::int as default_landed,
      -- Never reserved a number: died inside create-order on stockout,
      -- margin_too_low, or a provider fault. Charged and refunded, and NOT a
      -- delivery failure — which is why it has its own column.
      count(*) filter (where smspva_number is null
                         and status <> 'waiting')::int as refusals
    from scoped group by 1
  ),
  tot as (
    select coalesce(sum(numbered),0)::int as numbered,
           coalesce(sum(settled),0)::int as settled,
           coalesce(sum(codes),0)::int as codes,
           coalesce(sum(cancelled),0)::int as cancelled,
           coalesce(sum(rescued),0)::int as rescued,
           coalesce(sum(waiting),0)::int as waiting,
           coalesce(sum(default_landed),0)::int as default_landed,
           coalesce(sum(refusals),0)::int as refusals
    from by_prov
  ),
  wd as (select value as v from public.app_config where key = 'watchdog'),
  -- SMSPVA routes the reservation-collapse guard is currently holding shut.
  -- Kept visible because it is 7k+ rows of catalog that a resync could reopen,
  -- and because "the catalog looks small" has to have a legible cause.
  hidden as (
    select count(*)::int as n from public.routes
    where provider = 'smspva' and status = 'hidden'
  ),
  -- One row per SMS provider, ALWAYS all three. A missing reading must render
  -- as "no reading" — an omitted line reads as healthy, which is exactly the
  -- failure that hid SMSPVA having no monitoring at all while it served 100%
  -- of SMS. Freshness is left to the formatter so it can say WHICH it is.
  bals as (
    select * from (values ('5sim','5sim_health'),
                          ('herosms','herosms_health'),
                          ('smspva','smspva_health')) as p(name, key)
  )
  select jsonb_build_object(
    'window_hours', round(extract(epoch from p_window) / 3600.0, 1),
    'by_provider', coalesce((
      select jsonb_agg(jsonb_build_object(
        'provider', provider, 'numbered', numbered, 'settled', settled,
        'codes', codes, 'cancelled', cancelled, 'rescued', rescued,
        'waiting', waiting, 'default_landed', default_landed,
        'refusals', refusals,
        'pct', case when settled > 0 then round(100.0 * codes / settled) end)
        order by numbered desc, refusals desc)
      from by_prov), '[]'::jsonb),
    'totals', (select jsonb_build_object(
        'numbered', numbered, 'settled', settled, 'codes', codes,
        'cancelled', cancelled, 'rescued', rescued, 'waiting', waiting,
        'default_landed', default_landed, 'refusals', refusals,
        'pct', case when settled > 0 then round(100.0 * codes / settled) end)
      from tot),
    'watchdog', jsonb_build_object(
        'failing',    coalesce((select v->'failing' from wd), '[]'::jsonb),
        'checked_at', (select v->>'checked_at' from wd)),
    'smspva_hidden_routes', (select n from hidden),
    'balances', coalesce((
      select jsonb_agg(jsonb_build_object(
        'provider', b.name,
        'balance_usd', (c.value->>'balance_usd')::numeric,
        'checked_at',  c.value->>'checked_at') order by b.name)
      from bals b left join public.app_config c on c.key = b.key), '[]'::jsonb)
  );
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- ops_subs — /subs, the Second Number line
--
-- Everything here is currently zero and that is the point: this is the product
-- whose lifecycle shipped with `reclaim_lapsed_lines()` scheduled in no cron
-- job and `release-lines` never written, costing $1/month per cancelled
-- subscriber forever, discoverable only on the Telnyx invoice. A standing view
-- of subscription state against LINE state is how that divergence becomes
-- visible without opening a SQL console.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.ops_subs()
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  with dev as (select '825688de-6117-4251-9f90-93b83b41b572'::uuid as id),
  subs as (
    select * from public.line_subscriptions where user_id <> (select id from dev)
  ),
  lns as (
    select * from public.phone_lines where user_id <> (select id from dev)
  ),
  sub_states as (
    select state::text as state, count(*)::int as n from subs group by 1
  ),
  line_states as (
    select status::text as status, count(*)::int as n from lns group by 1
  ),
  -- `billing` splits Apple subscriptions from credit-billed rentals
  -- (20260806160000). Only the Apple half produces the MRR below, so a
  -- credit-billed line must not be counted into it.
  line_billing as (
    select billing, count(*)::int as n from lns group by 1
  ),
  active_subs as (select count(*)::int as n from subs where state = 'active'),
  -- What Apple actually billed, per currency, for the ACTIVE subscriptions.
  -- Printed next to the list-price estimate for the same reason /revenue prints
  -- the FX rate: the estimate must be auditable rather than asserted.
  active_billed as (
    select coalesce(currency,'?') as currency,
           sum(price_milli)::bigint as milli, count(*)::int as n
    from subs where state = 'active' and price_milli is not null
    group by 1
  ),
  notifs as (
    select notification_type, coalesce(subtype,'') as subtype, count(*)::int as n,
           count(*) filter (where processed_at is null)::int as unprocessed,
           count(*) filter (where process_error is not null)::int as errored
    from public.line_notifications
    where created_at >= now() - interval '7 days'
    group by 1, 2
  ),
  telnyx as (select value as v from public.app_config where key = 'telnyx_health'),
  devl as (
    select (select count(*)::int from public.phone_lines
              where user_id = (select id from dev)) as lines,
           (select count(*)::int from public.line_subscriptions
              where user_id = (select id from dev)) as subs
  )
  select jsonb_build_object(
    'subs_total',   (select count(*)::int from subs),
    'subs_active',  (select n from active_subs),
    'subs_by_state', coalesce((select jsonb_agg(jsonb_build_object(
                        'state', state, 'n', n) order by n desc, state)
                      from sub_states), '[]'::jsonb),
    'lines_total',  (select count(*)::int from lns),
    'lines_by_status', coalesce((select jsonb_agg(jsonb_build_object(
                        'status', status, 'n', n) order by n desc, status)
                      from line_states), '[]'::jsonb),
    'lines_by_billing', coalesce((select jsonb_agg(jsonb_build_object(
                        'billing', billing, 'n', n) order by n desc, billing)
                      from line_billing), '[]'::jsonb),
    'monthly_cost_cents', (select coalesce(sum(monthly_cost_cents),0)::int from lns
                             where status in ('active','grace','past_due','provisioning','releasing')),
    -- ⚠️ There is NO trial state and no offer-type column on
    -- line_subscriptions: `line_sub_state` is (active, grace, billing_retry,
    -- expired, revoked, canceled_pending) and ASSN's `offerType` is not
    -- persisted. Reported as untracked rather than silently rendered as zero
    -- trials, which would be an assertion we cannot make.
    'trials_tracked', false,
    'active_billed', coalesce((select jsonb_agg(jsonb_build_object(
                        'currency', currency, 'milli', milli, 'n', n)
                        order by milli desc) from active_billed), '[]'::jsonb),
    'notifications_7d', coalesce((select jsonb_agg(jsonb_build_object(
                        'type', notification_type, 'subtype', subtype, 'n', n,
                        'unprocessed', unprocessed, 'errored', errored)
                        order by n desc, notification_type)
                      from notifs), '[]'::jsonb),
    'telnyx', jsonb_build_object(
                'balance_usd', (select (v->>'balance_usd')::numeric from telnyx),
                'checked_at',  (select v->>'checked_at' from telnyx)),
    'dev_hidden', jsonb_build_object(
                'lines', (select lines from devl),
                'subs',  (select subs from devl))
  );
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- ACLs.
--
-- `CREATE FUNCTION` grants EXECUTE to PUBLIC by default, and anon/authenticated
-- are members of PUBLIC — so revoking from those two alone is a NO-OP while
-- PUBLIC still holds the grant, and the function stays callable at
-- /rest/v1/rpc/<name> with nothing but the publishable key. That is how
-- `revenue_snapshot` shipped world-callable WITH its revoke line, publishing
-- gross revenue and wholesale cost to anyone. PUBLIC first, every time.
-- Assert with has_function_privilege('anon', oid, 'execute') afterwards; a
-- passing revoke statement proves nothing.
-- ═══════════════════════════════════════════════════════════════════════════

revoke execute on function public.ops_snapshot(interval) from public, anon, authenticated;
revoke execute on function public.orders_recent(interval) from public, anon, authenticated;
revoke execute on function public.ops_funnel(interval)   from public, anon, authenticated;
revoke execute on function public.ops_delivery(interval) from public, anon, authenticated;
revoke execute on function public.ops_subs()             from public, anon, authenticated;

comment on function public.ops_funnel(interval) is
  'Per-day signup->order->code->purchase funnel for /funnel. Cohort activation '
  'and buyer rates over signups in the window; Production receipts only; dev '
  'account excluded; default-landed orders counted separately.';
comment on function public.ops_delivery(interval) is
  'Per-provider delivery for /delivery. Rate is over non-cancelled, '
  'non-default-landed numbered orders; refusals (never got a number) counted '
  'apart. Carries the watchdog verdict and one balance row per SMS provider.';
comment on function public.ops_subs() is
  'Second Number line state for /subs: subscriptions by state, lines by status '
  'and billing, ASSN notifications over 7d, Telnyx balance. No trial state '
  'exists in the schema, so trials are reported as untracked, never as zero.';
