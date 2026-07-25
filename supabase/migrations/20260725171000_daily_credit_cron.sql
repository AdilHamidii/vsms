-- Schedule the daily-credit nudge + eSIM expiry, and give both a watchdog check.
--
-- Every scheduled job needs a freshness signal or it can die silently — that is
-- the standing rule, and the reason winback's weeks of 401s were invisible.
--
-- 16:11 UTC is deliberately off the hour and off :00/:30: it is late afternoon
-- in Europe and late morning in the Americas, and it does not collide with
-- relay-winback (15:00) or the hourly price sync (:17).

do $$ begin
  if exists (select 1 from cron.job where jobname = 'relay-daily-credit') then
    perform cron.unschedule('relay-daily-credit');
  end if;
  if exists (select 1 from cron.job where jobname = 'expire-esim-orders') then
    perform cron.unschedule('expire-esim-orders');
  end if;
end $$;

select cron.schedule(
  'relay-daily-credit', '11 16 * * *',
  $$select net.http_post(
      url := 'https://enugzltysdmjzavisloy.supabase.co/functions/v1/daily-credit',
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-cron-secret', private_cron_secret()),
      body := '{}'::jsonb, timeout_milliseconds := 120000);$$);

-- Pure SQL, no edge function and no secret — same reasoning as run_watchdog:
-- a lapsed eSIM must stop reading "Active" even if the whole edge layer is down.
select cron.schedule(
  'expire-esim-orders', '*/15 * * * *',
  $$select public.expire_esim_orders();$$);

-- ── Watchdog: notice if the daily nudge stops running ────────────────────
create or replace function public.run_watchdog()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  fails jsonb := '[]'::jsonb;
  prev  jsonb;
  v_ts  timestamptz;
  bad_http int;
  bad_sample text;
  deliv_total int;
  deliv_ok    int;
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

  -- NEW: the daily-credit nudge is the app's only recurring reason to return.
  select updated_at into v_ts from app_config where key = 'daily_credit_heartbeat';
  if v_ts is not null and v_ts < now() - interval '26 hours' then
    fails := fails || jsonb_build_object('check','daily-credit',
      'detail','daily-credit nudge last ran '||v_ts::text||
               ' — the recurring retention loop is silent');
  end if;

  with c as (
    select
      (o.status = 'received') as is_code,
      (
        o.status = 'received'
        or o.status = 'expired'
        or (o.status = 'canceled' and o.closed_at - o.created_at >= interval '240 seconds')
        or (o.status = 'canceled' and exists (
              select 1 from orders n
              where n.user_id = o.user_id
                and n.service_id = o.service_id
                and n.id <> o.id
                and n.created_at >= o.closed_at
                and n.created_at < o.closed_at + interval '10 minutes'))
      ) as is_conclusive
    from orders o
    where o.created_at >= now() - interval '24 hours'
      and o.closed_at is not null
      and o.user_id <> '825688de-6117-4251-9f90-93b83b41b572'
  )
  select count(*) filter (where is_conclusive),
         count(*) filter (where is_conclusive and is_code)
    into deliv_total, deliv_ok
    from c;

  if deliv_total >= 10 and deliv_ok = 0 then
    fails := fails || jsonb_build_object('check','delivery-rate',
      'detail', deliv_total||' conclusive orders in 24h and ZERO codes delivered'||
                ' — every paying user is being refunded instead of served');
  elsif deliv_total >= 20 and (100.0 * deliv_ok / deliv_total) < 10 then
    fails := fails || jsonb_build_object('check','delivery-rate',
      'detail', round(100.0 * deliv_ok / deliv_total)||'% delivery over '||deliv_total||
                ' conclusive orders in 24h — far below the ~26% baseline');
  end if;

  select count(*),
         max(coalesce('HTTP '||status_code::text,
                      case when timed_out then 'timeout' else left(error_msg, 80) end))
    into bad_http, bad_sample
    from net._http_response
   where created > now() - interval '25 minutes'
     and (status_code is null
          or status_code not between 200 and 299
          or timed_out
          or error_msg is not null);
  if bad_http > 0 then
    fails := fails || jsonb_build_object('check','relay-http',
      'detail', bad_http||' failed relay response(s) in 25 min, e.g. '||coalesce(bad_sample,'?'));
  end if;

  select value into prev from app_config where key = 'watchdog';
  insert into app_config(key, value)
  values ('watchdog', jsonb_build_object(
            'failing',       fails,
            'checked_at',    now(),
            'last_alert_at', prev->'last_alert_at',
            'alerted',       prev->'alerted'))
  on conflict (key) do update set value = excluded.value;

  return jsonb_build_object('failing', fails);
end $$;

-- `create or replace` preserves the ACL, but re-issue the PUBLIC revoke anyway:
-- a fresh deploy of this file into a new project would otherwise ship the same
-- unauthenticated ops leak this migration set just closed.
revoke execute on function public.run_watchdog() from public;
revoke execute on function public.run_watchdog() from anon, authenticated;
