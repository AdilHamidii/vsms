-- Close the wholesale cost-book leak on `routes` and `esim_plans`.
--
-- Both tables carry a `public read` RLS policy AND a table-wide SELECT grant
-- to anon/authenticated, and RLS filters ROWS, not COLUMNS. So our entire
-- per-route and per-plan wholesale cost — i.e. our margin structure — was
-- readable by anyone holding the publishable key, which ships inside the IPA.
-- `routes: public read` is `using (true)` for {anon,authenticated} and
-- `esim_plans: public read` is `using (true)` for PUBLIC, so `esim_plans`
-- reads with no account at all.
--
-- ── WHY THE DEFERRED MIGRATION 20260725130000 WAS A NO-OP ────────────────────
-- It did `revoke select (col...) on public.routes from anon, authenticated`.
-- A column REVOKE only edits `pg_attribute.attacl`; it cannot subtract from
-- `pg_class.relacl`. Verified live 2026-09-08 immediately before this file:
--   routes      relacl={... anon=rxtm/postgres, authenticated=rxtm/postgres ...}  colacl=NONE
--   esim_plans  relacl={... anon=rxtm/postgres, authenticated=rxtm/postgres ...}  colacl=NONE
-- Table grant present, zero column ACLs — so the old statement changed nothing
-- and `has_column_privilege('anon','public.routes','last_cost_cents','select')`
-- was still true. The only shape that works is: REVOKE THE TABLE GRANT, then
-- GRANT the safe columns back explicitly.
--
-- That old file is also wrong in two further ways and must NOT be applied:
-- it names only 3 of the 7 cost columns `routes` now has (herosms_cost_cents,
-- herosms_smoothed_cost_cents, fivesim_cost_cents and
-- fivesim_smoothed_cost_cents were all added after it was written), and its
-- re-grant list omits `success_codes` and `real_sim_only`, which the shipped
-- client decodes. Superseded by this migration; see the comment at its foot.
--
-- ── WHY IT IS SAFE TO APPLY NOW (the adoption gate) ──────────────────────────
-- Postgres needs SELECT on EVERY column to answer `select=*`, so this breaks
-- any shipped build still sending it — the catalog would fail to load and every
-- price would render "Unavailable". Measured from the edge logs (24h to
-- 2026-09-08 09:40Z), grouped by the app's own User-Agent `VirtualSIM/<build>`:
--
--   build 50 (2.9) 36 IPs · 52 (2.10) 27 · 48 (2.7) 4 · 49 (2.8) 1 ·
--   53 (2.11 TF) 1 · 55 (dev) 1 · 42 (2.2) 1      — 71 distinct client IPs
--
--   /rest/v1/routes      : 0 requests with select=* from ANY build.
--                          Every publishable-key GET carries the identical
--                          11-column list, build 42 included.
--   /rest/v1/esim_plans  : 0 requests with select=*. One 10-column list only.
--
-- The explicit column lists shipped in build 19 (1.6, 2026-07-25 for routes /
-- 2026-07-30 for esim_plans), so every build in the field predates nothing.
-- `select=*` DOES still arrive on /rest/v1/services and /rest/v1/countries
-- from one device on build 42 (2.2) — those tables are therefore deliberately
-- NOT touched here, and neither carries a wholesale column (`services.cost` is
-- the seed RETAIL credit price the client decodes).
--
-- The service role bypasses grants entirely, so every sync, poller and edge
-- function keeps reading and writing costs unchanged.

-- ── routes ──────────────────────────────────────────────────────────────────
revoke select on public.routes from anon, authenticated;

-- Exactly the columns `Route` decodes in CatalogAPI.swift, and no others.
-- Derived from the model + the one call site (VirtualSIM/Networking/
-- CatalogAPI.swift:90) and cross-checked against the live query string.
grant select (
  service_id,
  country_id,
  retail_credits,
  status,
  success_rate,
  rate_source,
  success_sample,
  success_codes,
  premium_credits,
  real_sim_only,
  pool_rate_pct
) on public.routes to anon, authenticated;

-- ── esim_plans ──────────────────────────────────────────────────────────────
revoke select on public.esim_plans from anon, authenticated;

-- Exactly the columns `EsimPlan` decodes (VirtualSIM/Models/EsimModels.swift:30),
-- matching EsimPlansAPI.columns.
grant select (
  id,
  name,
  country_code,
  region,
  data_mb,
  validity_days,
  speed,
  extendable,
  retail_credits,
  status
) on public.esim_plans to anon, authenticated;

-- `esim_plans: public read` is granted to PUBLIC, so make sure the PUBLIC
-- pseudo-role holds no table SELECT of its own that would re-open the whole
-- row. (No-op today; the same class of trap as the PUBLIC EXECUTE default.)
revoke select on public.esim_plans from public;
revoke select on public.routes from public;

-- ── Document the invariant on the columns themselves ────────────────────────
comment on column public.routes.last_cost_cents is
  'WHOLESALE. Never grant to anon/authenticated — see 20260908160000.';
comment on column public.routes.smoothed_cost_cents is
  'WHOLESALE. Never grant to anon/authenticated — see 20260908160000. '
  'CatalogAPI must never select this column.';
comment on column public.routes.smspva_operator_cents is
  'WHOLESALE (per-operator). Never grant to anon/authenticated — see 20260908160000.';
comment on column public.routes.herosms_cost_cents is
  'WHOLESALE (raw, read by the order-time margin gate). Never grant to anon/authenticated.';
comment on column public.routes.herosms_smoothed_cost_cents is
  'WHOLESALE (ratcheted). Never grant to anon/authenticated.';
comment on column public.routes.fivesim_cost_cents is
  'WHOLESALE. Never grant to anon/authenticated.';
comment on column public.routes.fivesim_smoothed_cost_cents is
  'WHOLESALE (ratcheted). Never grant to anon/authenticated.';
comment on column public.esim_plans.last_cost_cents is
  'WHOLESALE. Never grant to anon/authenticated — see 20260908160000.';
comment on column public.esim_plans.smoothed_cost_cents is
  'WHOLESALE (ratcheted). Never grant to anon/authenticated — see 20260908160000.';

comment on table public.routes is
  'Client SELECT is COLUMN-GRANTED (20260908160000), not table-granted. '
  'A blanket `grant select on public.routes to anon` re-publishes the whole '
  'wholesale cost book. To let the client read a NEW column, add it to the '
  'column grant AND to CatalogAPI''s explicit list — never widen the table.';
comment on table public.esim_plans is
  'Client SELECT is COLUMN-GRANTED (20260908160000), not table-granted. '
  'Never restore a table-wide grant — it re-publishes last_cost_cents and '
  'smoothed_cost_cents to anyone holding the publishable key.';
