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
// The curve, on WHOLESALE cost in USD (owner decision 2026-09-01, "tail 5x"
// experiment — measure paywall->purchase on `needed >= 4` for ~2 weeks):
//
//     retailUsd(c) = c <= 0.15 ?  10.0 * c            // cheap band, unchanged
//                  : c <= 0.30 ?  1.50                 // plateau — the join
//                  :             5.0 * c               // tail: a true 5x
//     retailCredits(c) = clamp(1, 999, ceil(retailUsd(c) / 0.40))
//
// ⚠️ THE PLATEAU IS WHAT KEEPS THIS MONOTONIC, and it is not a stylistic
// choice. A blanket 5x above 15c would make retail DROP as wholesale RISES
// through the knee — 10 x 15c = $1.50 against 5 x 16c = $0.80 — a price
// inversion, i.e. a dearer route sold cheaper. Holding $1.50 flat from 15c to
// 30c (where 5x catches up to $1.50) is the cheapest continuous, monotone
// join. Never rewrite this as a flat multiple selected by a threshold.
//
// History: 2026-08-28 → 09-01 the tail was a MARGINAL 5.5x from the knee
// (1.50 + 5.5 * (c - 0.15)), which is an EFFECTIVE 6.3–7.2x on the $0.50–$1.00
// routes US users actually want (facebook/telegram/whatsapp). Measured on the
// first day of 2.6 analytics: 4 of 5 paywall purchase attempts on those routes
// were cancelled at Apple's sheet. This tail moves each of them down exactly
// one pack rung (facebook 9→7 cr, telegram 14→11, whatsapp 16→13) and leaves
// the ≤15c band — 12% delivery, and where the 3-credit grant lives — alone.
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

/** Multiple charged on the WHOLE wholesale cost on the tail (above the
 *  plateau). A true multiple, unlike the 2026-08-28 marginal slope. */
export const MULT_TAIL = 5.0;

/** Revenue collected at exactly the knee, and held flat across the plateau. */
const KNEE_RETAIL_USD = MULT_LOW * TAPER_KNEE_USD; // 1.50

/** Where the tail's `MULT_TAIL * c` reaches the plateau revenue — the
 *  plateau's upper end. 1.50 / 5 = 0.30. Derived, never set by hand. */
export const PLATEAU_END_USD = KNEE_RETAIL_USD / MULT_TAIL; // 0.30

const MIN_CREDITS = 1;
const MAX_CREDITS = 999;

/** Retail revenue, in USD, for a wholesale cost in USD. */
export function retailUsd(costUsd: number): number {
  if (!Number.isFinite(costUsd) || costUsd <= 0) return 0;
  if (costUsd <= TAPER_KNEE_USD) return MULT_LOW * costUsd;
  if (costUsd <= PLATEAU_END_USD) return KNEE_RETAIL_USD;
  return MULT_TAIL * costUsd;
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
 *      rev <  1.50 ? rev / 10.0
 *                  : max(0.30, rev / 5.0)
 *
 *  The plateau is not one-to-one: every cost in (0.15, 0.30] prices at $1.50.
 *  The inverse therefore returns the UPPER end of that preimage (0.30) — the
 *  most expensive route that could honestly carry this price — so the
 *  order-time ceiling is lenient across the whole plateau and never refuses
 *  an honestly-priced route. (`credits * 0.40` never equals 1.50 exactly for
 *  an integer credit count, so the `<` vs `<=` at the knee is moot; the
 *  4-credit plateau price is rev = 1.60 -> max(0.30, 0.32) = 0.32.)
 */
export function expectedCostUsd(credits: number): number {
  if (!Number.isFinite(credits) || credits <= 0) return 0;
  const rev = credits * NET_USD_PER_CREDIT;
  if (rev < KNEE_RETAIL_USD) return rev / MULT_LOW;
  return Math.max(PLATEAU_END_USD, rev / MULT_TAIL);
}
