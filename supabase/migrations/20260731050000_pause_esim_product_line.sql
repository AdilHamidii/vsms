-- Pause the eSIM product line from the BACKEND ONLY, reversibly, with no build.
--
-- The owner is switching eSIM providers and needs the product off the shelf now
-- and back on the moment a new provider is wired — without shipping an app.
--
-- The lever is `esim_plans.status`, because both halves already key on it:
--   * the client fetches `esim_plans?status=eq.active` (this is true of the
--     RELEASED build 18 as well as build 19, so it needs no app change), and
--   * `create-esim-order` already refuses any plan whose status is not
--     'active' with `plan_unavailable` — so a client holding a CACHED catalog
--     still cannot buy. That guard predates this migration; we are reusing it
--     rather than inventing a second, drift-prone one.
--
-- What deliberately KEEPS working, verified before writing this:
--   * The 12 live eSIMs. `check-esim-usage` looks plans up by id with NO status
--     filter, so usage, expiry stamping and the QR all behave. All 12 live
--     orders also carry their own `data_total_mb`, so the usage gauges read
--     from the ORDER, not the catalog.
--   * `expire-esim-orders` — untouched, still sweeping for those live orders.
--
-- Known, accepted cosmetic cost: the client resolves an order's plan out of the
-- fetched catalog (`EsimOrder(server:plan:)`), so while paused a live eSIM shows
-- the fallback name "eSIM" instead of its plan name. Data totals and usage are
-- unaffected. That is 12 users, for the length of the switch.
--
--   PAUSE:   select public.set_esim_paused(true);
--   RESUME:  select public.set_esim_paused(false);
--
-- Both return jsonb {paused, plans_changed, plans_active} — read it. Resuming a
-- catalog whose provider is gone re-activates 0 plans, and that must be VISIBLE
-- rather than looking like success.

insert into public.app_config (key, value)
values ('esim_paused', 'false'::jsonb)
on conflict (key) do nothing;

create or replace function public.set_esim_paused(p_paused boolean)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_changed integer;
  v_active  integer;
begin
  insert into public.app_config (key, value)
  values ('esim_paused', to_jsonb(p_paused))
  on conflict (key) do update set value = excluded.value;

  if p_paused then
    update public.esim_plans set status = 'hidden' where status = 'active';
    get diagnostics v_changed = row_count;
  else
    -- Re-activate ONLY plans the sync has seen recently. A plan the provider
    -- delisted goes stale and must stay hidden; blanket-activating every hidden
    -- row would resurrect exactly the rows `sync-esim-plans` retires on purpose
    -- (its own stale-hide pass uses the same last_checked_at signal).
    update public.esim_plans
    set status = 'active'
    where status = 'hidden'
      and retail_credits is not null
      and last_checked_at >= now() - interval '3 days';
    get diagnostics v_changed = row_count;
  end if;

  select count(*) into v_active from public.esim_plans where status = 'active';
  return jsonb_build_object(
    'paused', p_paused, 'plans_changed', v_changed, 'plans_active', v_active);
end;
$fn$;

-- CREATE FUNCTION grants EXECUTE to PUBLIC, and anon/authenticated are members
-- of PUBLIC — so revoking from anon/authenticated alone is a no-op. Revoke
-- PUBLIC explicitly or this is callable at /rest/v1/rpc/set_esim_paused.
revoke execute on function public.set_esim_paused(boolean) from public, anon, authenticated;

-- Watchdog: skip the eSIM catalog freshness check while paused. Regenerated
-- from pg_get_functiondef and diffed clause by clause — exactly one hunk
-- differs from the live definition, every other check is byte-identical.
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

  select updated_at into v_ts from app_config where key = 'esim_expiry_heartbeat';
  if v_ts is not null and v_ts < now() - interval '2 hours' then
    fails := fails || jsonb_build_object('check','expire-esim-orders',
      'detail','eSIM expiry sweep last ran '||v_ts::text);
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
$function$
;
