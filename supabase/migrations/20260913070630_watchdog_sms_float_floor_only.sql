-- 5sim and HeroSMS: page on balance ONLY under the $5 floor. The runway check
-- (balance ÷ 7-day burn < 5 days) no longer fires for either.
--
-- Owner decision 2026-09-13: "don't mention 5sim or herosms balance in the
-- watchdog unless they're under 5 usd". At the owner's fund-on-demand cadence
-- the runway line was a standing page — 5sim sat at ~4 days of runway for most
-- of a week while well above the floor, re-paging every 6 hours and riding
-- along in every other page — which is the alert fatigue this repo records as
-- how the next real outage gets missed.
--
-- Scope. Exactly one clause changes: the runway `if` gains a provider guard.
-- The $5 floor branch (HUNK 2) and the dead-route branch ("no spend in 7 days
-- against N orders the week before") are untouched — the latter is about a
-- route going dead, not about a balance, and it is the only signal for that.
-- Telnyx keeps the runway condition as written; its burn is read from
-- `orders`, where no Telnyx row exists, so in practice only its $10 floor ever
-- fires — left as-is because the owner's instruction named the two SMS
-- providers only.
--
-- Same surgical shape as 20260913064717: read the live definition, replace
-- the one clause, assert it matched exactly once, execute.
do $$
declare
  d text;
  needle constant text := 'if v_runway < 5 then';
  replacement constant text := 'if v_prov not in (''5sim'',''herosms'') and v_runway < 5 then';
  n int;
begin
  d := pg_get_functiondef('public.watchdog_money_checks'::regproc);
  n := (length(d) - length(replace(d, needle, ''))) / length(needle);
  if n <> 1 then
    raise exception 'watchdog_money_checks: expected exactly one "%", found %', needle, n;
  end if;
  execute replace(d, needle, replacement);
end $$;
