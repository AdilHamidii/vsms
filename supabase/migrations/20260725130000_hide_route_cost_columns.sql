-- Stop publishing the margin book to anyone holding the publishable key.
--
-- ⚠️  DO NOT APPLY THIS UNTIL THE BUILD CONTAINING THE EXPLICIT-COLUMN
--     CatalogAPI IS LIVE AND ADOPTED.  See "Rollout" below.  This file is
--     committed ahead of time so the fix isn't lost; applying it early is a
--     TOTAL catalog outage for every user still on an older build.
--
-- WHY: `routes` is fetched UNAUTHENTICATED by CatalogAPI, and until today with
-- `select=*`. Verified live 2026-07-25 with nothing but the shipped
-- publishable key:
--   /rest/v1/routes?select=service_id,smoothed_cost_cents,last_cost_cents
--   -> [{"service_id":"vinted","smoothed_cost_cents":500,"last_cost_cents":500}, ...]
-- That is our wholesale cost per route — i.e. our entire margin structure,
-- readable by any competitor who unpacks the IPA. `anon` and `authenticated`
-- both hold table-wide SELECT, and RLS cannot help: it filters ROWS, not
-- COLUMNS. Column-level GRANTs are the only mechanism that can.
--
-- ROLLOUT (two phases — the ordering is the whole point):
--   1. SHIPPED FIRST (client): CatalogAPI now names its columns explicitly and
--      the `lastCostCents` field is gone from the Route model entirely (it was
--      decoded and never read by a single call site — pure leak, zero benefit).
--   2. THEN this migration. Postgres requires SELECT on EVERY column to answer
--      `SELECT *`, so the moment these revokes land, any client still sending
--      `select=*` gets `permission denied` for the whole routes query — no
--      routes, so `cost(for:country:)` returns nil for everything and the app
--      renders "Unavailable" on every service. Applying this before build
--      adoption breaks paying users who did nothing wrong.
--
-- Check adoption before applying, then apply and immediately re-run the curl
-- above expecting a 42501 permission-denied rather than data.
--
-- The service role is unaffected (it bypasses grants), so sync-prices,
-- sync-smspool and sync-smspva-operators keep reading and writing costs.

revoke select (last_cost_cents, smoothed_cost_cents, smspva_operator_cents)
  on public.routes from anon, authenticated;

-- Re-assert the safe surface explicitly, so a future table-wide GRANT can't
-- silently re-expose the costs by accident.
grant select (
  service_id, country_id, retail_credits, status,
  success_rate, rate_source, success_sample,
  premium_credits, smspva_operator, stock, last_checked_at
) on public.routes to anon, authenticated;

comment on column public.routes.smoothed_cost_cents is
  'WHOLESALE cost. NEVER expose to anon/authenticated — see migration '
  '20260725130000. CatalogAPI must never select this column.';
comment on column public.routes.last_cost_cents is
  'WHOLESALE cost. NEVER expose to anon/authenticated — see migration 20260725130000.';
comment on column public.routes.smspva_operator_cents is
  'WHOLESALE per-operator cost. NEVER expose to anon/authenticated — see migration 20260725130000.';
