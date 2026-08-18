-- ─────────────────────────────────────────────────────────────────────────────
-- run_watchdog(): the three MONEY checks it was missing
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Found by the 2026-08-18 money audit. Every one of these is a case where money
-- stops or leaks and the watchdog reads green:
--
--   1. PROVIDER FLOAT. `poll-active-orders` writes `<provider>_health` with an
--      alert tier every minute, and NOTHING gates on it — the tier is rendered
--      by /balance and read by no check. Measured 2026-08-18: 5sim at $3.88,
--      HeroSMS $3.78, every provider at alert_tier 4, watchdog `failing: []`.
--      When 5sim hits zero, `reserve` returns BALANCE_ERROR, create-order maps
--      it to `provider_unreachable`, and 100% of SMS revenue stops behind a
--      generic outage message. The check is on RUNWAY, not a fixed floor: the
--      7-day GROSS reservation burn is what the balance must fund (a
--      reservation is paid before its refund comes back, and ~79% of orders
--      refund), so `balance / daily gross burn` is the honest number.
--
--   2. CREDIT-LINE RENT. `debit_credit_lines()` writes `line_rent_heartbeat`
--      daily and NOTHING reads it. If that cron stops, credit-billed lines are
--      never debited, never reach `grace`, never reach `releasing`, and run
--      free at Telnyx rent with no credits collected — silently. This is the
--      exact `relay-daily-credit` / `winback` failure the watchdog's own
--      comments document twice.
--
--   3. APPLE LAPSE STATE. Companion to reclaim_lapsed_lines() branch (d),
--      added in 20260818110000: an Apple-billed line still `active` 12h past
--      its period end means the backstop itself failed twice. Same rule as the
--      `releasing >6h` check beside it — check the STATE, not just a heartbeat.
--
-- WHY A COMPANION FUNCTION AND NOT A REWRITE. CLAUDE.md records that
-- regenerating run_watchdog from pg_get_functiondef silently narrowed the
-- delivery check and deleted a branch once, and invented a nonexistent column
-- another time — the dump is truncated by most tooling. So the existing
-- function is NOT touched. `watchdog_money_checks()` returns its own jsonb
-- array, and a thin wrapper appends it. Every existing clause stays
-- byte-identical, and the addition can be diffed on its own.
--
-- The cron calls `run_watchdog()`; the wrapper keeps that name so nothing
-- else changes. The previous body lives on as `run_watchdog_core()`.
-- ─────────────────────────────────────────────────────────────────────────────

-- 1. Preserve the existing body verbatim under a new name.
do $$
declare
  v_def text;
begin
  select pg_get_functiondef('public.run_watchdog'::regproc) into v_def;
  -- Only the identifier changes; the body is the live definition, unmodified.
  v_def := replace(v_def,
    'FUNCTION public.run_watchdog()',
    'FUNCTION public.run_watchdog_core()');
  execute v_def;
end $$;

revoke execute on function public.run_watchdog_core() from public, anon, authenticated;

-- 2. The three money checks, in their own function.
create or replace function public.watchdog_money_checks()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  fails      jsonb := '[]'::jsonb;
  v_ts       timestamptz;
  v_bal      numeric;
  v_burn     numeric;
  v_runway   numeric;
  v_lines    int;
  v_prov     text;
  v_unreleased int;
begin
  -- (1) Provider runway, per provider that still serves orders. Gross burn is
  -- summed from actual_cost_cents on every order that reserved a number in
  -- the last 7 days — refunded or not, because the float had to exist first.
  -- 5 days of runway is the page threshold: enough time to top up, and far
  -- above the noise of a single busy day.
  for v_prov in select unnest(array['5sim', 'herosms']) loop
    select (value->>'balance_usd')::numeric,
           (value->>'checked_at')::timestamptz
      into v_bal, v_ts
      from app_config where key = v_prov || '_health';

    -- Stale or missing reading is the poller's problem (its own check above);
    -- do not double-page here.
    if v_bal is null or v_ts is null or v_ts < now() - interval '15 minutes' then
      continue;
    end if;

    select coalesce(sum(actual_cost_cents), 0) / 100.0 / 7.0
      into v_burn
      from orders
     where provider = v_prov
       and smspva_number is not null
       and created_at >= now() - interval '7 days';

    -- No burn means no risk; and it avoids a divide-by-zero on a quiet
    -- provider.
    if v_burn <= 0 then
      continue;
    end if;

    v_runway := v_bal / v_burn;
    if v_runway < 5 then
      fails := fails || jsonb_build_object('check', v_prov || '-float',
        'detail', v_prov || ' balance $' || round(v_bal, 2) ||
                  ' covers ~' || round(v_runway, 1) || ' days of reservations ' ||
                  '($' || round(v_burn, 2) || '/day gross) — top up or every ' ||
                  'order fails as provider_unreachable');
    end if;
  end loop;

  -- (2) Credit-line rent sweep. Daily cron; 26h is the same multiple the
  -- winback and daily-credit checks use. `is null or` so a job that has never
  -- once succeeded fails LOUD.
  select updated_at into v_ts from app_config where key = 'line_rent_heartbeat';
  if v_ts is null or v_ts < now() - interval '26 hours' then
    fails := fails || jsonb_build_object('check', 'debit-credit-lines',
      'detail', 'credit-line rent sweep last ran ' || coalesce(v_ts::text, 'never') ||
                ' — credit-billed numbers are running free at the provider');
  end if;

  -- (3) Apple lapse STATE. reclaim_lapsed_lines() branch (d) suspends these at
  -- 6h; if one is still active at 12h the backstop has failed twice.
  select count(*) into v_lines from phone_lines
   where billing = 'apple'
     and status = 'active'
     and current_period_end is not null
     and current_period_end < now() - interval '12 hours';
  if v_lines > 0 then
    fails := fails || jsonb_build_object('check', 'apple-line-lapse',
      'detail', v_lines || ' Apple-billed line(s) still active >12h past period end — ' ||
                'no EXPIRED notification arrived and the reclaim backstop did not fire');
  end if;

  -- (4) Numbers that delete-account could NOT release (added 2026-08-18,
  -- same day). After the account cascades, phone_lines can no longer name
  -- them; app_config.unreleased_line_numbers is the only record. Pages until
  -- a human releases them at Telnyx and clears the key.
  select coalesce(jsonb_array_length(value), 0) into v_unreleased
    from app_config where key = 'unreleased_line_numbers';
  if coalesce(v_unreleased, 0) > 0 then
    fails := fails || jsonb_build_object('check', 'unreleased-line-numbers',
      'detail', v_unreleased || ' deleted account(s) left Telnyx number(s) unreleased — ' ||
                'see app_config.unreleased_line_numbers, release by hand, then clear the key');
  end if;

  return fails;
end;
$function$;

revoke execute on function public.watchdog_money_checks() from public, anon, authenticated;

-- 3. The wrapper, under the original name so the cron is untouched. The core
--    already wrote `app_config.watchdog` from ITS list; the wrapper re-writes
--    the row with the merged list so telegram-notify (which reads the row)
--    sees every check. `alerted`/`last_alert_at` are carried exactly as the
--    core carries them.
create or replace function public.run_watchdog()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  fails jsonb;
  extra jsonb;
  prev  jsonb;
begin
  fails := public.run_watchdog_core();
  extra := public.watchdog_money_checks();
  fails := fails || extra;

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
