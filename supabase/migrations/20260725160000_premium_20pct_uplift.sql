-- Real-SIM (premium) tier now sells at a 20% uplift over standard.
--
-- WHY: premium_credits was only FLOORED at retail_credits, and the pinned
-- carrier costs the same as a random fill on essentially every route (probed
-- 2026-07-21, re-confirmed today). Result: `premium_credits = retail_credits`
-- on ALL 16,303 active routes — zero uplift, no exceptions. The tier was
-- strictly better than standard (named real carrier, fail-fast, never silently
-- downgraded to a Donor* VoIP pool) at an identical price, so Standard was the
-- irrational pick and the two chips showed the same number, which read as a
-- broken picker rather than a choice.
--
-- The uplift is a FLOOR, not a replacement: where the carrier genuinely costs
-- more than 1.2x base, the carrier-derived price still wins, because that is
-- the figure create-order's margin ceiling has to clear.
--
--   premium_credits = max(ceil(retail_credits * 1.20),
--                         clamp(ceil(carrier_cents/100 / 0.05), 1, 999))
--
-- Mirrors PREMIUM_MULTIPLIER in sync-smspva-operators — keep them in lockstep.
-- This backfill is required because that sync is cursor-chunked at 12
-- countries/night, so it would take ~6 nights to reach every route on its own
-- (the same reason the 3x -> 6x divisor change needed migration 20260725120000's
-- companion backfill).
--
-- Order-time safety: create-order derives its ceiling from the credits it is
-- about to charge (credits * NET / MIN_MARGIN), so a HIGHER premium price only
-- widens the headroom. This cannot make an honest route fail margin_too_low.

update public.routes
set premium_credits = greatest(
      least(999, ceil(retail_credits * 1.20)),
      greatest(1, least(999, ceil(smspva_operator_cents / 100.0 / 0.05)))
    )
where premium_credits is not null
  and smspva_operator_cents is not null
  and retail_credits is not null;

comment on column public.routes.premium_credits is
  'Real-SIM tier price. max(ceil(retail_credits * 1.20), carrier cost at the '
  'standard divisor) — a 20% uplift floor, overridden upward when the pinned '
  'carrier itself costs more. Keep in lockstep with PREMIUM_MULTIPLIER in '
  'sync-smspva-operators.';
