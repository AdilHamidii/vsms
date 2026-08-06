-- The signup credit grant is removed permanently (owner decision, 2026-08-04).
--
-- WHY. The grant was never really "how much a new user can buy" — it decided
-- which single route the app pre-selected for them, and the whole cohort went
-- there (grant 1 -> olx/us, grant 3 -> deliveroo/us). Those cohorts ordered and
-- then never submitted the number anywhere: proven on 2026-08-04 by taking a
-- cancelled deliveroo/us number off the provider dashboard and completing a
-- real signup with it, which delivered a code immediately. The pool was fine;
-- the orders were free numbers nobody had a reason to use.
--
-- The retention data already pointed the same way: 10 of 14 lifetime buyers
-- purchased BEFORE their first order ever, median signup -> purchase 3 minutes.
-- Purchase is a paywall event, not a reward for a proven delivery. So paying
-- first is how this product actually converts, and a user who has paid has a
-- reason to use the number.
--
-- SAFE AT ZERO, verified before applying:
--   * handle_new_user() regex-guards, clamps to [0,50] and defaults to 0. It
--     never calls wallet_credit (which RAISES on a non-positive amount) — it
--     inserts the wallets row directly, ALWAYS, including at 0. Signup cannot
--     break.
--   * At 0 it also skips the signup_grants tombstone entirely, so no identity
--     is burned for a grant that never happened. Re-enabling later still pays
--     everyone who has not actually been paid.
--   * wallet_transactions is only written when the amount is > 0, so the ledger
--     invariant sum(delta) = balance holds with no zero-delta rows.
--   * app_config.daily_credit_enabled is already false, so this is not
--     undermined by the daily faucet.
--   * The referral grants (2 joiner / 5 referrer) are untouched and remain
--     live. They are dormant in practice — profiles.referred_by is 0 rows, the
--     feature has never been used once — but they are a real second door to
--     free credits. If they are ever meant to close too, that is a separate
--     decision and a separate migration.
--
-- CLIENT COUPLING — the thing this broke last time. Onboarding page 2 rendered
-- a hardcoded "+3 credits" card, so zeroing the grant on 2026-08-03 turned the
-- app's first pre-sign-in screen into a promise the server would not keep. That
-- card is deleted in the same change as this migration (OnboardingScreen.swift,
-- shipping as build 30). Nothing on that screen may quote a credit amount
-- again: it runs before sign-in, so it cannot read app_config, while this value
-- changes without a release — it has been 0, 1, 3 and 5.
--
-- ROLLBACK is one statement: set the value back to {"credits": N}. It takes
-- effect on the very next signup with no deploy and no release.

insert into public.app_config (key, value)
values ('signup_bonus_credits', '{"credits": 0}'::jsonb)
on conflict (key) do update set value = excluded.value;

do $$
declare v_grant integer;
begin
  -- Assert through the SAME expression handle_new_user() evaluates, rather
  -- than trusting the row we just wrote. A value this function would reject
  -- (non-numeric, negative, over 50) silently falls back to 0 there, so
  -- reading the raw jsonb would not prove what a new user actually receives.
  select case
           when c.value->>'credits' ~ '^[0-9]{1,9}$'
             then least(greatest((c.value->>'credits')::int, 0), 50)
             else 0
         end
    into v_grant
    from public.app_config c
   where c.key = 'signup_bonus_credits';

  if coalesce(v_grant, 0) <> 0 then
    raise exception 'signup bonus is %, expected 0', v_grant;
  end if;
end $$;
