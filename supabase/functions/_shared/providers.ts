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
 *  SMSPool-ONLY as of 2026-07-20 (owner decision): SMSPVA and virtualsms are
 *  retired for NEW orders — their adapters stay only so poll/cancel/refund
 *  keep working for historical orders. To re-enable a fallback, restore the
 *  chain here AND un-hide its routes + re-schedule its sync cron. */
export function providerOrder(c: RouteCodes, _prefer: Provider = "smspool"): Provider[] {
  return c.spService && c.spCountry ? ["smspool"] : [];
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
      const r = await sp.purchase(c.spCountry, c.spService, maxPriceUsd, pool ?? undefined);
      if (!r.ok) return { ok: false, error: r.error };
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
      const r = await smsGetNumber(c.smsCountry, c.smsService);
      if (!isOk(r)) return { ok: false, error: r.error?.type ?? "smspva_error" };
      return { ok: true, orderId: String(r.data.orderId), number: `${c.dial} ${r.data.phoneNumber}` };
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
    return { state: s.state, code: s.code, fullText: s.fullText };
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
