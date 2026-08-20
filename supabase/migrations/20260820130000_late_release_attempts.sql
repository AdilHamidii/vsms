-- ─────────────────────────────────────────────────────────────────────────────
-- Bound the late-watch release retry EXPLICITLY, instead of with a flag that is
-- either always-set or always-clear
-- ─────────────────────────────────────────────────────────────────────────────
--
-- `poll-active-orders`' late-watch sweep is the ONLY thing that ever hands a
-- cancelled number back to the provider (`cancel-order` stopped releasing
-- synchronously on 2026-07-27). When the watch window closes with no code it
-- calls `markDead()` — cancel, then ban — to reclaim up to ~$3.50 of wholesale.
--
-- Two failure modes, and the code has now been wrong in BOTH directions using
-- only `late_watch_until` to decide:
--
--   * markDead FIRST, clear the flag second: a failed clear leaves
--     `late_watch_until <= now()` true forever, so every minutely run
--     re-cancels-and-bans an already-dead number at the provider, for the life
--     of the row. Unbounded, compounding, and it starves the 50-row budget this
--     sweep shares with real code rescues.
--   * clear FIRST, markDead second (`20260819`, the current code): the DB
--     failure is bounded, but the PROVIDER failure — the likelier of the two —
--     becomes a PERMANENT FORFEIT with no retry. During a provider outage every
--     expiring watched number forfeits ~$3.50 instead of one.
--
-- A single boolean-ish flag cannot express "retry, but not forever". This
-- column can: `late_release_attempts` counts markDead attempts, is incremented
-- BEFORE the provider call, and is monotone — so the number of provider calls
-- a row can ever cause is bounded by the cap in `poll-active-orders`
-- (`MAX_LATE_RELEASE_ATTEMPTS`), no matter what fails or how often.
--
-- Nothing decodes this column client-side (`Order` in Swift ignores unknown
-- keys), and it is never read anywhere except that sweep.
-- ─────────────────────────────────────────────────────────────────────────────

alter table public.orders
  add column if not exists late_release_attempts integer not null default 0;

comment on column public.orders.late_release_attempts is
  'markDead() attempts made by poll-active-orders'' late-watch sweep. Incremented BEFORE the provider call so the retry is bounded even when the provider or the DB write fails; the sweep gives up and clears late_watch_until once it reaches MAX_LATE_RELEASE_ATTEMPTS.';
