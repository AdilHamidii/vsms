-- Per-route HeroSMS cost + real-SIM stock, so availability and the margin gate
-- stop relying on a retired provider's numbers.
--
-- THE BUG THIS EXISTS TO FIX. After the cutover, `routes.last_cost_cents` and
-- `smoothed_cost_cents` on HeroSMS routes still hold SMSPVA's wholesale, frozen
-- (sync-prices deliberately skips non-SMSPVA rows). create-order's graceful
-- degrade at `liveCost ??= route.last_cost_cents/100` therefore margin-checks a
-- HeroSMS purchase against SMSPVA's price. For the ~16% of HeroSMS routes that
-- HeroSMS cannot serve at all, `livePriceUsd` returns null, the stale cost
-- passes the gate, the reservation then fails NO_NUMBERS — and the user is
-- charged, refunded, and told to "try another country or service".
--
-- These columns are written ONLY by sync-herosms and are the authoritative
-- HeroSMS-side facts. `retail_credits` is deliberately NOT touched here:
-- repricing is a separate, owner-gated decision.
--
-- `herosms_physical_count` is the count of PHYSICAL SIM numbers on the route
-- (vs VoIP). Confirmed against HeroSMS's own UI: every country it labels "Only
-- virtual" reports 0. Meta's properties reject VoIP ranges and are ~53% of our
-- order volume at ~12% delivery, so this is the steering signal SMSPVA never
-- gave us — stored now, used when steering is rebuilt.

alter table public.routes
  add column if not exists herosms_cost_cents     integer,
  add column if not exists herosms_physical_count integer,
  add column if not exists herosms_total_count    integer,
  add column if not exists herosms_checked_at     timestamptz;

comment on column public.routes.herosms_cost_cents is
  'HeroSMS wholesale in cents for this (service,country). NULL = HeroSMS does not serve it.';
comment on column public.routes.herosms_physical_count is
  'Physical-SIM numbers available (vs VoIP). 0 = virtual-only stock.';
comment on column public.routes.herosms_checked_at is
  'Last successful sync-herosms pass. Drives the stale-guard.';

-- Partial index: the sync and the availability sweep both scan HeroSMS rows only.
create index if not exists routes_herosms_checked_idx
  on public.routes (herosms_checked_at)
  where provider = 'herosms';
