-- Red-team audit fixes, 2026-07-31. Four independent silent failures, each
-- verified against live data before being touched. None of these threw an
-- error; every one of them reported success while doing nothing (or doing it
-- for the wrong provider).
--
--   1. refresh_arrival_timing measured ONLY SMSPVA and stamped that band onto
--      all 268 services, including every HeroSMS-served one.
--   2. stranded_credit_candidates was still gated on a delivery rate that
--      reads the minority provider, so the cohort was permanently empty.
--   3. begin_email_order counted FAILED free orders against the daily cap.
--   4. email_orders had no expiry sweep at all — the documented known-open.
--
-- Plus watchdog coverage for sync-herosms (which owns the provider that now
-- serves demand and had no freshness check) and the new email sweep.

-- ─────────────────────────────────────────────────────────────────────────
-- 1. Arrival timing must describe the provider that serves the NEXT order
-- ─────────────────────────────────────────────────────────────────────────
-- `active_sms_provider()` votes by active route count. After the per-service
-- split, and after sync-herosms hid what HeroSMS cannot serve, SMSPVA holds
-- 7,757 active routes against HeroSMS's ~5,000 — so the vote returns the
-- provider that STOPPED serving the demand. Measured 2026-07-31: 38 of the 46
-- arrivals in the trailing 30 days are SMSPVA, 5 HeroSMS, 3 retired smspool;
-- the function counted 38 and discarded the rest.
--
-- `20260730230000` already fixed this class of bug for the route/service/
-- country refreshes by routing them through refresh_evidence_all_providers().
-- refresh_arrival_timing is a SEPARATE entry in sync-prices' maintenance list,
-- outside that wrapper, and kept consuming the known-wrong vote. CLAUDE.md's
-- claim that active_sms_provider() "is no longer load-bearing" was true only
-- of the wrapped refreshes.
--
-- The fix is the same predicate the wrapped refreshes use: an order counts only
-- if its provider STILL OWNS that service. Both live providers are included and
-- retired ones (smspool, virtualsms) drop out by construction — so this needs
-- no provider argument and cannot be pointed at the wrong one again.
create or replace function public.refresh_arrival_timing(
  p_lookback interval default '30 days'::interval,
  p_hold_seconds integer default 120,
  p_min_service integer default 8,
  p_min_p90 integer default 20,
  p_min_global integer default 20,
  p_provider text default null::text)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  g_n int; g_p50 int; g_p90 int; g_hold int; v_updated int;
begin
  -- Staleness is worse than absence: wipe every row we own before rewriting, so
  -- a provider switch degrades to "say nothing" rather than to yesterday's
  -- numbers describing a provider we no longer use.
  update public.services
     set arrival_p50_seconds = null, arrival_p90_seconds = null,
         arrival_sample = null, arrival_scope = null, arrival_hold_pct = null
   where arrival_scope is not null;

  select count(*),
         ceil(percentile_cont(0.5) within group (order by secs))::int,
         ceil(percentile_cont(0.9) within group (order by secs))::int,
         round(100.0 * count(*) filter (where secs <= p_hold_seconds)
               / nullif(count(*), 0))::int
    into g_n, g_p50, g_p90, g_hold
  from (
    select extract(epoch from (o.arrived_at - o.created_at))::numeric as secs
      from public.orders o
     where o.arrived_at is not null
       and o.arrived_at > o.created_at
       and o.created_at >= now() - p_lookback
       and o.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
       -- p_provider is honoured when passed (diagnostics), but the DEFAULT is
       -- every provider that still owns the service. Never active_sms_provider().
       and (p_provider is null or o.provider = p_provider)
       and exists (select 1 from public.routes r
                    where r.service_id = o.service_id
                      and r.provider = o.provider
                      and r.status = 'active')
  ) d;

  -- No honest claim available anywhere: leave everything NULL and stay silent.
  if coalesce(g_n, 0) < p_min_global then
    return 0;
  end if;

  update public.services
     set arrival_p50_seconds = g_p50,
         arrival_p90_seconds = case when g_n >= p_min_p90 then g_p90 end,
         arrival_sample      = g_n,
         arrival_scope       = 'global',
         arrival_hold_pct    = g_hold
   where id is not null;   -- deliberate table-wide UPDATE; safeupdate needs a WHERE

  -- Services with enough of their own deliveries overwrite the global band.
  with per as (
    select o.service_id,
           count(*) as n,
           ceil(percentile_cont(0.5) within group
                (order by extract(epoch from (o.arrived_at - o.created_at))))::int as p50,
           ceil(percentile_cont(0.9) within group
                (order by extract(epoch from (o.arrived_at - o.created_at))))::int as p90,
           round(100.0 * count(*) filter (
                   where extract(epoch from (o.arrived_at - o.created_at)) <= p_hold_seconds)
                 / count(*))::int as hold
      from public.orders o
     where o.arrived_at is not null
       and o.arrived_at > o.created_at
       and o.created_at >= now() - p_lookback
       and o.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
       and (p_provider is null or o.provider = p_provider)
       and exists (select 1 from public.routes r
                    where r.service_id = o.service_id
                      and r.provider = o.provider
                      and r.status = 'active')
     group by o.service_id
    having count(*) >= p_min_service
  ),
  upd as (
    update public.services s
       set arrival_p50_seconds = per.p50,
           arrival_p90_seconds = case when per.n >= p_min_p90 then per.p90 end,
           arrival_sample      = per.n,
           arrival_scope       = 'service',
           arrival_hold_pct    = per.hold
      from per where s.id = per.service_id
    returning 1
  )
  select count(*) into v_updated from upd;

  return v_updated;
end;
$function$;

revoke execute on function public.refresh_arrival_timing(interval, integer, integer, integer, integer, text)
  from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 2. stranded_credit_candidates — remove the dead delivery-rate gate
-- ─────────────────────────────────────────────────────────────────────────
-- The gate `recent_sms_delivery_rate() >= 40` was already documented as
-- REPLACED by a liveness check (provider balance + a fresh, clean watchdog).
-- That replacement shipped in winback/index.ts (`claimSafe`) — but the SQL
-- predicate it replaced was never deleted, so the two ran in series and the
-- SQL one was shut.
--
-- Verified 2026-07-31: recent_sms_delivery_rate() returns NULL, because it
-- scopes to active_sms_provider() = smspva, which had 4 conclusive orders in
-- 48h against a p_min_sample of 5 — while HeroSMS had 6 in the same window.
-- coalesce(NULL,0) >= 40 is false, so the cohort returned 0 rows and could
-- never reopen: SMSPVA's share only shrinks as the split matures.
--
-- Deleting the predicate rather than re-scoping it is deliberate. The edge
-- function's liveness check is strictly better — it asks "can we serve an
-- order right now", which is the actual precondition for telling someone their
-- credits are still usable, and it does not need a delivery sample to answer.
create or replace function public.stranded_credit_candidates(p_limit integer default 100)
returns table(user_id uuid, balance integer)
language sql
stable security definer
set search_path to 'public'
as $function$
  select w.user_id, w.balance
  from public.wallets w
  join lateral (
    select o.status, o.otp
    from public.orders o
    where o.user_id = w.user_id
    order by o.created_at desc
    limit 1
  ) last_order on true
  join public.profiles p on p.user_id = w.user_id
  where w.balance > 0
    and last_order.status in ('expired', 'canceled')
    and last_order.otp is null          -- a rescued code is NOT a failure
    and p.stranded_nudge_sent_at is null
    and w.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
    and not exists (
      select 1 from public.orders o2
      where o2.user_id = w.user_id and o2.created_at >= now() - interval '24 hours')
    and exists (select 1 from public.push_devices d where d.user_id = w.user_id)
  limit p_limit;
$function$;

revoke execute on function public.stranded_credit_candidates(integer)
  from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 3. A FAILED free e-mail order must not burn the daily allowance
-- ─────────────────────────────────────────────────────────────────────────
-- The cap counted ROWS with cost_credits = 0 and no status predicate, and
-- failEmail() leaves failed rows in place. So every failure AFTER the row is
-- inserted — provider stockout at buy time, purchase failure, unreachable
-- provider, persist failure, the 30s buy timeout — consumed one of the user's
-- three free addresses.
--
-- That lands on exactly the wrong tier: the free pair is the scarcest inventory
-- we sell (hotmail.com measured TWO available for discord.com in one sweep), so
-- a stockout mid-buy is the EXPECTED failure, not an exotic one. Three dry taps
-- and the user is told "you've used today's free addresses" having received
-- nothing — on the product whose entire purpose is acquiring users.
--
-- The paid path already gets this right (`delete from email_orders` on
-- insufficient funds), which is what makes this a miss rather than a decision.
create or replace function public.begin_email_order(
  p_user uuid, p_service text, p_site text, p_domain text, p_credits integer)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_existing uuid; v_order uuid; v_ok boolean;
  v_free_today integer; v_cap integer;
begin
  if p_credits is null or p_credits < 0 then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  perform pg_advisory_xact_lock(hashtext(p_user::text));

  select id into v_existing from public.email_orders
   where user_id = p_user and site = p_site and domain = p_domain
     and status = 'waiting' and created_at > now() - interval '2 minutes'
   limit 1;
  if v_existing is not null then
    return jsonb_build_object('ok', false, 'reason', 'duplicate_request');
  end if;

  if p_credits = 0 then
    select coalesce((value #>> '{}')::integer, 3) into v_cap
      from public.app_config where key = 'email_free_daily_cap';
    v_cap := coalesce(v_cap, 3);
    select count(*) into v_free_today from public.email_orders
     where user_id = p_user and cost_credits = 0
       and status <> 'failed'            -- a non-order does not count
       and created_at >= date_trunc('day', now() at time zone 'utc');
    if v_free_today >= v_cap then
      return jsonb_build_object('ok', false, 'reason', 'free_limit_reached', 'cap', v_cap);
    end if;
  end if;

  insert into public.email_orders (user_id, service_id, site, domain, cost_credits, status)
  values (p_user, p_service, p_site, p_domain, p_credits, 'waiting')
  returning id into v_order;

  if p_credits > 0 then
    select public.wallet_spend(p_user, p_credits, 'spend', null) into v_ok;
    if not coalesce(v_ok, false) then
      delete from public.email_orders where id = v_order;
      return jsonb_build_object('ok', false, 'reason', 'insufficient');
    end if;
    update public.wallet_transactions set email_order_id = v_order
     where id = (select id from public.wallet_transactions
                  where user_id = p_user and reason = 'spend' and email_order_id is null
                  order by created_at desc, id desc limit 1);
  end if;

  return jsonb_build_object('ok', true, 'order_id', v_order);
end;
$function$;

revoke execute on function public.begin_email_order(uuid, text, text, text, integer)
  from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 4. The missing e-mail expiry sweep
-- ─────────────────────────────────────────────────────────────────────────
-- email_orders has never had one. The consequences are worse than "the refund
-- waits for the next poll", because the three paths that were supposed to cover
-- for it all dead-end:
--
--   * check-email-order deliberately refuses to invent a terminal state on a
--     provider fault, delegating expiry to "the cron sweep" — which does not
--     exist. So for an activation the provider has forgotten (404), the local
--     22-minute expiry sits BEHIND a successful provider read and is
--     unreachable for exactly the rows that need it.
--   * ResumeBar's email branch has no age bound (the SMS branch does), so one
--     abandoned order pins "Waiting for a code" above the tab bar on every tab,
--     permanently.
--   * email_orders.expires_at is a dead column — nothing has ever written it.
--     A sweep copied from expire_esim_orders(), which keys on expires_at, would
--     match zero rows and look like a working deploy.
--
-- So this keys on created_at + 22 minutes, matching EMAIL_WINDOW_SECONDS in
-- _shared/emailStatus.ts. The two must not disagree: shorter here would close a
-- row the client still renders as live.
--
-- Nothing is reclaimed from the provider on purpose. HeroSMS auto-expires and
-- refunds US at ~21 minutes (measured by holding one to its natural end), so
-- there is no wholesale to recover and therefore no reason to make this an
-- edge function. Plain SQL means it still evaluates when the edge/secret layer
-- is broken — the same rationale as run_watchdog.
create or replace function public.expire_email_orders()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_n integer := 0;
  r record;
begin
  for r in
    with claimed as (
      update public.email_orders
         -- Explicit cast: a CASE yields text, and Postgres will not implicitly
         -- coerce that to email_status in an UPDATE SET. Without it the whole
         -- function raises 42804 on every run.
         set status     = (case when code is not null then 'received' else 'expired' end)::email_status,
             closed_at  = now(),
             updated_at = now()
       where status = 'waiting'                        -- THE atomic claim
         and created_at < now() - interval '22 minutes'
      returning id, user_id, cost_credits, code
    )
    select * from claimed
  loop
    v_n := v_n + 1;
    -- Refund only a PAID order that produced no code. `code is not null` is the
    -- authority for "a code arrived", never status — the same rule the SMS side
    -- had to learn when a rescued code started living on a canceled row.
    if r.cost_credits > 0 and r.code is null then
      begin
        perform public.wallet_move_email(r.user_id, r.cost_credits, 'refund', r.id);
      exception when others then
        -- Per-row, so one bad refund cannot abort the sweep. A double refund is
        -- already impossible: wallet_transactions_email_refund_once_idx is a
        -- partial unique on (email_order_id) where reason='refund'.
        raise warning 'expire_email_orders: refund failed order=% user=%: %',
          r.id, r.user_id, sqlerrm;
      end;
    end if;
  end loop;

  insert into public.app_config (key, value)
  values ('email_expiry_heartbeat', jsonb_build_object('at', now(), 'expired', v_n))
  on conflict (key) do update set value = excluded.value;

  return v_n;
end;
$function$;

revoke execute on function public.expire_email_orders() from public, anon, authenticated;

-- Seed the heartbeat so the watchdog check added below cannot page in the gap
-- between this migration applying and the first cron run.
insert into public.app_config (key, value)
values ('email_expiry_heartbeat', jsonb_build_object('at', now(), 'expired', 0))
on conflict (key) do update set value = excluded.value;

select cron.unschedule('expire-email-orders')
 where exists (select 1 from cron.job where jobname = 'expire-email-orders');

select cron.schedule('expire-email-orders', '*/5 * * * *',
                     $$select public.expire_email_orders();$$);

-- ─────────────────────────────────────────────────────────────────────────
-- 5. Watchdog coverage
-- ─────────────────────────────────────────────────────────────────────────
-- Rebuilt from pg_get_functiondef and diffed clause by clause against the prior
-- definition, per the standing rule that a one-line refactor here is a
-- monitoring outage. THREE hunks differ; every other check is byte-identical:
--
--   a) NEW: sync-herosms freshness. It had none. The existing catalog check
--      reads routes.last_checked_at, which sync-herosms never writes (it writes
--      herosms_checked_at) — verified live: for provider='herosms',
--      max(last_checked_at) is frozen at the 2026-07-30 cutover while
--      max(herosms_checked_at) is current. So that check is driven entirely by
--      sync-prices and would stay green with sync-herosms dead. That job owns
--      the provider serving nearly all demand and is the only thing enforcing
--      MAX_WHOLESALE_CENTS and keeping herosms_cost_cents current for
--      create-order's margin fallback — a silent stall re-creates the exact
--      charge-and-refund bug it was written to fix.
--
--   b) NEW: expire-email-orders freshness, for the sweep added above.
--
--   c) FIXED: three checks used `if v_ts is not null and v_ts < ...`, so a
--      never-written or deleted heartbeat passed silently forever. That is the
--      precise shape of the winback incident where a daily job 401'd for weeks
--      with zero signal. They now use `is null or`, matching the six checks
--      above them.
create or replace function public.run_watchdog()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  fails jsonb := '[]'::jsonb;
  prev  jsonb;
  v_ts  timestamptz;
  bad_http int;
  bad_sample text;
  deliv_total int;
  deliv_ok    int;
  v_push_fail int;
begin
  select (value->>'checked_at')::timestamptz into v_ts
    from app_config where key = 'smspva_health';
  if v_ts is null or v_ts < now() - interval '10 minutes' then
    fails := fails || jsonb_build_object('check','poll-active-orders',
      'detail','balance heartbeat last written '||coalesce(v_ts::text,'never')||
               ' — OTP polling, expiry refunds and balance monitoring are down');
  end if;

  select max(last_checked_at) into v_ts from routes;
  if v_ts is null or v_ts < now() - interval '3 hours' then
    fails := fails || jsonb_build_object('check','sync-prices',
      'detail','newest route price is from '||coalesce(v_ts::text,'never'));
  end if;

  -- (a) sync-herosms owns the provider that serves the demand.
  select max(herosms_checked_at) into v_ts from routes where provider = 'herosms';
  if v_ts is null or v_ts < now() - interval '3 hours' then
    fails := fails || jsonb_build_object('check','sync-herosms',
      'detail','newest HeroSMS route cost is from '||coalesce(v_ts::text,'never')||
               ' — stale wholesale passes the margin gate and reservations then fail');
  end if;

  -- eSIM catalog freshness. Skipped while the product is deliberately paused
  -- (app_config.esim_paused). Pausing to switch providers means the old
  -- provider stops being synced BY DESIGN, so without this the owner is paged
  -- every 6h about a staleness they chose — and alert fatigue on the only
  -- monitoring channel is exactly how a real outage later gets missed.
  -- Compared as jsonb, not cast: value::text::boolean throws on a JSON string.
  if not coalesce((select value = 'true'::jsonb from public.app_config
                   where key = 'esim_paused'), false) then
    select max(last_checked_at) into v_ts from esim_plans;
    if v_ts is null or v_ts < now() - interval '26 hours' then
      fails := fails || jsonb_build_object('check','sync-esim-plans',
        'detail','eSIM catalog last synced '||coalesce(v_ts::text,'never'));
    end if;
  end if;

  select (value->>'last_digest_at')::timestamptz into v_ts
    from app_config where key = 'telegram_bot';
  if v_ts is null or v_ts < now() - interval '7 hours' then
    fails := fails || jsonb_build_object('check','telegram-digest',
      'detail','last digest '||coalesce(v_ts::text,'never'));
  end if;

  select updated_at into v_ts from app_config where key = 'smspva_operator_sync';
  if v_ts is null or v_ts < now() - interval '30 hours' then
    fails := fails || jsonb_build_object('check','sync-smspva-operators',
      'detail','operator cursor last moved '||coalesce(v_ts::text,'never'));
  end if;

  select updated_at into v_ts from app_config where key = 'smspva_conversions_sync';
  if v_ts is null or v_ts < now() - interval '24 hours' then
    fails := fails || jsonb_build_object('check','sync-smspva-conversions',
      'detail','conversions cursor last moved '||coalesce(v_ts::text,'never'));
  end if;

  -- (c) `is null or`, not `is not null and` — an absent heartbeat means the job
  -- has never once succeeded, which is the loudest thing it could tell us.
  select updated_at into v_ts from app_config where key = 'winback_heartbeat';
  if v_ts is null or v_ts < now() - interval '26 hours' then
    fails := fails || jsonb_build_object('check','winback',
      'detail','winback heartbeat last written '||coalesce(v_ts::text,'never'));
  end if;

  select updated_at into v_ts from app_config where key = 'daily_credit_heartbeat';
  if v_ts is null or v_ts < now() - interval '26 hours' then
    fails := fails || jsonb_build_object('check','daily-credit',
      'detail','daily-credit nudge last ran '||coalesce(v_ts::text,'never'));
  end if;

  select updated_at into v_ts from app_config where key = 'esim_expiry_heartbeat';
  if v_ts is null or v_ts < now() - interval '2 hours' then
    fails := fails || jsonb_build_object('check','expire-esim-orders',
      'detail','eSIM expiry sweep last ran '||coalesce(v_ts::text,'never'));
  end if;

  -- (b) the e-mail expiry sweep added in this migration. Runs */5, so 2h is the
  -- same generous multiple the eSIM sweep gets.
  select updated_at into v_ts from app_config where key = 'email_expiry_heartbeat';
  if v_ts is null or v_ts < now() - interval '2 hours' then
    fails := fails || jsonb_build_object('check','expire-email-orders',
      'detail','e-mail expiry sweep last ran '||coalesce(v_ts::text,'never')||
               ' — paid addresses are not being refunded');
  end if;

  select coalesce((value->>'consecutive_failures')::int, 0) into v_push_fail
    from app_config where key = 'push_health';
  if v_push_fail >= 10 then
    fails := fails || jsonb_build_object('check','apns',
      'detail',v_push_fail||' consecutive push failures — code-arrived alerts are not reaching anyone');
  end if;

  select count(*), min(coalesce(status_code::text, error_msg, 'timeout'))
    into bad_http, bad_sample
    from net._http_response
   where created >= now() - interval '25 minutes'
     and (status_code is null or status_code < 200 or status_code >= 300
          or timed_out or error_msg is not null);
  if bad_http > 0 then
    fails := fails || jsonb_build_object('check','relay-http',
      'detail',bad_http||' non-2xx cron relay responses in 25 min (e.g. '||coalesce(bad_sample,'?')||')');
  end if;

  -- Delivery outcome. 24h window so it is actually reachable at ~10 orders/day.
  select count(*), count(*) filter (where o.otp is not null or o.status = 'received')
    into deliv_total, deliv_ok
    from orders o
   where o.closed_at >= now() - interval '24 hours'
     and o.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
     and o.smspva_number is not null
     and (o.status in ('received','expired')
          or (o.status = 'canceled' and o.closed_at - o.created_at >= interval '240 seconds')
          or (o.status = 'canceled' and exists (
                select 1 from orders n
                where n.user_id = o.user_id and n.service_id = o.service_id
                  and n.id <> o.id and n.created_at >= o.closed_at
                  and n.created_at < o.closed_at + interval '10 minutes')));
  if deliv_total >= 10 and deliv_ok = 0 then
    fails := fails || jsonb_build_object('check','delivery-collapse',
      'detail',deliv_total||' conclusive orders in 24h, ZERO codes delivered');
  elsif deliv_total >= 20 and deliv_ok::numeric / deliv_total < 0.10 then
    fails := fails || jsonb_build_object('check','delivery-degraded',
      'detail',deliv_ok||'/'||deliv_total||' delivered in 24h (<10%)');
  end if;

  select value into prev from app_config where key = 'watchdog';
  insert into app_config (key, value)
  values ('watchdog', jsonb_build_object(
    'checked_at', now(), 'failing', fails,
    'alerted', coalesce(prev->'alerted', '[]'::jsonb),
    'last_alert_at', prev->>'last_alert_at'))
  on conflict (key) do update set value = excluded.value;

  return fails;
end;
$function$;

revoke execute on function public.run_watchdog() from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 6. Housekeeping: drop the cursor for a function deleted on 2026-07-30
-- ─────────────────────────────────────────────────────────────────────────
-- sync-smspool is gone from disk and undeployed. Its cursor row is inert (no
-- watchdog check reads it) but reads as live state for a job that no longer
-- exists, which is exactly what a future audit should not have to re-derive.
delete from public.app_config where key = 'smspool_sync';
