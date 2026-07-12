// Unified provider router: virtualsms.io (primary) + SMSPVA (fallback).
// The order functions call these instead of a specific provider, so routing +
// failover live in one place. Each provider owns its identifier scheme:
//   virtualsms — service short code ("wa") + ISO country ("FR")
//   smspva     — smspva_code ("opt20") + smspva country code ("US")

import * as vs from "./virtualsms.ts";
import {
  getNumber as smsGetNumber,
  getSms,
  cancelOrder as smsCancel,
  getServicePrice,
  isOk,
} from "./smspva.ts";

export type Provider = "virtualsms" | "smspva";

export interface RouteCodes {
  vsService?: string | null;
  vsCountry?: string | null;
  smsService?: string | null;
  smsCountry?: string | null;
  dial: string;
}

/** Providers that can serve this route, preferred first. Default: virtualsms
 *  (real-SIM quality + webhooks/swap), SMSPVA as backup. */
export function providerOrder(c: RouteCodes, prefer: Provider = "virtualsms"): Provider[] {
  const can = new Set<Provider>();
  if (c.vsService && c.vsCountry) can.add("virtualsms");
  if (c.smsService && c.smsCountry) can.add("smspva");
  const pref: Provider[] = prefer === "virtualsms"
    ? ["virtualsms", "smspva"]
    : ["smspva", "virtualsms"];
  return pref.filter((p) => can.has(p));
}

/** Live wholesale price (USD) at a provider, or null if unavailable. */
export async function livePriceUsd(p: Provider, c: RouteCodes): Promise<number | null> {
  try {
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

/** Reserve a number at a provider. */
export async function reserve(p: Provider, c: RouteCodes): Promise<Reservation> {
  try {
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
    if (p === "virtualsms") { await vs.cancelOrder(orderId); return; }
    await smsCancel(orderId);
  } catch (e) {
    console.error(`release failed provider=${p} order=${orderId}:`, e);
  }
}
