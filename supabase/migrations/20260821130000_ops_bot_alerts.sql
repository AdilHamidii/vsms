/* 20260821130000_ops_bot_alerts.sql — Telegram ops-bot ALERT overhaul.
 *
 * Two changes, both small and both load-bearing:
 *
 * 1. telegram_events.kind gains four values. Three are new alerts
 *    (trial_soon, trial_off, route_fill); the fourth (line_consumption)
 *    splits a dedupe COLLISION that has been silently eating alerts.
 *
 * 2. watchdog_money_checks()'s {provider}-float check stops going quiet
 *    exactly when a route dies.
 *
 * Note the file deliberately opens with a block comment, not a `--` line:
 * `supabase db query --file` parses a leading `--` as a CLI flag.
 */

-- ────────────────────────────────────────────────────────────────────────────
-- 1. telegram_events.kind
--
-- ⚠️ EVERY EXISTING VALUE IS REPEATED VERBATIM. This constraint has been
-- widened five times and each widening re-states the whole list; dropping one
-- by accident does not fail loudly — the INSERT is rejected with 23514 inside
-- a claim helper that swallows it, so the alert simply never arrives. That has
-- already happened once here (`iap_unknown`, fixed in 20260806090000).
--
-- The four additions:
--   trial_soon       a free trial converts within 24h (telegram-notify)
--   trial_off        a trial whose auto-renew was switched off (telegram-notify)
--   route_fill       ≥3 orders on one route closed with no number (telegram-notify)
--   line_consumption Apple CONSUMPTION_REQUEST (apple-notifications)
--
-- 🔴 line_consumption exists to fix a real, silent collision. Both the REFUND
-- branch and the CONSUMPTION_REQUEST branch of apple-notifications claimed
-- (kind='line_refund', ref=originalTransactionId) — the same pair — so
-- whichever notification arrived first took the row and the other was dropped
-- with no trace. "A refund has been REQUESTED, you have 12h" and "the money
-- has GONE BACK" are different urgencies with different actions, and either
-- could eat the other. They now use different kinds AND refs carrying Apple's
-- notificationUUID, which is present even on consumable notifications whose
-- originalTransactionId is null.
alter table public.telegram_events drop constraint if exists telegram_events_kind_check;
alter table public.telegram_events add constraint telegram_events_kind_check
  check (kind = any (array[
    'signup', 'purchase', 'esim', 'email', 'line', 'line_refund',
    'line_orphan', 'line_provision_failed', 'iap_unknown', 'line_event',
    'mail_sub', 'mail_sub_event',
    -- added 20260821130000
    'trial_soon', 'trial_off', 'route_fill', 'line_consumption'
  ]));

-- ────────────────────────────────────────────────────────────────────────────
-- 2. watchdog_money_checks() — the {provider}-float check.
--
-- Regenerated from `pg_get_functiondef('public.watchdog_money_checks')` and
-- diffed clause by clause, per the standing rule in CLAUDE.md ("a one-line
-- refactor that changes a watchdog threshold is a monitoring outage"). EXACTLY
-- ONE hunk differs: the `if v_burn <= 0 then continue; end if;` line. The other
-- three checks (debit-credit-lines, apple-line-lapse, unreleased-line-numbers)
-- and the runway arithmetic are byte-identical to the deployed definition.
--
-- WHAT WAS WRONG. The runway check divides by the 7-day burn, so it skipped
-- any provider with zero burn — written as divide-by-zero defence, and true as
-- far as it goes. But zero burn over seven days IS the symptom of total route
-- death: a provider whose orders have all stopped is precisely the one that
-- pages nobody. Same shape as the SMSPVA freshness gate and the daily-credit
-- gate: each predicate individually defensible, jointly unsatisfiable.
--
-- WHAT IT DOES NOW. Zero burn with ≥1 numbered order in the PRIOR week (the
-- 7–14 day window) is itself the alert: we were selling, and we have stopped.
-- Zero burn with no prior orders stays silent — that is a provider nobody has
-- used in a fortnight, which is a business fact, not an outage, and paging on
-- it would be the alert-fatigue this check already suffers from elsewhere.
create or replace function public.watchdog_money_checks()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  fails jsonb := '[]'::jsonb; v_ts timestamptz; v_bal numeric; v_burn numeric;
  v_runway numeric; v_lines int; v_prov text; v_unreleased int;
begin
  for v_prov in select unnest(array['5sim','herosms']) loop
    select (value->>'balance_usd')::numeric, (value->>'checked_at')::timestamptz
      into v_bal, v_ts from app_config where key = v_prov || '_health';
    if v_bal is null or v_ts is null or v_ts < now() - interval '15 minutes' then continue; end if;
    select coalesce(sum(actual_cost_cents),0)/100.0/7.0 into v_burn from orders
     where provider = v_prov and smspva_number is not null and created_at >= now() - interval '7 days';
    -- ── the one changed hunk (20260821130000) ──────────────────────────────
    -- Was: `if v_burn <= 0 then continue; end if;` — silent exactly when a
    -- route has gone completely dead. A nested declare block keeps the change
    -- to this hunk alone rather than touching the function's declare list.
    if v_burn <= 0 then
      declare v_prior int;
      begin
        select count(*) into v_prior from orders
         where provider = v_prov and smspva_number is not null
           and created_at >= now() - interval '14 days'
           and created_at <  now() - interval '7 days';
        if v_prior > 0 then
          fails := fails || jsonb_build_object('check', v_prov || '-float',
            'detail', 'no spend in 7 days against ' || v_prior ||
                      ' orders the week before — route may be dead');
        end if;
      end;
      continue;
    end if;
    -- ── end changed hunk ───────────────────────────────────────────────────
    v_runway := v_bal / v_burn;
    if v_runway < 5 then
      fails := fails || jsonb_build_object('check', v_prov || '-float',
        'detail', v_prov || ' balance $' || round(v_bal,2) || ' covers ~' || round(v_runway,1) ||
                  ' days of reservations ($' || round(v_burn,2) || '/day gross) — top up or every order fails as provider_unreachable');
    end if;
  end loop;
  select updated_at into v_ts from app_config where key = 'line_rent_heartbeat';
  if v_ts is null or v_ts < now() - interval '26 hours' then
    fails := fails || jsonb_build_object('check','debit-credit-lines',
      'detail','credit-line rent sweep last ran '||coalesce(v_ts::text,'never')||' — credit-billed numbers are running free at the provider');
  end if;
  select count(*) into v_lines from phone_lines
   where billing='apple' and status='active' and current_period_end is not null
     and current_period_end < now() - interval '12 hours';
  if v_lines > 0 then
    fails := fails || jsonb_build_object('check','apple-line-lapse',
      'detail',v_lines||' Apple-billed line(s) still active >12h past period end — no EXPIRED notification arrived and the reclaim backstop did not fire');
  end if;
  -- (4) Numbers that delete-account could NOT release. After the account
  -- cascades, phone_lines can no longer name them; this list is the only
  -- record. Pages until a human releases them at Telnyx and clears the key.
  select coalesce(jsonb_array_length(value), 0) into v_unreleased
    from app_config where key = 'unreleased_line_numbers';
  if coalesce(v_unreleased, 0) > 0 then
    fails := fails || jsonb_build_object('check','unreleased-line-numbers',
      'detail', v_unreleased || ' deleted account(s) left Telnyx number(s) unreleased — see app_config.unreleased_line_numbers, release by hand, then clear the key');
  end if;
  return fails;
end; $function$;

-- A `revoke ... from anon, authenticated` alone is a NO-OP while PUBLIC holds
-- the grant CREATE FUNCTION hands out by default, and anon/authenticated are
-- members of PUBLIC. Revoke from PUBLIC explicitly; assert with
-- has_function_privilege('anon', oid, 'execute') = false.
revoke execute on function public.watchdog_money_checks() from public, anon, authenticated;
grant execute on function public.watchdog_money_checks() to service_role;
