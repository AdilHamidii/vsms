-- Close the remaining "if this silently did nothing, how would we know?" gaps.
--
-- Audited 2026-07-27: 14 active pg_cron jobs, run_watchdog() covered 8. The
-- uncovered ones and what their silent failure costs:
--
--   expire-esim-orders (*/15)  — eSIMs stay "Active" forever past expiry, which
--                                is the exact bug 20260725170000 was written to
--                                fix. Plain SQL, no heartbeat, no check.
--   APNs (not a cron)          — if the .p8 expires or the topic drifts, EVERY
--                                push dies at once: "your code arrived", the
--                                expiry-refund notice, winback, daily credit.
--                                poll-active-orders logs console.error and
--                                returns 200 {pushSent: 0}. Nothing anywhere
--                                counts it.
--
-- purge-job-run-details and telegram-events-prune are left uncovered on
-- purpose: both guard slow-growing storage on a 500MB cap, so a missed run is
-- days from mattering and a page would be noise.

-- ── 1. expire_esim_orders writes a heartbeat.
--
-- Re-created from the live definition with only the heartbeat added, so the
-- expiry semantics are untouched.
create or replace function public.expire_esim_orders()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_n integer;
begin
  with upd as (
    update public.esim_orders
       set status = 'expired', updated_at = now()
     where expires_at is not null
       and expires_at < now()
       and status in ('provisioning', 'installed', 'active')
    returning 1
  )
  select count(*) into v_n from upd;

  -- Heartbeat so a silent death is visible. The app_config_touch trigger
  -- maintains updated_at, which is what run_watchdog reads.
  insert into public.app_config (key, value)
  values ('esim_expiry_heartbeat', jsonb_build_object('at', now(), 'expired', v_n))
  on conflict (key) do update set value = excluded.value;

  return v_n;
end;
$function$;

-- ── 2. Watchdog: eSIM expiry freshness + APNs health.
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
      'detail','newest route price is from '||coalesce(v_ts::text,'never')||
               ' — retail is drifting from wholesale and catalog self-correction is frozen');
  end if;

  select max(last_checked_at) into v_ts from esim_plans;
  if v_ts is null or v_ts < now() - interval '26 hours' then
    fails := fails || jsonb_build_object('check','sync-esim-plans',
      'detail','eSIM catalog last synced '||coalesce(v_ts::text,'never')||
               ' — a wholesale price rise now blocks ALL eSIM purchases (fail-closed ceiling)');
  end if;

  select (value->>'last_digest_at')::timestamptz into v_ts
    from app_config where key = 'telegram_bot';
  if v_ts is null or v_ts < now() - interval '7 hours' then
    fails := fails || jsonb_build_object('check','telegram-digest',
      'detail','last digest '||coalesce(v_ts::text,'never')||
               ' — if you are reading this the send path partially works; check telegram-notify logs');
  end if;

  select updated_at into v_ts from app_config where key = 'smspva_operator_sync';
  if v_ts is null or v_ts < now() - interval '30 hours' then
    fails := fails || jsonb_build_object('check','sync-smspva-operators',
      'detail','operator cursor last moved '||coalesce(v_ts::text,'never')||
               ' — premium real-SIM pins are going stale');
  end if;

  select updated_at into v_ts from app_config where key = 'smspva_conversions_sync';
  if v_ts is null or v_ts < now() - interval '24 hours' then
    fails := fails || jsonb_build_object('check','sync-smspva-conversions',
      'detail','conversions cursor last moved '||coalesce(v_ts::text,'never')||
               ' — seeded delivery evidence is going stale');
  end if;

  select updated_at into v_ts from app_config where key = 'winback_heartbeat';
  if v_ts is not null and v_ts < now() - interval '26 hours' then
    fails := fails || jsonb_build_object('check','winback',
      'detail','winback heartbeat last written '||v_ts::text);
  end if;

  select updated_at into v_ts from app_config where key = 'daily_credit_heartbeat';
  if v_ts is not null and v_ts < now() - interval '26 hours' then
    fails := fails || jsonb_build_object('check','daily-credit',
      'detail','daily-credit nudge last ran '||v_ts::text);
  end if;

  -- NEW: eSIM expiry sweep. Runs every 15 min, so 2 hours of silence is dead.
  select updated_at into v_ts from app_config where key = 'esim_expiry_heartbeat';
  if v_ts is not null and v_ts < now() - interval '2 hours' then
    fails := fails || jsonb_build_object('check','expire-esim-orders',
      'detail','eSIM expiry sweep last ran '||v_ts::text||
               ' — sold eSIMs will keep showing as Active past their expiry');
  end if;

  -- NEW: APNs. If the .p8 expires or the topic drifts, every push in the
  -- product dies at once — including "your code arrived", which is the core
  -- delivery mechanism for a product whose median wait is ~58s.
  select coalesce((value->>'consecutive_failures')::int, 0) into v_push_fail
    from app_config where key = 'push_health';
  if v_push_fail >= 10 then
    fails := fails || jsonb_build_object('check','apns',
      'detail',v_push_fail||' consecutive push failures — code-arrived alerts are not reaching anyone');
  end if;

  -- net._http_response has no `url` column (id, status_code, content_type,
  -- headers, content, timed_out, error_msg, created) — sample the status and
  -- error instead.
  select count(*), min(coalesce(status_code::text, error_msg, 'timeout'))
    into bad_http, bad_sample
    from net._http_response
   where created >= now() - interval '25 minutes'
     and (status_code is null or status_code < 200 or status_code >= 300);
  if bad_http > 0 then
    fails := fails || jsonb_build_object('check','relay-http',
      'detail',bad_http||' non-2xx cron relay responses in 25 min (e.g. '||coalesce(bad_sample,'?')||')');
  end if;

  select count(*), count(*) filter (where o.otp is not null or o.status = 'received')
    into deliv_total, deliv_ok
    from orders o
   where o.closed_at >= now() - interval '6 hours'
     and o.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
     and o.smspva_number is not null
     and (o.status in ('received','expired')
          or (o.status = 'canceled' and o.closed_at - o.created_at >= interval '240 seconds'));
  if deliv_total >= 8 and deliv_ok = 0 then
    fails := fails || jsonb_build_object('check','delivery-collapse',
      'detail',deliv_total||' conclusive orders in 6h, ZERO codes delivered');
  end if;

  select value into prev from app_config where key = 'watchdog';

  insert into app_config (key, value)
  values ('watchdog', jsonb_build_object(
    'checked_at', now(),
    'failing', fails,
    'alerted', coalesce(prev->'alerted', '[]'::jsonb),
    'last_alert_at', prev->>'last_alert_at'))
  on conflict (key) do update set value = excluded.value;

  return fails;
end;
$function$;

revoke execute on function public.run_watchdog() from public;
