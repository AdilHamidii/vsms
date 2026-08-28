// THE SMS RETAIL PRICING CURVE — one tapered formula, uniform across every SMS
// provider (owner decision 2026-08-28).
//
// WHY THIS FILE EXISTS, AND WHY IT CONTRADICTS AN OLD STANDING WARNING.
// Until now each sync carried its OWN `CREDIT_DIVISOR` — 5sim 0.04, HeroSMS
// 0.025, SMSPVA 0.05 — and this repo's standing rule was that "consolidating
// them into _shared/ would silently reprice a whole provider", because the
// values were deliberately DIFFERENT. That rule is retired by this decision:
// the values are now deliberately UNIFORM, so the duplication has stopped
// buying anything and has only ever cost drift. Every SMS retail price and its
// order-time inverse comes from here.
//
// The curve, on WHOLESALE cost in USD:
//
//     retailUsd(c) = c <= 0.15 ?  10.0 * c
//                              :  1.50 + 5.5 * (c - 0.15)
//     retailCredits(c) = clamp(1, 999, ceil(retailUsd(c) / 0.40))
//
// ⚠️ THE TAPER IS MARGINAL (piecewise-linear and CONTINUOUS at the knee), and
// that is not a stylistic choice. A blanket 5.5x above 15c would make retail
// DROP as wholesale RISES through the knee — 10 x 15c = $1.50 against
// 5.5 x 16c = $0.88 — a price inversion, i.e. a dearer route sold cheaper.
// Only the marginal form is monotonic. Never rewrite this as a flat multiple
// selected by a threshold.
//
// LOCKSTEP RULE (the one that fails silently and per-order):
// `expectedCostUsd` below MUST remain the exact algebraic inverse of
// `retailUsd`. create-order derives its order-time ceiling from it, so if the
// two ever disagree, honestly-priced routes are refused at checkout with
// `margin_too_low` — charged and instantly refunded, with no error anywhere
// and no signal until someone reads the logs. ANY change to one must change
// the other IN THE SAME COMMIT, and the inverse must be re-derived, not
// re-guessed.

/** MEASURED net revenue per credit, over all Production purchases (blended
 *  gross $0.467, $0.397 after Apple's 15%). Re-derive from receipts if the
 *  pack mix shifts; do not guess it. */
export const NET_USD_PER_CREDIT = 0.40;

/** Wholesale cost at which the multiple tapers. */
export const TAPER_KNEE_USD = 0.15;

/** Multiple charged on wholesale up to the knee. */
export const MULT_LOW = 10.0;

/** MARGINAL multiple charged on wholesale ABOVE the knee — not a blanket
 *  multiple on the whole cost (see the inversion note above). */
export const MULT_HIGH = 5.5;

/** Revenue collected at exactly the knee. Both halves of the curve pass
 *  through this point, which is what makes it continuous. */
const KNEE_RETAIL_USD = MULT_LOW * TAPER_KNEE_USD; // 1.50

const MIN_CREDITS = 1;
const MAX_CREDITS = 999;

/** Retail revenue, in USD, for a wholesale cost in USD. */
export function retailUsd(costUsd: number): number {
  if (!Number.isFinite(costUsd) || costUsd <= 0) return 0;
  return costUsd <= TAPER_KNEE_USD
    ? MULT_LOW * costUsd
    : KNEE_RETAIL_USD + MULT_HIGH * (costUsd - TAPER_KNEE_USD);
}

/** Retail price in CREDITS for a wholesale cost in USD, clamped to 1..999.
 *  This is the single definition every SMS pricing sync writes
 *  `routes.retail_credits` (and `premium_credits`) from. */
export function retailCredits(costUsd: number): number {
  if (!Number.isFinite(costUsd) || costUsd <= 0) return MIN_CREDITS;
  const raw = Math.ceil(retailUsd(costUsd) / NET_USD_PER_CREDIT);
  return Math.max(MIN_CREDITS, Math.min(MAX_CREDITS, raw));
}

/** The EXACT inverse of `retailUsd`: the wholesale cost a route priced at
 *  `credits` was expected to have. create-order builds its order-time ceiling
 *  on top of this, so it must equal the curve the route was priced with (see
 *  the lockstep rule at the top of this file).
 *
 *      rev = credits * 0.40
 *      rev <= 1.50 ? rev / 10.0
 *                  : 0.15 + (rev - 1.50) / 5.5
 */
export function expectedCostUsd(credits: number): number {
  if (!Number.isFinite(credits) || credits <= 0) return 0;
  const rev = credits * NET_USD_PER_CREDIT;
  return rev <= KNEE_RETAIL_USD
    ? rev / MULT_LOW
    : TAPER_KNEE_USD + (rev - KNEE_RETAIL_USD) / MULT_HIGH;
}
