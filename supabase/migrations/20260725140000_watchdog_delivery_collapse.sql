-- Teach the watchdog to notice that the PRODUCT is broken, not just the jobs.
--
-- WHY: on 2026-07-24 every single SMS order failed — 12 orders, 3 users, zero
-- codes, everyone refunded — and `run_watchdog()` reported `failing: []` for
-- the entire day. Correctly, by its own rules: the poller was fresh, prices
-- were syncing, no relay returned non-2xx. Numbers were being reserved fine;
-- the codes just never arrived. Every check we had watched the machinery and
-- none watched the outcome, so the most expensive failure mode in the business
-- was the one nobody was paged about.
--
-- CONCLUSIVE orders only, reusing refresh_route_observed_success's definition:
-- a 5-second cancel is not evidence that a code would not have come, but a
-- cancel held >= 240s — or one followed by the same user re-ordering the same
-- service within 10 minutes — is. Without that, yesterday's event would have
-- been invisible here too: 11 of its 12 orders were user-cancels.
--
-- The volume gates keep a quiet day quiet. Against the ~26% lifetime baseline,
-- 0-of-10 is roughly a 5% coincidence — rare enough to be worth a look, common
-- enough that this is a "come and check", not a claim of certainty.
--
-- Everything else in this function is carried over verbatim from
-- 20260722050000; only the delivery block and its two variables are new.

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
  -- poll-active-orders writes smspva_health every minute; it is the de-facto
  -- heartbeat for the entire relay + CRON_SECRET + edge-runtime path.
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

  -- Winback: absent key means "never initialized", which is not a failure
  -- (the first daily run seeds it); staleness after that is.
  select updated_at into v_ts from app_config where key = 'winback_heartbeat';
  if v_ts is not null and v_ts < now() - interval '26 hours' then
    fails := fails || jsonb_build_object('check','winback',
      'detail','winback heartbeat last written '||v_ts::text);
  end if;

  -- ── Delivery-rate collapse (NEW) ─────────────────────────────────────
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

  -- Any relayed edge function that answered non-2xx / timed out in the last
  -- 25 min (pg_net keeps ~6h of history — this is the ONLY consumer of it).
  -- Catches 401 (CRON_SECRET drift on EITHER store), 500s, and the fail-loud
  -- 502s of the sync functions, for every relay including ones with no
  -- freshness check of their own.
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

  -- Preserve alert bookkeeping (telegram-notify stamps these when it pages).
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

revoke execute on function public.run_watchdog() from anon, authenticated;
