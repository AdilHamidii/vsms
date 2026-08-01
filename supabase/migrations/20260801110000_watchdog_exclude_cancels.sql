-- Re-scope the watchdog's delivery checks to EXCLUDE user cancellations.
--
-- The delivery-collapse check fired on 2026-08-01 ("14 conclusive orders in
-- 24h, ZERO codes delivered") while non-cancelled delivery was ~73%. It counted
-- a cancel as conclusive whenever the user held the number 240s+ OR re-ordered
-- the same service within 10 minutes — and with 59% of numbered orders being
-- user cancels, that made it a gauge of impatience rather than provider health.
-- Alert fatigue on the only monitoring channel is how a real outage later gets
-- missed, so this is a correctness fix, not cosmetics.
--
-- Only `received` and `expired` are evidence about the PROVIDER. A cancel is
-- the user's choice: evidence about the UI, not about the numbers.
--
-- Thresholds come from measured reachability over 30 days, because a gate above
-- achievable volume is a silently disabled check — this function has shipped
-- exactly that bug before (the 6h/>=8 rewrite that was unreachable):
--     72h non-cancelled: avg 6, max 12   -> collapse gate 6   (short = fast)
--     7d  non-cancelled: min 3, avg 13, max 21 -> degraded gate 12
-- Zero codes in 6 orders against a ~73% baseline is p ~ 0.0004.
--
-- Regenerated from pg_get_functiondef and diffed clause by clause: exactly two
-- hunks differ (the two new declarations and the delivery block). Every other
-- check is byte-identical.

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
