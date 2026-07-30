// Unified provider router. SMS is served by ONE provider at a time, with no
// cross-provider fallback (owner decision 2026-07-30). The order functions call
// these instead of a specific provider, so routing lives in one place.
//
// Each provider owns its identifier scheme:
//   smspva  — smspva_code ("opt20") + smspva country code ("US")
//
// RETIRED 2026-07-30: smspool (SMS only — it keeps the eSIM line, a separate
// table and code path) and virtualsms (purchase endpoint 503'd for every combo,
// 3 lifetime orders, 0 codes). Their adapters, syncs and route codes are gone.
// Their names survive ONLY as historical values on `orders.provider` — 50 and 3
// rows respectively — which is why `OrderProvider` still admits them and
// `orders_provider_check` still permits them. Rewriting those rows would
// destroy the delivery evidence they carry.

import {
  getNumber as smsGetNumber,
  getSms,
  cancelOrder as smsCancel,
  blockNumber as smsBlock,
  getServicePrice,
  getBalance as smsGetBalance,
  isOk,
} from "./smspva.ts";

/** Providers that can be ROUTED TO for a new order. */
export type Provider = "smspva";

/** Providers that may appear on an existing `orders.provider`, including
 *  retired ones. Lifecycle calls (poll/release/markDead/markSuccess) accept
 *  this wider type because they run against rows written long ago. */
export type OrderProvider = Provider | "smspool" | "virtualsms";

/** Documented provider failure classes, so callers map to real user copy.
 *  create-order branches on THIS, never on the raw error string.
 *
 *  Formerly `SmspoolErrorType`, defined in the SMSPool adapter. It was never
 *  SMSPool-specific — it is the router's shared vocabulary — and leaving it
 *  named after a provider that no longer serves SMS invited exactly the kind of
 *  confusion this cleanup exists to remove. */
export type ProviderErrorType =
  | "OUT_OF_STOCK" | "PRICE_NOT_FOUND" | "BALANCE_ERROR"
  | "RATE_LIMITED" | "AUTH_ERROR" | "TRANSPORT_ERROR";

export interface RouteCodes {
  smsService?: string | null;
  smsCountry?: string | null;
  dial: string;
}

/** Providers that can serve this route, preferred first.
 *
 *  SMSPVA only, and deliberately a single element: there is NO fallback.
 *  A silent cross-provider substitution is what hid virtualsms's dead purchase
 *  endpoint behind SMSPVA for weeks — create-order's loop tried the next
 *  provider and the failure never surfaced. One provider, one attempt, a real
 *  error when it fails.
 *
 *  eSIMs are untouched and stay on SMSPool (a separate table and code path). */
export function providerOrder(c: RouteCodes): Provider[] {
  return c.smsService && c.smsCountry ? ["smspva"] : [];
}

/** Live wholesale price (USD) at a provider, or null if unavailable. */
export async function livePriceUsd(p: Provider, c: RouteCodes): Promise<number | null> {
  try {
    if (p === "smspva" && c.smsService && c.smsCountry) {
      const r = await getServicePrice(c.smsCountry, c.smsService);
      return isOk(r) && Number.isFinite(r.data?.price) && r.data.price > 0 ? r.data.price : null;
    }
  } catch { /* fall through to null */ }
  return null;
}

export interface Reservation {
  ok: boolean;
  orderId?: string;   // provider's order/activation id
  number?: string;    // display-formatted phone number
  costUsd?: number;
  /** Provider's own hold deadline (epoch seconds) when it reports one. */
  expiresAt?: number;
  /** Carrier/pool that actually filled, for outcome attribution. */
  pool?: string;
  error?: string;
  errorType?: ProviderErrorType;
}

/** Reserve a number at a provider. maxPriceUsd caps the fill price where the
 *  provider supports it; pool pins the carrier the route was priced from.
 *  pinStrict=true (premium tier) makes a dry pin a hard failure instead of
 *  retrying unpinned. */
export async function reserve(
  p: Provider, c: RouteCodes, _maxPriceUsd?: number, pool?: string | null,
  pinStrict = false,
): Promise<Reservation> {
  try {
    if (p === "smspva" && c.smsService && c.smsCountry) {
      // SMSPVA's allocation endpoint accepts no price cap and reports no cost
      // — it once billed $3.60 on a route quoted at pennies. Bracket the
      // purchase with balance reads so the caller learns the REAL charge and
      // can hide/reprice the route. Best-effort: if either read fails we
      // still complete the order, just without a measured cost.
      //
      // `pool` here is an SMSPVA OPERATOR pin — a real carrier such as
      // "Vodafone_UK". Random (unpinned) fills come from the anonymized
      // Donor* pools, the VoIP-style stock strict services reject.
      //
      //  - premium (pinStrict): a dry carrier FAILS and create-order refunds
      //    — the buyer paid for the real-SIM pool, never silently downgrade
      //    (owner decision 2026-07-21).
      //  - standard: pin opportunistically and fall back to a random fill
      //    when the carrier is dry or the error is unclassified. Probed
      //    2026-07-21: the carrier costs the same or less than a random fill
      //    on all 16,320 active routes, so this is a free delivery upgrade
      //    that can never do worse than the old always-random behavior.
      const before = await smsGetBalance().catch(() => null);
      let usedPool = pool ?? undefined;
      let r = await smsGetNumber(c.smsCountry, c.smsService, usedPool);
      if (!isOk(r) && usedPool && !pinStrict) {
        const t = classifySmspvaFault(r.error?.type ?? "smspva_error");
        if (t === undefined || t === "OUT_OF_STOCK") {
          usedPool = undefined;
          r = await smsGetNumber(c.smsCountry, c.smsService);
        }
      }
      if (!isOk(r)) {
        const raw = r.error?.type ?? "smspva_error";
        return { ok: false, error: raw, errorType: classifySmspvaFault(raw) };
      }
      let costUsd: number | undefined;
      const after = await smsGetBalance().catch(() => null);
      const b0 = isOk(before) ? before.data?.balance : undefined;
      const b1 = isOk(after) ? after.data?.balance : undefined;
      if (typeof b0 === "number" && typeof b1 === "number" && b0 > b1) costUsd = b0 - b1;
      return {
        ok: true,
        orderId: String(r.data.orderId),
        // SMSPVA returns a NATIONAL number, so the dial code is prepended here.
        // Any future provider that returns full E.164 must NOT reuse this line
        // — it would produce a doubled country code.
        number: `${c.dial} ${r.data.phoneNumber}`,
        costUsd,
        pool: usedPool,
      };
    }
  } catch (e) {
    return { ok: false, error: String(e) };
  }
  return { ok: false, error: "provider_not_configured" };
}

/** Map an SMSPVA error `type` onto the shared fault taxonomy.
 *
 *  Until now the SMSPVA branch set `error` (a free string) but never
 *  `errorType`, and create-order classifies purely on `errorType`. So EVERY
 *  SMSPVA failure — dead account, bad key, rate limit, genuine stockout — fell
 *  through to "no_numbers_available". Two consequences, both bad:
 *
 *    - the user is told "try another country or service", so they dutifully
 *      try every country and get the same lie each time;
 *    - the one console.error written to make a dead provider loud is itself
 *      gated on errorType, so it never fired for the only SMS provider we have.
 *
 *  With one SMS provider and no fallback, an empty balance would take the
 *  product down with no signal anywhere.
 *
 *  SMSPVA's error vocabulary is not publicly documented (docs.smspva.com
 *  describes a different, older API), and the only string confirmed live is
 *  APIKEY_NOT_SET. So match on substrings rather than pretending to know the
 *  full enum, and log anything unrecognised so the real vocabulary can be
 *  learned from production instead of guessed.
 */
function classifySmspvaFault(raw: string): ProviderErrorType | undefined {
  const t = raw.toUpperCase();
  if (/BALANCE|FUND|MONEY|DEPOSIT|PAYMENT/.test(t)) return "BALANCE_ERROR";
  if (/APIKEY|API_KEY|AUTH|TOKEN|FORBID|DENIED/.test(t)) return "AUTH_ERROR";
  if (/LIMIT|FREQUENT|TOO_MANY|FLOOD|THROTTL/.test(t)) return "RATE_LIMITED";
  // From SMSPVA's official OpenAPI schema (smspva.com/json/schema.php):
  // PRICE_FETCH_FAIL(501) is a transient price-lookup failure — route it to
  // the margin path, not "no numbers". SERVER_BUSY(503) is "server overload,
  // try later" — a retryable hiccup, NOT a stockout; classifying it as
  // OUT_OF_STOCK told users to abandon a route that was fine seconds later.
  if (/PRICE_FETCH|PRICE_NOT/.test(t)) return "PRICE_NOT_FOUND";
  if (/SERVER_BUSY|OVERLOAD/.test(t)) return "RATE_LIMITED";
  if (/STOCK|NO_NUMBER|NUMBERS|AVAIL|EMPTY|SOLD|NUMBER_NOT_FOUND/.test(t)) return "OUT_OF_STOCK";
  // Deliberately undefined: create-order then uses its existing default. We do
  // NOT invent a classification we cannot justify — but we do make it visible.
  console.error(`smspva: unclassified error type "${raw}" — add it to classifySmspvaFault`);
  return undefined;
}

/** A lifecycle call arrived for a provider we can no longer talk to.
 *
 *  This function is the whole reason the retired names survive in the type.
 *  Previously every lifecycle switch ended in an UNGUARDED SMSPVA call, so any
 *  provider without an explicit branch silently had its orders polled and
 *  cancelled against SMSPVA using a foreign order id — returning HTTP 200 the
 *  entire time, delivering nothing, and never reclaiming the wholesale. Refuse
 *  loudly instead; a retired provider has no open orders to service anyway
 *  (verified 2026-07-30: zero waiting orders on any provider). */
function refuseRetired(fn: string, p: string, orderId: string): void {
  console.error(
    `${fn}: refusing retired provider "${p}" order=${orderId} — no adapter, ` +
    `and falling through to another provider's API would corrupt its state`,
  );
}

/** Tell the provider an activation SUCCEEDED. SMSPVA's blocknumber marks the
 *  number used — their docs ask for it, and account karma influences the
 *  quality of numbers they hand out next. Best-effort hygiene: a failure here
 *  must never affect the delivered order. */
export async function markSuccess(p: OrderProvider, orderId: string): Promise<void> {
  if (p !== "smspva") return;
  try { await smsBlock(orderId); } catch { /* hygiene only */ }
}

/** Tell the provider an activation FAILED (ran its whole window with no SMS)
 *  and close it. SMSPVA's own docs instruct exactly this: "If you haven't
 *  received an SMS within 580 seconds, make sure to ban the number" — an
 *  unbanned request id is retained for ~10 minutes and the same dead number
 *  is allocated again (measured live 2026-07-24: 9 retry orders drew only 6
 *  distinct numbers). Ban and cancel carry the identical karma cost
 *  (-0.0125 each, smspva.com/info.html), so this is free hygiene that stops
 *  dead numbers cycling back into our own orders. Ban first, then cancel to
 *  reclaim the wholesale refund; both best-effort — the user's credit refund
 *  has already happened by the time this runs and must never depend on it. */
export async function markDead(p: OrderProvider, orderId: string): Promise<void> {
  if (p !== "smspva") { refuseRetired("markDead", p, orderId); return; }
  // Log both outcomes explicitly: these calls return SMSPVA's error ENVELOPE
  // rather than throwing, so a silent try/catch would hide whether the ban
  // registered and whether the follow-up cancel still reclaims the wholesale
  // cost (undocumented — the ban may consume the request id). This line is
  // the only evidence available for that interaction.
  // CANCEL FIRST, then ban. This order is deliberate and was reversed on
  // 2026-07-27.
  //
  // `cancelorder` is what reclaims the wholesale cost; `blocknumber` is
  // hygiene. Banning first risked consuming the request id (undocumented — the
  // comment above has always said so), which would forfeit the refund on every
  // call. That became material the moment cancel-order stopped calling
  // release() and routed all reclamation through here: measured $38.14 of
  // wholesale sat in cancels over 30 days, against ~$146 of net revenue in the
  // same period.
  //
  // The trade is explicit: if cancelling frees the number before the ban
  // registers, it can be re-issued — but the client's fresh-number guarantee
  // already filters numbers this user recently burned, whereas a forfeited
  // refund is certain, unrecoverable cash.
  let banOk = false, cancelOk = false, detail = "";
  try {
    const c = await smsCancel(orderId);
    cancelOk = isOk(c);
    if (!cancelOk) detail += `cancel=${(c as { error?: { type?: string } }).error?.type ?? "?"} `;
  } catch (e) { detail += `cancel_threw=${e} `; }
  try {
    const b = await smsBlock(orderId);
    banOk = isOk(b);
    if (!banOk) detail += `ban=${(b as { error?: { type?: string } }).error?.type ?? "?"}`;
  } catch (e) { detail += `ban_threw=${e}`; }
  console.log(`markDead order=${orderId} ban=${banOk} cancel=${cancelOk} ${detail}`);
}

export interface PollResult {
  state: "waiting" | "received" | "canceled" | "expired" | "unknown";
  code?: string;
  fullText?: string;
}

/** Poll a provider order for the SMS code. */
export async function poll(p: OrderProvider, orderId: string): Promise<PollResult> {
  if (p !== "smspva") {
    refuseRetired("poll", p, orderId);
    return { state: "unknown" };
  }
  const r = await getSms(orderId);
  if (isOk(r) && r.data.sms?.code) {
    return { state: "received", code: r.data.sms.code, fullText: r.data.sms.fullText };
  }
  return { state: "waiting" };
}

/** Best-effort release/cancel at a provider (local refund happens regardless). */
export async function release(p: OrderProvider, orderId: string): Promise<void> {
  if (p !== "smspva") { refuseRetired("release", p, orderId); return; }
  try {
    await smsCancel(orderId);
  } catch (e) {
    console.error(`release failed provider=${p} order=${orderId}:`, e);
  }
}
