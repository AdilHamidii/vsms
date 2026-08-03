-- Make 5sim's rate720 FALSIFIABLE, and stop stamping a retired provider's stock.
--
-- rate720 now steers the whole catalog and is rendered to users as a colour on
-- every country row. It is also UNDOCUMENTED — only the bare `rate` appears in
-- 5sim's docs — and this codebase's record with vendor metrics is poor:
-- `physicalCount` was recorded on 4,046 routes and used for nothing, then a
-- claim about it was made and retracted the same day.
--
-- Today it cannot be tested at all. sync-5sim rewrites `routes` hourly, so the
-- rate a route was SOLD on is gone an hour later; joining an order back to
-- `routes` reads the CURRENT rate, not the one that drove the pick. Stamping it
-- on the order is the only way to ever answer "does the number we show users
-- predict whether they get a code".
--
-- Both columns, not just the rate: `pool_pinned` records the chain we asked for,
-- while `operator_used` already records what actually filled. Without the pair
-- you cannot tell a good pool that delivered from a fallback that saved us.
alter table public.orders add column if not exists pool_rate_pct smallint;
alter table public.orders add column if not exists pool_pinned   text;

comment on column public.orders.pool_rate_pct is
  'The published 30-day rate of the pool pinned at reservation. NULL = not recorded or the pool was unrated -- never 0, which is a real vendor verdict.';
comment on column public.orders.pool_pinned is
  'The comma-ordered pool chain create-order asked for. Compare against operator_used to see whether the head pool served or a fallback did.';

-- ⚠️ 3,023 of 4,492 active 5sim routes still carry a non-null
-- herosms_physical_count, so two thirds of 5sim orders were about to be stamped
-- with a RETIRED provider's inventory figure. That is precisely the
-- cross-provider comparison this repo already had to retract once.
update public.routes set herosms_physical_count = null, herosms_total_count = null
 where provider <> 'herosms' and herosms_physical_count is not null;
