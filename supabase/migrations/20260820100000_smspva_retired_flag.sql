-- Write the `smspva_retired` flag the watchdog has been reading since 2026-08-03.
--
-- 🔴 THE BUG. `run_watchdog_core` guards its two SMSPVA freshness checks with
--
--     coalesce((select value->>'retired' from app_config
--               where key = 'smspva_retired'), 'false') <> 'true'
--
-- and **nothing has ever written that key**. `20260817100000_retire_smspva.sql`
-- retired the provider and unscheduled `relay-sync-smspva-operators` and
-- `relay-sync-smspva-conversions`, but never inserted the flag — so both checks
-- kept measuring the freshness of cursors belonging to jobs that no longer run.
-- Their timestamps froze on 2026-08-17 and the watchdog has been RED ever since,
-- permanently and unrecoverably: the cursors cannot move again by construction.
--
-- ⚠️ THE FAILURE MODE IS "A GUARD READING A KEY NOBODY WRITES", and it is silent
-- in both directions. The guard looks correct in review — the `coalesce` even
-- reads as deliberate, defensive style — and it fails OPEN, so a missing key
-- means *every* clause it protects stays armed rather than throwing. Nothing
-- anywhere reports "this key does not exist". **When you retire a subsystem,
-- write its flag in the SAME migration that unschedules its jobs.**
--
-- TWO CONSEQUENCES, both live until this lands:
--
--  1. **The pager is buried.** `telegram-notify` re-alerts on the failing set,
--     so the genuine `5sim-float` page ("balance covers ~3.8 days") arrives
--     alongside two permanent false positives. Worse, the "✅ recovered"
--     transition can never fire again, because `failing` can never return to
--     empty — which retires the one signal that says an outage ENDED.
--
--  2. **A winback cohort is structurally suppressed.**
--     `winback/index.ts` computes
--         claimSafe = balUsd >= 7.5 && failing === 0 && wdFresh
--     so with `failing` pinned at >= 2 the `stranded_credit_candidates` cohort
--     selects nobody on every daily run. That is the SIXTH time this cohort has
--     been closed by a gate nobody could see — see CLAUDE.md's winback section,
--     where the previous five are recorded. It is worth stating plainly: this
--     cohort has a history of being killed by predicates that are individually
--     defensible and jointly unsatisfiable.
--
-- WHAT THIS DOES. Writes the flag, nothing else. The guards were written
-- correctly; they were simply reading a key that did not exist. Un-retiring
-- SMSPVA is still `value = '{"retired": false}'` plus re-scheduling the two
-- crons, exactly as `20260803150000`'s header describes.
--
-- NOT client-readable: `app_config_read` whitelists only
-- maintenance / announcement / esim_paused / lines_paused, and this key is not
-- added to it. Do not add it — that policy is the only thing keeping provider
-- balances and the watchdog verdict off the publishable key.

insert into public.app_config (key, value)
values ('smspva_retired', jsonb_build_object(
  'retired', true,
  'retired_at', '2026-08-17T00:00:00Z',
  'note', 'Retired by 20260817100000_retire_smspva.sql; flag added 2026-08-20 '
       || 'after the watchdog had been red for three days reading it.'))
on conflict (key) do update
  set value = excluded.value,
      updated_at = now();
