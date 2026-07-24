// Unified provider router. Preference order: SMSPool (primary) -> SMSPVA
// (fallback) -> virtualsms (last; currently degraded). The order functions call
// these instead of a specific provider, so routing + failover live in one place.
// Each provider owns its identifier scheme:
//   smspool    — numeric service id ("1363") + numeric country id ("3")
//   smspva     — smspva_code ("opt20") + smspva country code ("US")
//   virtualsms — service short code ("wa") + ISO country ("FR")

import * as sp from "./smspool.ts";
import * as vs from "./virtualsms.ts";
import {
  getNumber as smsGetNumber,
  getSms,
  cancelOrder as smsCancel,
  blockNumber as smsBlock,
  getServicePrice,
  getBalance as smsGetBalance,
  isOk,
} from "./smspva.ts";

export type Provider = "smspool" | "smspva" | "virtualsms";

export interface RouteCodes {
  spService?: string | null;   // SMSPool numeric service id
  spCountry?: string | null;   // SMSPool numeric country id
  vsService?: string | null;
  vsCountry?: string | null;
  smsService?: string | null;
  smsCountry?: string | null;
  dial: string;
}

/** Providers that can serve this route, preferred first.
 *  SMSPVA for SMS; SMSPool keeps the eSIM line only (owner decision
 *  2026-07-21). SMSPool served 43 SMS orders across 3 days and delivered 3.
 *  The decisive test: leboncoin/NL — 8 of 13 on SMSPVA — went 0 of 1 on
 *  SMSPool with everything working (number issued from the pinned pool at 7c
 *  against a 1-credit charge, held 173s); the SMS simply never arrived.
 *
 *  SMSPool is deliberately NOT a fallback here: its ToS 6.7 bans financial,
 *  crypto, KYC, telecom and government verifications outright, and SMSPVA
 *  carries ~134 services SMSPool has no mapping for at all — so routing SMS
 *  to it costs coverage as well as delivery.
 *
 *  eSIMs are untouched and stay on SMSPool (9 of 9 delivered, a separate
 *  table and code path).
 *
 *  virtualsms stays retired: its purchase endpoint 503s for every combo. */
export function providerOrder(c: RouteCodes, _prefer: Provider = "smspva"): Provider[] {
  return c.smsService && c.smsCountry ? ["smspva"] : [];
}

/** Live wholesale price (USD) at a provider, or null if unavailable. */
export async function livePriceUsd(p: Provider, c: RouteCodes): Promise<number | null> {
  try {
    if (p === "smspool" && c.spService && c.spCountry) {
      const r = await sp.getPrice(c.spCountry, c.spService);
      return r.ok && r.priceUsd != null ? r.priceUsd : null;
    }
    if (p === "virtualsms" && c.vsService && c.vsCountry) {
      const r = await vs.price(c.vsService, c.vsCountry);
      return r.ok && r.priceUsd != null ? r.priceUsd : null;
    }
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
  /** Pool that actually filled (SMSPool), for outcome attribution. */
  pool?: string;
  error?: string;
  /** Documented provider failure class, so callers map to real user copy. */
  errorType?: sp.SmspoolErrorType;
}

/** Reserve a number at a provider. maxPriceUsd caps the fill price where the
 *  provider supports it (SMSPool max_price); pool pins the pool/carrier the
 *  route was priced from. pinStrict=true (premium tier) makes a dry pin a
 *  hard failure instead of retrying unpinned. */
export async function reserve(
  p: Provider, c: RouteCodes, maxPriceUsd?: number, pool?: string | null,
  pinStrict = false,
): Promise<Reservation> {
  try {
    if (p === "smspool" && c.spService && c.spCountry) {
      // Pin the pool the route was priced from. Pools are SUPPLIERS with
      // different carriers and measurably different delivery — and sync picks
      // the pin on MEASURED success rate, not price (price is mildly
      // ANTI-correlated with delivery: on 20 sampled combos the priciest pool
      // was the worst-performing one 10 times, and the best-rate pool was also
      // cheaper on 13).
      //
      // Pinning without a fallback would convert "this pool is dry" into a
      // hard failure, so an OUT_OF_STOCK on the pinned pool retries once on
      // auto — we would rather fill from a mediocre pool than not at all.
      let r = await sp.purchase(c.spCountry, c.spService, maxPriceUsd, pool ?? undefined);
      if (!r.ok && pool && r.errorType === "OUT_OF_STOCK") {
        r = await sp.purchase(c.spCountry, c.spService, maxPriceUsd);
      }
      if (!r.ok) return { ok: false, error: r.error, errorType: r.errorType };
      // A number still activating cannot receive a code (SMSPool FAQ), so a
      // failed wait means release it and let the caller fall through rather
      // than hand over a number that is guaranteed to fail.
      if (r.orderId) {
        const ready = await sp.waitUntilReady(r.orderId).catch(() => false);
        if (!ready) {
          await sp.cancel(r.orderId).catch(() => {});
          return { ok: false, error: "number_never_activated" };
        }
      }
      return {
        ok: true, orderId: r.orderId, number: r.phoneNumber ?? "",
        costUsd: r.costUsd, expiresAt: r.expiresAt, pool: r.pool,
      };
    }
    if (p === "virtualsms" && c.vsService && c.vsCountry) {
      const r = await vs.buyNumber(c.vsService, c.vsCountry);
      if (!r.ok) return { ok: false, error: r.error };
      const num = r.phoneNumber
        ? (r.phoneNumber.startsWith("+") ? r.phoneNumber : `+${r.phoneNumber}`)
        : "";
      return { ok: true, orderId: r.orderId, number: num, costUsd: r.costUsd };
    }
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
 *  With SMSPVA the sole SMS provider, an empty balance would take the product
 *  down with no signal anywhere.
 *
 *  SMSPVA's error vocabulary is not publicly documented (docs.smspva.com
 *  describes a different, older API), and the only string confirmed live is
 *  APIKEY_NOT_SET. So match on substrings rather than pretending to know the
 *  full enum, and log anything unrecognised so the real vocabulary can be
 *  learned from production instead of guessed.
 */
function classifySmspvaFault(raw: string): sp.SmspoolErrorType | undefined {
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

/** Tell the provider an activation SUCCEEDED. SMSPVA's blocknumber marks the
 *  number used — their docs ask for it, and account karma influences the
 *  quality of numbers they hand out next. Best-effort hygiene: a failure here
 *  must never affect the delivered order. */
export async function markSuccess(p: Provider, orderId: string): Promise<void> {
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
export async function markDead(p: Provider, orderId: string): Promise<void> {
  if (p !== "smspva") { await release(p, orderId); return; }
  try { await smsBlock(orderId); } catch { /* hygiene only */ }
  try { await smsCancel(orderId); } catch { /* already closed by the ban is fine */ }
}

export interface PollResult {
  state: "waiting" | "received" | "canceled" | "expired" | "unknown";
  code?: string;
  fullText?: string;
}

/** Poll a provider order for the SMS code. */
export async function poll(p: Provider, orderId: string): Promise<PollResult> {
  if (p === "smspool") {
    const s = await sp.check(orderId);
    // "activating" is not terminal — the number simply isn't live yet. Report
    // it as waiting so callers keep polling rather than expiring the order.
    const state = s.state === "activating" ? "waiting" : s.state;
    return { state, code: s.code, fullText: s.fullText };
  }
  if (p === "virtualsms") {
    const s = await vs.getOrder(orderId);
    return { state: s.state, code: s.code, fullText: s.fullText };
  }
  const r = await getSms(orderId);
  if (isOk(r) && r.data.sms?.code) {
    return { state: "received", code: r.data.sms.code, fullText: r.data.sms.fullText };
  }
  return { state: "waiting" };
}

/** Best-effort release/cancel at a provider (local refund happens regardless). */
export async function release(p: Provider, orderId: string): Promise<void> {
  try {
    if (p === "smspool") { await sp.cancel(orderId); return; }
    if (p === "virtualsms") { await vs.cancelOrder(orderId); return; }
    await smsCancel(orderId);
  } catch (e) {
    console.error(`release failed provider=${p} order=${orderId}:`, e);
  }
}
