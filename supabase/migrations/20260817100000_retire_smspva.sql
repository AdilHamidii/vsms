-- Retire SMSPVA (owner decision, 2026-08-17).
--
-- 🔴 WHY. It stopped filling orders entirely — this is not a margin or pricing
-- problem. Measured over the 14 days to 2026-08-17:
--
--     provider   orders   reserved a number   codes
--     5sim         91           91              --
--     herosms       5            5              --
--     smspva        7            0               0
--
-- Every order routed to SMSPVA was a charge-and-refund. It stayed invisible for
-- two reasons, both worth remembering: the adapter never classified its
-- failures, so users were told `no_numbers_available` ("try another country")
-- for what was a total provider outage, and `alertProviderFault` is gated on
-- BALANCE_ERROR/AUTH_ERROR so the pager has never once fired for it.
--
-- ⚠️ THE COLLAPSE GUARD COULD NOT SAVE US, and this is the structural lesson.
-- `sync-prices` only hides a provider after >= 8 reservations in a rolling
-- 7 days. Once a provider stops filling, its volume collapses BELOW that floor,
-- the window drains, and the verdict clears itself — so the guard is a latch
-- that only ever unlatches. A hide must persist until N *successful*
-- reservations, never clear on low volume.
--
-- WHAT THIS DOES. 5,099 active routes:
--   *   943 re-homed to HeroSMS  (its code + country mapping both exist)
--   * 4,156 hidden               (no other provider can serve the pair)
--   *     0 re-homed to 5sim     — correct and expected: `sync-5sim` already
--         re-homes anything it can serve on its hourly run, so what remained on
--         SMSPVA is by definition outside 5sim's map.
--
-- Catalog effect: 467 visible services -> 381. The 86 services lost are
-- SMSPVA-only and have **9 orders and 0 codes in their entire history** — they
-- have never once delivered, so this removes inventory that could only ever
-- charge and refund.
--
-- Routing is disabled in the same commit (`_shared/providers.ts`). Both halves
-- are required: hiding alone would leave the router able to pick SMSPVA the
-- moment any route was re-activated, and `refresh_route_observed_success`
-- un-hides priced routes with no check on WHY they were hidden.
--
-- ROLLBACK is deliberate and cheap: restore the two `providerOrder` lines and
-- `update routes set status='active' where provider='smspva' and ...`. The
-- adapter, the account and the credentials are untouched.

begin;

-- 1. Re-home what HeroSMS can actually serve.
--
-- Returned as `hidden`, not `active`: the route must be re-priced from HeroSMS's
-- OWN live stock before it can be sold. This mirrors the 2026-08-06 sync-5sim
-- repair for the same reason — a route carrying one provider's price while
-- owned by another is the margin gate reading a cost that does not apply, which
-- refused 3,064 of 4,080 routes with `margin_too_low` the last time it happened.
update public.routes r
   set provider = 'herosms',
       status = 'hidden',
       -- SMSPVA-derived pricing MUST NOT survive the move. `last_cost_cents` is
       -- SMSPVA's cost column and `create-order` falls back to it; leaving it
       -- would pass the margin gate on a price we can no longer buy at, then
       -- fail at reservation — a charge-and-refund wearing a stockout's face.
       -- This is item 9 of the provider-switch checklist.
       retail_credits = null,
       premium_credits = null,
       last_cost_cents = null,
       smoothed_cost_cents = null,
       smspva_operator_cents = null
  from public.services s, public.countries c
 where r.service_id = s.id
   and r.country_id = c.id
   and r.provider = 'smspva'
   and r.status = 'active'
   and s.herosms_code is not null and s.herosms_code <> ''
   and c.herosms_id is not null;

-- 2. Hide everything SMSPVA still owns. Ownership is left on the row on
--    purpose: it records who the route belonged to, and it is what makes the
--    rollback a one-line UPDATE rather than a re-derivation.
update public.routes
   set status = 'hidden'
 where provider = 'smspva'
   and status = 'active';

commit;
