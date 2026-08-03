-- Stop the watchdog paging about the daily credit, which was switched off.
--
-- The daily credit WAS removed: relay-daily-credit unscheduled 2026-08-02,
-- the grant disabled behind app_config.daily_credit_enabled (20260801150000),
-- and the client code deleted. What was NOT removed was its MONITORING.
--
-- run_watchdog still checked the freshness of app_config.daily_credit_heartbeat,
-- and the only writer of that key is the daily-credit edge function the
-- unscheduled cron used to call. So the key froze at 2026-08-01 16:11:20Z and
-- can never be written again. The check fires at >26h stale: it tripped at
-- 2026-08-02 18:11Z and has re-alerted every 6 hours since, about a job that
-- was deliberately turned off.
--
-- Two costs, both real and both already incurred:
--
--  1. Alert fatigue on the ONLY monitoring channel — which this repo's own
--     notes call out as how the next genuine outage gets ignored.
--  2. winback gates its stranded-credit cohort on `failing.length === 0`
--     (winback/index.ts:140). A permanently-red watchdog therefore substituted
--     an empty list for the cohort of users whose last order FAILED while they
--     still hold idle credits — silently, and indefinitely. That is the third
--     cohort-killing ANDed gate found in this codebase.
--
-- GATED, not deleted, so re-enabling the grant restores its monitoring in the
-- same step rather than leaving a paying job unwatched. The enabled flag is
-- compared as TEXT, never cast to boolean: a junk value would raise, and
-- run_watchdog is deliberately plain SQL so it still evaluates when the whole
-- edge/secret layer is down. Missing or malformed reads as "disabled".
--
-- Regenerated from pg_get_functiondef and diffed clause by clause: exactly ONE
-- hunk differs and all 15 checks are still present (the specific regression
-- this file's predecessors warn about — a rebuild once silently narrowed a
-- delivery check into unreachability and deleted a whole branch).
--
-- Verified in a rolled-back transaction against the live definition:
--   disabled now   -> []                      (watchdog fully green)
--   re-enabled     -> pages daily-credit      (gated, NOT dead)
--   junk value     -> []                      (no raise)
--   row missing    -> []                      (no raise)

CREATE OR REPLACE FUNCTION public.run_watchdog()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  fails jsonb := '[]'::jsonb;
  prev  jsonb;
  v_ts  timestamptz;
  bad_http int;
  bad_sample text;
  deliv_total int;
  deliv_ok    int;
  deliv7_total int;
  deliv7_ok   int;
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

  -- Only meaningful while the daily credit is actually ENABLED.
  --
  -- Its cron (relay-daily-credit) was unscheduled on 2026-08-02 and the grant
  -- disabled behind app_config.daily_credit_enabled. The heartbeat's ONLY
  -- writer is the daily-credit function that cron used to call, so the key
  -- froze at 2026-08-01 16:11:20Z and can never be written again. This check
  -- tripped at 18:11Z and has paged every 6h since — about a job that was
  -- deliberately switched off.
  --
  -- Two real costs: alert fatigue on the only monitoring channel, which is
  -- documented here as how the NEXT real outage gets ignored; and winback gates
  -- its stranded-credit cohort on `failing.length === 0` (winback/index.ts:140),
  -- so a permanently-red watchdog silently suppressed the cohort of users whose
  -- last order failed while they still hold idle credits.
  --
  -- Gated, not deleted, so re-enabling the grant restores its monitoring in the
  -- same step rather than leaving a paying job unwatched.
  --
  -- Compared as TEXT, never `::boolean` — a junk value would raise, and this
  -- function is the last thing that still evaluates when the edge/secret layer
  -- is broken. A missing or malformed row reads as "disabled", i.e. silent.
  if coalesce((select value->>'enabled' from app_config
                where key = 'daily_credit_enabled'), 'false') = 'true' then
    select updated_at into v_ts from app_config where key = 'daily_credit_heartbeat';
    if v_ts is null or v_ts < now() - interval '26 hours' then
      fails := fails || jsonb_build_object('check','daily-credit',
        'detail','daily-credit nudge last ran '||coalesce(v_ts::text,'never'));
    end if;
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

  -- Delivery outcome. CANCELS ARE EXCLUDED (2026-08-01).
  --
  -- This used to count a cancel as conclusive when the user either held the
  -- number 240s+ or re-ordered the same service within 10 minutes. At a 59%
  -- cancel rate that made the check a measure of user impatience, not provider
  -- health: it fired 'ZERO codes delivered' on 2026-08-01 while non-cancelled
  -- delivery was ~73%. Alert fatigue on the only monitoring channel is how a
  -- real outage later gets missed.
  --
  -- Only `received` (delivered) and `expired` (ran the full window, nothing
  -- arrived) say anything about whether the PROVIDER is working. A cancel is
  -- the user's choice and is evidence about the UI, not the numbers.
  --
  -- Thresholds are set from measured reachability over 30 days, because a gate
  -- above the achievable volume is a silently disabled check — this function
  -- has already shipped that bug once:
  --   72h non-cancelled volume: avg 6, max 12  -> collapse gate 6
  --   7d  non-cancelled volume: min 3, avg 13, max 21 -> degraded gate 12
  -- At a ~73% baseline, zero codes in 6 orders is p ~ 0.0004, so 6 is small
  -- but not noisy. Collapse uses the SHORT window so a real outage is caught
  -- in hours; degradation uses the long one, where a rate is meaningful.
  select count(*), count(*) filter (where o.otp is not null or o.status = 'received')
    into deliv_total, deliv_ok
    from orders o
   where o.closed_at >= now() - interval '72 hours'
     and o.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
     and o.smspva_number is not null
     and o.status in ('received','expired');

  select count(*), count(*) filter (where o.otp is not null or o.status = 'received')
    into deliv7_total, deliv7_ok
    from orders o
   where o.closed_at >= now() - interval '7 days'
     and o.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
     and o.smspva_number is not null
     and o.status in ('received','expired');

  if deliv_total >= 6 and deliv_ok = 0 then
    fails := fails || jsonb_build_object('check','delivery-collapse',
      'detail',deliv_total||' uncancelled orders in 72h, ZERO codes delivered');
  elsif deliv7_total >= 12 and deliv7_ok::numeric / deliv7_total < 0.30 then
    fails := fails || jsonb_build_object('check','delivery-degraded',
      'detail',deliv7_ok||'/'||deliv7_total||' delivered in 7d (<30%, baseline ~73%)');
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
$function$
;
