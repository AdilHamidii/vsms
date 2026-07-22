-- Autopilot watchdog + hygiene batch (2026-07-22 autonomy audit).
--
-- Goal: the app must generate revenue with no intervention beyond provider
-- top-ups — so every scheduled job's death must become LOUD. The historical
-- failure class: cron relays fire net.http_post (async), so cron.job_run_details
-- shows 'succeeded' even when the edge function 401s/500s (winback died this
-- way for 9 days), and the only record of the real outcome (net._http_response)
-- purges itself within ~6 hours.
--
-- Design: run_watchdog() is PLAIN SQL on its own pg_cron schedule — no edge
-- function, no CRON_SECRET, no HTTP — so it keeps evaluating even when the
-- entire edge/secret layer is broken. It writes its verdict to
-- app_config.'watchdog'; telegram-notify (runs every minute, holds the bot
-- token) is the alert transport, paging on any failing check with a 6h
-- re-alert cadence and an all-clear on recovery. Residual blind spot: if
-- telegram-notify ITSELF is dead the page can't go out — but then the 6-hourly
-- digest also stops, which is the documented human-observable backstop
-- (docs/autopilot-runbook.md: "no digest for >7h means the alert layer is
-- down, open the dashboard").

-- ── 1) app_config.updated_at becomes trustworthy ─────────────────────────
-- The operator/conversions cursor upserts send only {key,value}, so their
-- updated_at froze at creation time — the two newest syncs were unmonitorable
-- even in principle. A touch trigger fixes every current and future writer.
create or replace function public.touch_app_config()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

drop trigger if exists app_config_touch on public.app_config;
create trigger app_config_touch
  before insert or update on public.app_config
  for each row execute function public.touch_app_config();

-- ── 2) The watchdog itself ───────────────────────────────────────────────
-- Thresholds are deliberately generous multiples of each job's cadence so a
-- single slow run can't page: poller is minutely (10 min), sync-prices hourly
-- (3 h), digest 6-hourly (7 h), esim-plans daily (26 h), conversions hourly
-- but cursor-rotated (24 h), operators nightly-window (30 h), winback daily
-- (26 h, and only once its heartbeat key exists at all).
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

do $$ begin
  if exists (select 1 from cron.job where jobname = 'watchdog') then
    perform cron.unschedule('watchdog');
  end if;
  if exists (select 1 from cron.job where jobname = 'purge-job-run-details') then
    perform cron.unschedule('purge-job-run-details');
  end if;
end $$;

select cron.schedule('watchdog', '*/10 * * * *', $$select public.run_watchdog();$$);

-- ── 3) cron.job_run_details retention ────────────────────────────────────
-- 79,743 rows (~63% of the whole database on a plan with a 500 MB cap),
-- growing ~4.3k rows/day, read by nobody after 7 days.
select cron.schedule('purge-job-run-details', '7 3 * * *',
  $$delete from cron.job_run_details where end_time < now() - interval '7 days'$$);
delete from cron.job_run_details where end_time < now() - interval '7 days';

-- ── 4) Indexes for the telegram-notify sweep ─────────────────────────────
-- The sweep window widens from 30 min to 24 h (a Telegram outage longer than
-- the old window permanently dropped signup alerts); give its three
-- created_at scans indexes so the minutely query stays trivial forever.
create index if not exists profiles_created_at_idx      on public.profiles(created_at);
create index if not exists iap_receipts_created_at_idx  on public.iap_receipts(created_at);
create index if not exists esim_orders_created_at_idx   on public.esim_orders(created_at);

-- ── 5) Stale-balance honesty in the digest ───────────────────────────────
-- ops_snapshot rendered the last written balance as current forever — a dead
-- poller (or revoked provider key) produced confidently WRONG "all is well"
-- digests. A reading older than 10 minutes now surfaces as "no reading",
-- which the formatter already renders honestly.
create or replace function public.ops_snapshot(p_window interval default '6 hours')
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
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
  ord as (
    select count(*)::int as placed,
           count(*) filter (where status = 'received')::int as received,
           count(*) filter (where status in ('expired','canceled'))::int as failed
    from scoped
  ),
  by_prov as (
    select coalesce(provider, 'unknown') as provider,
           count(*)::int as placed,
           count(*) filter (where status = 'received')::int as received,
           count(*) filter (where status in ('expired','canceled'))::int as failed
    from scoped group by 1
  ),
  esim as (
    select count(*)::int as n, coalesce(sum(cost_credits),0)::int as credits
    from public.esim_orders
    where created_at >= (select t from since) and user_id <> (select id from dev)
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
  )
  select jsonb_build_object(
    'window_hours', round(extract(epoch from p_window) / 3600.0, 1),
    'signups',      (select n from sign),
    'purchases',    jsonb_build_object(
                      'count',   (select n from buys),
                      'credits', (select credits from buys)),
    'orders',       jsonb_build_object(
                      'placed',   (select placed from ord),
                      'received', (select received from ord),
                      'failed',   (select failed from ord),
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
    'esims',        jsonb_build_object(
                      'count',   (select n from esim),
                      'credits', (select credits from esim)),
    'smspva_usd',   (select usd from bal_pva),
    'smspool_usd',  (select usd from bal_pool)
  );
$function$;

-- ── 6) Retire the retired provider's leftovers ───────────────────────────
-- virtualsms_health froze at "healthy $10.50" on 2026-07-21 — a false-healthy
-- triage signal for a provider that no longer serves anything.
delete from public.app_config where key in ('virtualsms_health', 'virtualsms_sync');

-- ── 7) Reconcile migration bookkeeping ───────────────────────────────────
-- Six 2026-07-21 migrations were applied live via MCP apply_migration (which
-- mints its own version numbers) and exist in the repo under these round
-- version stamps — but supabase_migrations.schema_migrations has no rows for
-- them, so the next `supabase db push` would RE-APPLY all six (some are not
-- idempotent). Register them as already-applied.
insert into supabase_migrations.schema_migrations (version, name, statements)
values
  ('20260721120000', 'smspva_premium_tier',
   array['-- registered retroactively 2026-07-22: applied live via MCP apply_migration on 2026-07-21; repo file is authoritative']),
  ('20260721130000', 'signup_bonus_1cr_daily_operator_sync',
   array['-- registered retroactively 2026-07-22: applied live via MCP apply_migration on 2026-07-21; repo file is authoritative']),
  ('20260721140000', 'operator_sync_maintenance_window',
   array['-- registered retroactively 2026-07-22: applied live via MCP apply_migration on 2026-07-21; repo file is authoritative']),
  ('20260721150000', 'stranded_credit_winback',
   array['-- registered retroactively 2026-07-22: applied live via MCP apply_migration on 2026-07-21; repo file is authoritative']),
  ('20260721160000', 'conversion_seeded_rates',
   array['-- registered retroactively 2026-07-22: applied live via MCP apply_migration on 2026-07-21; repo file is authoritative']),
  ('20260721170000', 'backend_hardening',
   array['-- registered retroactively 2026-07-22: applied live via MCP apply_migration on 2026-07-21; repo file is authoritative'])
on conflict (version) do nothing;
