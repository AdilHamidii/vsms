-- Provider float: page on an ABSOLUTE balance as well as on runway.
-- OWNER DECISION 2026-09-08 — alert at 5sim < $5.00, HeroSMS < $5.00,
-- Telnyx < $10.00.
--
-- `watchdog_money_checks()` only ever measured RUNWAY (balance ÷ 7-day burn
-- < 5 days). That is the right check for "healthy balance, about to be
-- spent", and it is kept untouched — but it cannot answer "nearly empty",
-- because a provider with LOW burn divides its way to a large runway: at
-- $0.20/day of spend, $2.00 reads as 10 days and pages nothing while a single
-- $1.50 route is already unfundable. The zero-burn branch below it does not
-- catch that either — it fires on the ORDER history, not on the money.
--
-- Telnyx is checked here for the first time. It is the one provider that
-- bills MONTHLY and RECURRING, `telnyx_health` has been written minutely by
-- poll-active-orders since 2026-08-06, and nothing in the watchdog has ever
-- read it: a dry Telnyx balance means an EXISTING subscriber's $1/month
-- number cannot be renewed, which is why its level is DOUBLE the SMS one.
--
-- The pager half of this decision lives in `poll-active-orders/index.ts`
-- (BALANCE_ALERT_USD) and the display half in `_shared/opsFormat.ts`
-- (LOW_BALANCE_USD / TELNYX_LOW_USD). Three copies of the same number, which
-- is exactly the drift class this repo keeps paying for — change them
-- together.
--
-- Procedure per the standing rule (a one-line refactor that changes a
-- watchdog threshold is a monitoring outage): `pg_get_functiondef` captured
-- in full and diffed clause by clause against the live definition. EXACTLY
-- TWO hunks differ — the `telnyx` addition to the loop's provider array and
-- the absolute-balance block after the freshness guard. Every other clause,
-- including the 20260821130000 zero-burn branch, the runway text, the
-- credit-line rent heartbeat, the Apple-lapse check and the unreleased-number
-- check, is byte-identical.
--
-- Check NAMES are unchanged (`<provider>-float`): `_shared/tgAlert.ts`
-- resolves its Telegram copy from the `-float` SUFFIX, so a new name would
-- silently fall through to the raw-detail branch. `telnyx-float` therefore
-- inherits that copy for free.

create or replace function public.watchdog_money_checks()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  fails jsonb := '[]'::jsonb; v_ts timestamptz; v_bal numeric; v_burn numeric;
  v_runway numeric; v_lines int; v_prov text; v_unreleased int; v_floor numeric;
begin
  -- HUNK 1: telnyx joins the loop. Its health key has the same shape
  -- ({balance_usd, checked_at}) and the same minutely writer.
  for v_prov in select unnest(array['5sim','herosms','telnyx']) loop
    select (value->>'balance_usd')::numeric, (value->>'checked_at')::timestamptz
      into v_bal, v_ts from app_config where key = v_prov || '_health';
    if v_bal is null or v_ts is null or v_ts < now() - interval '15 minutes' then continue; end if;
    -- HUNK 2: the absolute floor, owner decision 2026-09-08. Fails CLOSED in
    -- the useful direction — an unknown provider gets the $5 SMS level rather
    -- than no check at all. `continue` afterwards so one provider never
    -- produces two entries under the same check name (the runway line below
    -- would be redundant on a balance this low, and a duplicated check name
    -- makes the recovery transition ambiguous).
    v_floor := case when v_prov = 'telnyx' then 10 else 5 end;
    if v_bal < v_floor then
      fails := fails || jsonb_build_object('check', v_prov || '-float',
        'detail', v_prov || ' balance $' || round(v_bal,2) || ' is under the $' ||
                  round(v_floor,2) || ' floor — top up');
      continue;
    end if;
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

revoke execute on function public.watchdog_money_checks() from public, anon, authenticated;

do $$
begin
  if has_function_privilege('anon', 'public.watchdog_money_checks()', 'execute') then
    raise exception 'watchdog_money_checks is callable by anon';
  end if;
end $$;

comment on function public.watchdog_money_checks() is
  'Watchdog money checks. Provider float pages on an ABSOLUTE floor '
  '(5sim/HeroSMS $5, Telnyx $10 — owner decision 2026-09-08) and, above it, '
  'on runway < 5 days. Keep the floors in lockstep with BALANCE_ALERT_USD in '
  'poll-active-orders and LOW_BALANCE_USD / TELNYX_LOW_USD in opsFormat.ts.';
