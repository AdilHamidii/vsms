-- `iap_unknown` was never admitted by the telegram_events kind constraint, so
-- the alert written to catch an unrecognised Apple product COULD NEVER SEND.
--
-- `iap-verify` inserts `kind: 'iap_unknown'` as its escape hatch when
-- `creditsForProduct` returns null — the case where a new pack was added in App
-- Store Connect without updating `PRODUCT_TO_CREDITS`. The insert raises 23514,
-- supabase-js RETURNS the error rather than throwing, the call site destructures
-- only `{ data: claimed }`, and `if (claimed)` then skips the notify. So the
-- purchase is refused with a 400 AND the owner is never told.
--
-- Verified against the live constraint 2026-08-06: no version of it has ever
-- included this kind (20260721010000 signup/purchase/esim; 20260730180000
-- +email; 20260805170000 +line/line_refund/line_orphan/line_provision_failed).
--
-- This is the SECOND time a kind has been inserted that the constraint rejects,
-- and both were invisible for the same reason. If you add a `telegram_events`
-- kind in TypeScript, widen this constraint in the same commit.

alter table public.telegram_events
  drop constraint if exists telegram_events_kind_check;

alter table public.telegram_events
  add constraint telegram_events_kind_check
  check (kind = any (array[
    'signup', 'purchase', 'esim', 'email',
    'line', 'line_refund', 'line_orphan', 'line_provision_failed',
    'iap_unknown'
  ]));
