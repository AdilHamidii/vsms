-- 5sim per-route state: wholesale cost, stock, and THE POOL WE BUY FROM.
--
-- Two groups of columns, deliberately named differently, because they have
-- different lifetimes and different audiences.
--
-- `fivesim_*` — provider-specific, server-only, same shape as `herosms_*`.
-- `pool_*`    — PROVIDER-NEUTRAL, and two of them ship to the client.
--
-- The neutral naming is not tidiness. Every provider-prefixed column this
-- codebase has added became a liability the moment a route was re-homed:
-- `last_cost_cents` (SMSPVA's) was silently used as HeroSMS's cached cost and
-- produced charge-and-refund on every affected order, and 305 SMSPVA `seeded`
-- rates were stranded on HeroSMS routes where no sync could ever clear them
-- (20260803121000). The pool identity and its published rate are concepts that
-- outlive any one provider, so they get names that do too.
--
-- PRICING LOCKSTEP (owner: 10x margin, 2026-08-03). sync-5sim's CREDIT_DIVISOR
-- must be 0.03 and create-order's MIN_MARGIN_BY_PROVIDER['5sim'] must be 10.0,
-- because the order-time ceiling is computed as credits * NET_USD_PER_CREDIT /
-- MIN_MARGIN and that has to equal the divisor the route was priced with, to
-- the cent:  0.30 / 10 = 0.03.  Changing one alone either blocks honest routes
-- or leaks margin on every order.

alter table public.routes add column if not exists fivesim_cost_cents          integer;
alter table public.routes add column if not exists fivesim_smoothed_cost_cents integer;
alter table public.routes add column if not exists fivesim_stock               integer;
alter table public.routes add column if not exists fivesim_checked_at          timestamptz;

alter table public.routes add column if not exists pool_operator      text;
alter table public.routes add column if not exists pool_rate_pct      smallint;
alter table public.routes add column if not exists pool_rate_window   text;
alter table public.routes add column if not exists pool_rate_checked_at timestamptz;

comment on column public.routes.fivesim_cost_cents is
  'RAW 5sim wholesale for the chosen pool, cents. What the order-time margin gate reads -- deliberately NOT smoothed, because smoothing the gate input hides drift.';
comment on column public.routes.fivesim_smoothed_cost_cents is
  'Ratcheted cost (rises apply immediately, only falls are damped) -- retail_credits is derived from THIS. A symmetric average once put 4,384 routes under wholesale in a single run.';
comment on column public.routes.fivesim_stock is
  'Numbers available in the chosen pool at last sync. NULL = never synced, 0 = synced and empty.';
comment on column public.routes.pool_operator is
  'Ordered, comma-separated 5sim operator slugs, BEST FIRST (e.g. "virtual51,virtual34,any"). create-order tries them in order. 5sim buys one operator per path segment, so this is a fallback chain, not a set -- unlike herosms_real_operators, which getNumberV2 accepts as a single list.';
comment on column public.routes.pool_rate_pct is
  'The chosen pool''s published 30-day delivery rate (5sim rate720), 0-100. NULL = the provider publishes no rate for it, which means "too few orders", NEVER "bad" -- it must render as absent and must never be coerced to 0.';
comment on column public.routes.pool_rate_window is
  'Which window pool_rate_pct came from, e.g. "720h". Recorded because 5sim''s own site shows the MAX across seven windows and its Statistics tab shows rate72, so a number without its window is not interpretable.';

-- Freshness lookups and the watchdog check are always provider-scoped.
create index if not exists routes_fivesim_checked_idx
  on public.routes (fivesim_checked_at)
  where provider = '5sim';

-- Wholesale must never reach a client. Mirrors the existing revoke for
-- last_cost_cents / smoothed_cost_cents / smspva_operator_cents.
--
-- ⚠️ Honest caveat: `routes` carries a TABLE-level select grant plus a "public
-- read" RLS policy, and a column-level REVOKE only edits pg_attribute.attacl --
-- it cannot subtract from pg_class.relacl. So this statement is a NO-OP today,
-- exactly as documented in CLAUDE.md for the deferred 20260725130000. It is
-- included so the column is already named in the right place when that grant is
-- finally narrowed to an explicit column list; it is NOT load-bearing, and
-- `herosms_cost_cents` is readable by anon today for the same reason.
revoke select (fivesim_cost_cents, fivesim_smoothed_cost_cents)
  on public.routes from anon, authenticated;

do $$
declare n int;
begin
  select count(*) into n from information_schema.columns
   where table_schema='public' and table_name='routes'
     and column_name in ('fivesim_cost_cents','fivesim_smoothed_cost_cents',
                         'fivesim_stock','fivesim_checked_at','pool_operator',
                         'pool_rate_pct','pool_rate_window','pool_rate_checked_at');
  if n <> 8 then raise exception '5sim route columns incomplete: % of 8', n; end if;
end $$;
