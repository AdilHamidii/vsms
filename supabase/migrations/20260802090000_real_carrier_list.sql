-- Pin EVERY real carrier, not just the best one — and record which one filled.
--
-- The problem, owner-framed 2026-08-02: "I want good quality numbers for my
-- users to improve success rates."
--
-- What we do today: sync-herosms probes ~8 operators per country, keeps only
-- the single carrier with the most stock in `herosms_real_operator`, and
-- create-order pins that one OPPORTUNISTICALLY. When it is dry the order falls
-- back to the unpinned pool — which is overwhelmingly VoIP (badoo/us measured
-- 2026-07-31: verizon 14,224 real numbers vs textnow 458,985 VoIP, ~96% of the
-- country's stock on one VoIP operator). So the fallback lands users on exactly
-- the numbers strict services reject.
--
-- Why a LIST fixes it without costing availability. Verified in HeroSMS's own
-- OpenAPI spec, `qpSAOptionalOperator`:
--     "List of desired telecom operators (separated by commas without spaces)"
--     example: "tele2,beeline"
-- So one request can name every real carrier at once. Pinning the union of them
-- draws on far more stock than one carrier while still excluding VoIP — better
-- on quality AND on availability than the current single pin. The probe already
-- measures all of them; it just discards all but the maximum.
--
-- 4,106 of 5,140 active HeroSMS routes already have a carrier resolved, so this
-- is turning existing measurement into a wider pin, not new probing.

alter table public.routes
  add column if not exists herosms_real_operators text;

comment on column public.routes.herosms_real_operators is
  'Comma-joined real (non-VoIP) carriers that had stock at the last probe, most '
  'stock first, ready to pass straight to getNumberV2''s `operator` param. '
  'NULL means never probed — distinct from an empty result. Superset of '
  'herosms_real_operator, which stays as the single best carrier for the '
  'premium/real_sim_only strict pin.';

-- The control arm we have never had.
--
-- getNumberV2's response carries `activationOperator` (spec example:
-- "activationOperator": "any") and we discard it. Without it we cannot answer
-- the question this whole feature rests on — do real SIMs deliver better than
-- VoIP? — because `routes.herosms_physical_count` describes the ROUTE at sync
-- time, not the number the user actually got.
--
-- CLAUDE.md records the physicalCount experiment as unfalsifiable: sync-herosms
-- hid every zero-physicalCount route on strict services before an order could
-- land on one, so the comparison group could never be populated. Recording the
-- operator that actually filled sidesteps that entirely — every order becomes
-- evidence about a named carrier, whether or not the route was ever hidden.
alter table public.orders
  add column if not exists operator_used text;

comment on column public.orders.operator_used is
  'The carrier the provider actually filled from (getNumberV2 activationOperator). '
  '"any" means an unpinned fill. NULL means not recorded — never assume it means '
  'unpinned. This is the control arm for "do real SIMs deliver better than VoIP"; '
  'settle it by joining against app_config.voip_operators.';

-- Settle the real-vs-VoIP question with:
--   select (o.operator_used is not null
--           and lower(o.operator_used) <> 'any'
--           and not (lower(o.operator_used) = any (
--             select lower(jsonb_array_elements_text(value))
--             from public.app_config where key = 'voip_operators'))) as real_sim,
--          count(*) n,
--          count(*) filter (where o.otp is not null) codes
--   from public.orders o
--   where o.provider = 'herosms' and o.smspva_number is not null
--     and o.status <> 'canceled'          -- cancels measure impatience, not delivery
--   group by 1;
