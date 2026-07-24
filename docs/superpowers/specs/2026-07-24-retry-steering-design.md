# Retry steering — fresh numbers + operator rotation on SMS retries

**Date:** 2026-07-24 · **Scope:** backend only (`create-order`) · **Status:** approved

## Problem

When a number receives no code, users cancel and immediately retry. Measured
2026-07-24 (Betano/Bulgaria, one paying user, 9 attempts in 15 minutes, 0
delivered):

- SMSPVA re-issued the **same number** on retry — 9 orders drew only 6 distinct
  numbers. A number that just proved dead gets sold to the same user again.
- Every attempt pinned the **same carrier** (the route's `smspva_operator`), so
  when that carrier's pool is dead for a service, retries 2–N have roughly the
  same odds as attempt 1.

71% of all cancels (30-day window) happen under 2 minutes and feed this loop.
The retry is the one moment we *know* the previous number/pool failed; today we
ignore that knowledge.

## Non-goals

- No iOS changes (waiting-screen UX is a separate, later effort).
- No measurement/`success_rate` changes (offered, declined for now).
- No `blockNumber`-on-cancel provider feedback (undocumented semantics; would
  need a paid live test first).
- No schema change: `orders.smspool_pool` already records the operator that
  actually filled each SMSPVA order (set from `Reservation.pool`), and
  `orders.smspva_number` records the number. Both are queryable history.

## Design

All changes live in `supabase/functions/create-order/index.ts`.

### 1. Retry context (one read, before `begin_order`)

Query this user's orders for the same service from the last 60 minutes:

- `recentNumbers` — the `smspva_number` values already drawn (any country).
- `triedOperators` — `smspool_pool` values of **canceled** orders for this
  exact (service, country) whose `closed_at` is within the last 15 minutes,
  provider `smspva`.

Both default to empty on any error (guardrail: this feature only ever narrows
choices; it must never fail an order).

### 2. Operator rotation

Compute the intended SMSPVA pin exactly as today (premium → route operator,
standard → `standardCarrier`). If that pin is in `triedOperators`:

- Fetch `getCountryPrices(country.smspva_code)`, find the row for the service
  code, and read its `po` (operator → USD price) map.
- Eligible alternates: not in `triedOperators`, not a `Donor*` VoIP pool
  (case-insensitive prefix), price ≤ `maxCostUsd` (the existing margin
  ceiling). Pick the cheapest.
- No eligible alternate (or the fetch fails): **standard** falls back to
  unpinned (random fill — at least a different pool than the one that just
  failed); **premium** keeps the route's pinned operator — never degrade the
  real-SIM promise.
- When a premium order is rotated, the margin pre-check uses the alternate's
  live price instead of the cached `smspva_operator_cents` (the post-reserve
  actual-cost enforcement is unchanged and still binds either way).

### 3. Fresh-number guarantee

After a successful `reserve()`: if the returned number is in `recentNumbers`,
`release()` the reservation and reserve again — at most 3 reserve attempts
total. The loop runs only on a *successful* reserve with a duplicate number;
any reserve error takes the existing error path untouched. If every attempt
collides, keep the last number (a duplicate is still better than a failed
order).

## Guardrails

- Retry-context read, price-map fetch, and duplicate-release are best-effort;
  every failure degrades to today's exact behavior.
- No new error codes → nothing to add to `APIError.swift`.
- Added latency: one cheap SQL read per order; the rotation fetch and
  re-reserve loop run only on the retry path.
- `begin_order` dedupe untouched (it guards concurrent open orders only).

## Verification

1. `deno check` on the edited function (or review-only if deno is absent).
2. Deploy `create-order`, then live E2E with a disposable user on a cheap
   route: order → cancel → re-order; confirm via SQL that attempt 2 drew a
   different number and a different (or null) `smspool_pool`, both refunds
   landed, and the ledger reconciles. Wholesale exposure < $1, refunded.
