-- 20260808180000_stamp_default_landed.sql
--
-- Two changes, one cause. 20260808170000 excluded default-landed orders from
-- route/service/country evidence and backfilled the flag for FIRST orders only.
-- Profiling the survivors showed that was too narrow, and that a one-time
-- backfill decays.
--
--
-- ── 1. The cohort includes RETRIES, not just first orders ────────────────────
--
-- 6 of the 9 orders that survived the first backfill on deliveroo/us were
-- immediate re-orders by the same default-landed users — account age 2–8
-- minutes, prior_orders 1–2, each already carrying a `from_default = true`
-- sibling. They are the same event: the app pre-selected a service the user
-- never came for, the number went nowhere, they tapped again, and the second
-- number went nowhere either. CLAUDE.md's own account of the 2026-08-04
-- investigation counted them ("16 of 16 subsequent orders to olx — from 9
-- different users"); the first backfill simply did not.
--
-- The first-order criterion is therefore replaced by an account-age one:
-- under 60 minutes old at order time. It SUBSUMES the old predicate (a first
-- order under 30 minutes is also an order under 60) and adds the same-session
-- retries, so this statement is a strict widening, never a reinterpretation.
--
-- ⚠️ Account age is what keeps the veteran account out. The dev account's
-- deliveroo/us orders sit at ~34,000–40,000 minutes of account age with 21+
-- prior orders; they are deliberate, and they stay unflagged. (They are also
-- already excluded from evidence by the dev-user filter, so this changes
-- nothing for them either way — but the predicate must not depend on that.)
--
--
-- ── 2. A one-time backfill DECAYS ────────────────────────────────────────────
--
-- `from_default` is stamped by the CLIENT, and only 2.0+ does it. 2.0 is still
-- in review, so every order placed today comes from a 1.9 client and arrives
-- NULL — two of the retries above were placed on 2026-08-08. Contamination
-- re-accrues every day the old build is in the field, which would have left
-- the country badge drifting back out of true between manual backfills.
--
-- `stamp_default_landed()` is the bridge: the same statement, run hourly from
-- `sync-prices`' maintenance list (no new pg_cron job) until 2.0+ dominates
-- the install base. The `from_default is null` guard makes it a permanent
-- no-op on anything a client has already stamped — a 2.0 client that recorded
-- FALSE knows something this heuristic does not and must always win — so it is
-- safe to leave running forever rather than needing to be remembered and
-- removed.
--
-- 🔴 THE ROUTE LIST IS OBSERVED, NOT DERIVED. These are the three pairs
-- `AppState.bestStarter` actually resolved to across the grant sizes that were
-- live from 2026-07-26 (1 cr -> olx/us, 2–3 cr -> deliveroo/ge, 3 cr ->
-- deliveroo/us). If the starter pick moves — a new grant size, a re-ranked
-- candidate list, a catalog change that reshuffles pool rates — this list is
-- stale and silently stops catching the new default. See CLAUDE.md, "The grant
-- size decides which ONE route new users land on". It is deliberately a
-- hardcoded list rather than a live call to the ranker: the ranker's answer
-- TODAY is not the answer that was in the field when a historical order was
-- placed, and an evidence filter that changes retroactively is worse than one
-- that is merely out of date.

create or replace function public.stamp_default_landed()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_stamped integer;
begin
  with upd as (
    update public.orders o
    set from_default = true
    -- NEVER overwrite a client-stamped value. NULL means "not recorded"
    -- (pre-2.0); false means a 2.0+ client positively said the user chose
    -- this service. Only NULL is ours to fill in.
    where o.from_default is null
      -- the observed default-landing set; see the header before editing
      and (o.service_id, o.country_id) in (('olx','us'), ('deliveroo','us'), ('deliveroo','ge'))
      -- the grant-cohort era begins here
      and o.created_at >= timestamptz '2026-07-26'
      -- account age at order time. Catches the first order AND the
      -- same-session retries that follow it, which are the same event.
      and exists (
        select 1 from auth.users u
        where u.id = o.user_id
          and o.created_at - u.created_at < interval '60 minutes'
      )
    returning 1
  )
  select count(*) into v_stamped from upd;
  return v_stamped;
end;
$function$;

comment on function public.stamp_default_landed() is
  'Bridge until 2.0+ clients stamp orders.from_default themselves. Flags orders '
  'on the app''s observed default-landing routes placed by accounts under 60 '
  'minutes old. Never overwrites a client-stamped value, so it is a permanent '
  'no-op once 2.0 dominates. Called hourly from sync-prices.';

-- Service-role only. `revoke ... from anon, authenticated` alone is a NO-OP
-- while PUBLIC holds the default EXECUTE grant that CREATE FUNCTION hands out,
-- so PUBLIC must be named explicitly — this repo shipped `revenue_snapshot`
-- world-callable with a revoke line right there in the migration.
revoke execute on function public.stamp_default_landed() from public, anon, authenticated;

-- ── The broadened backfill ───────────────────────────────────────────────────
-- Run through the function rather than repeating its UPDATE here, so the
-- one-time catch-up and the hourly job can never drift apart. A constant
-- duplicated across two places in this repo has drifted every single time.
select public.stamp_default_landed();
