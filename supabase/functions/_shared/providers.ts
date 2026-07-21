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
 *  SMSPool → SMSPVA as of 2026-07-20. The brief SMSPool-only period was
 *  reversed on measured delivery: over 30 days SMSPVA delivered 59% (29/49)
 *  vs SMSPool's 13% (2/16), at a LOWER average cost when it succeeded (13¢
 *  vs 20¢) — and SMSPool's catalog lacks ~134 services SMSPVA carries
 *  (PayPal, Revolut, Coinbase, Binance, Wise, Klarna…).
 *  virtualsms stays retired: its purchase endpoint 503s for every combo. */
export function providerOrder(c: RouteCodes, prefer: Provider = "smspool"): Provider[] {
  const can: Provider[] = [];
  if (c.spService && c.spCountry) can.push("smspool");
  if (c.smsService && c.smsCountry) can.push("smspva");
  return prefer === "smspva" ? can.reverse() : can;
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
  error?: string;
}

/** Reserve a number at a provider. maxPriceUsd caps the fill price where the
 *  provider supports it (SMSPool max_price); pool pins the SMSPool quality
 *  tier the route was priced from. */
export async function reserve(
  p: Provider, c: RouteCodes, maxPriceUsd?: number, pool?: string | null,
): Promise<Reservation> {
  try {
    if (p === "smspool" && c.spService && c.spCountry) {
      // pool intentionally not forwarded — see sp.purchase(): auto beats our
      // priciest-pool inference. Kept in the signature for a manual override.
      const r = await sp.purchase(c.spCountry, c.spService, maxPriceUsd);
      if (!r.ok) return { ok: false, error: r.error };
      // Hold the number back until it leaves "activating" — a code requested
      // during that window is never delivered (SMSPool FAQ).
      if (r.orderId) await sp.waitUntilReady(r.orderId).catch(() => true);
      return { ok: true, orderId: r.orderId, number: r.phoneNumber ?? "", costUsd: r.costUsd };
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
      const before = await smsGetBalance().catch(() => null);
      const r = await smsGetNumber(c.smsCountry, c.smsService);
      if (!isOk(r)) return { ok: false, error: r.error?.type ?? "smspva_error" };
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
      };
    }
  } catch (e) {
    return { ok: false, error: String(e) };
  }
  return { ok: false, error: "provider_not_configured" };
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
