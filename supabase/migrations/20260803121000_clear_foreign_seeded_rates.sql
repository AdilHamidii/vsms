-- A seeded rate may only exist on the provider that seeded it.
--
-- `sync-smspva-conversions` writes SMSPVA's own per-country conversion grade
-- (3->90, 2->70, 1->40) as `success_rate` with `rate_source='seeded'`, and it
-- scopes every one of its statements `.eq("provider","smspva")` — including the
-- clearing pass. That scoping is right, but it has a hole: when a route is
-- RE-HOMED to another provider, the row leaves SMSPVA's scope carrying the
-- grade with it, and nothing can ever clear it again.
--
-- Measured 2026-08-03: 305 HeroSMS routes carry a stale SMSPVA seeded rate —
-- 285 active (176 of them reading 70% or better) and 20 hidden — against just
-- 6 HeroSMS routes with a real measured rate, all of which read 0%. So every
-- optimistic number in the HeroSMS half of the catalog describes a provider we
-- no longer buy from. No SMSPVA row is touched: the predicate is the exact
-- complement of the scope sync-smspva-conversions maintains.
--
-- No user-visible lie today: `deliveryRecord` requires rate_source='measured'
-- and maps everything else to "Not tested", and `bestCountry`'s "proven" tier
-- was narrowed to measured-only for exactly this reason. This is dead data with
-- a live trap attached — the next consumer that reads `success_rate` without
-- also reading `rate_source` inherits a retired provider's opinion, which is
-- precisely how the seeded grade ranked never-sold routes as "proven" before.
--
-- Same class as the evidence rule already documented: evidence must describe
-- the provider that serves the NEXT order.
update public.routes
   set success_rate = null,
       rate_source  = null
 where rate_source = 'seeded'
   and provider is distinct from 'smspva';
