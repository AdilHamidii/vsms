// Telnyx adapter — the fourth product line (rentable second numbers).
//
// Every wrapper below was written AFTER probing the live API with a real
// account and real purchases on 2026-08-05, never from the documentation. That
// discipline caught four things the docs would have led us to write wrong:
//
//   1. `POST /v2/messaging_profiles` REQUIRES `whitelisted_destinations`,
//      else 40331.
//   2. `messaging_profile_id` is NOT settable on `PATCH /v2/phone_numbers/{id}`
//      (10027) — messaging config lives on the `/messaging` sub-resource.
//   3. Number orders are ASYNCHRONOUS and the response reports NO COST.
//      Nothing anywhere reports what you paid, so the search quote is the only
//      chance to record it.
//   4. `regulatory_requirements` in SEARCH RESULTS IS ALWAYS NULL and means
//      nothing. A GB number bought on the strength of it arrived
//      `requirement-info-pending` and was unusable. The real source is
//      `GET /v2/requirements?filter[action]=ordering`.
//
// ── Why not Web Crypto ─────────────────────────────────────────────────────
// `crypto.subtle` MAY support Ed25519 in the Supabase edge runtime. It also
// may not — and this codebase has already paid for that assumption once: Apple
// Root CA G3 is ECDSA P-384, `crypto.subtle.verify` threw
// `NotSupportedError: Not implemented` on the hosted runtime while passing on
// local Deno, and EVERY IAP purchase failed `chain_verify_failed` for weeks
// before anyone noticed (see `_shared/iap.ts`).
//
// Do not re-run that experiment on the path that delivers people's text
// messages. Pure JS via @noble/curves works identically in both runtimes.

import { ed25519 } from "https://esm.sh/@noble/curves@1.6.0/ed25519";
import type { ProviderErrorType } from "./providers.ts";

/** Telnyx rejects a webhook older than this. Ours must too, or a captured
 *  request can be replayed against us forever. */
export const TELNYX_SIGNATURE_TOLERANCE_SECONDS = 300;

export const TELNYX_SIGNATURE_HEADER = "telnyx-signature-ed25519";
export const TELNYX_TIMESTAMP_HEADER = "telnyx-timestamp";

export type TelnyxSignatureFailure =
  | "missing_signature"
  | "missing_timestamp"
  | "bad_timestamp"
  | "stale_timestamp"
  | "missing_public_key"
  | "malformed_signature"
  | "bad_signature";

export type TelnyxSignatureResult =
  | { ok: true }
  | { ok: false; reason: TelnyxSignatureFailure };

function b64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64.trim());
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/**
 * Verify a Telnyx webhook.
 *
 * The signed message is `${timestamp}|${rawBody}` — Ed25519 over the RAW
 * request bytes.
 *
 * 🔴 `rawBody` MUST be the exact string from `await req.text()`, read ONCE and
 * verified BEFORE parsing. `JSON.parse` followed by `JSON.stringify` reorders
 * keys and drops insignificant whitespace, so it verifies a *different*
 * document than the one Telnyx signed and every signature fails. Parse after.
 *
 * Fails CLOSED. Every other provider path in this codebase degrades gracefully
 * on an unreadable response; this one must not. An unverifiable webhook is
 * someone else's message being written into a user's thread, or someone else's
 * call being billed to us.
 */
export function verifyTelnyxSignature(
  rawBody: string,
  signatureB64: string | null,
  timestampHeader: string | null,
  publicKeyB64: string | undefined = Deno.env.get("TELNYX_PUBLIC_KEY"),
  nowSeconds: number = Math.floor(Date.now() / 1000),
): TelnyxSignatureResult {
  if (!signatureB64) return { ok: false, reason: "missing_signature" };
  if (!timestampHeader) return { ok: false, reason: "missing_timestamp" };
  if (!publicKeyB64) return { ok: false, reason: "missing_public_key" };

  const ts = Number(timestampHeader);
  if (!Number.isFinite(ts)) return { ok: false, reason: "bad_timestamp" };
  // Absolute difference, not `now - ts`: a clock skewed the other way must be
  // rejected too, and a far-future timestamp is exactly what an attacker would
  // send to make a captured request replayable indefinitely.
  if (Math.abs(nowSeconds - ts) > TELNYX_SIGNATURE_TOLERANCE_SECONDS) {
    return { ok: false, reason: "stale_timestamp" };
  }

  let sig: Uint8Array, key: Uint8Array;
  try {
    sig = b64ToBytes(signatureB64);
    key = b64ToBytes(publicKeyB64);
  } catch {
    return { ok: false, reason: "malformed_signature" };
  }
  if (sig.length !== 64 || key.length !== 32) {
    return { ok: false, reason: "malformed_signature" };
  }

  const message = new TextEncoder().encode(`${timestampHeader}|${rawBody}`);
  try {
    return ed25519.verify(sig, message, key)
      ? { ok: true }
      : { ok: false, reason: "bad_signature" };
  } catch {
    // A malformed point or non-canonical encoding is a REJECTION, never a
    // crash: a thrown verifier in a webhook handler becomes a 500, and Telnyx
    // retries a 500 — turning one bad request into a retry storm.
    return { ok: false, reason: "bad_signature" };
  }
}

/** Convenience wrapper for a Request. Read the body yourself and pass it in —
 *  this deliberately does NOT call `req.text()`, because the handler needs the
 *  same string afterwards and a Request body can only be consumed once. */
export function verifyTelnyxRequest(
  req: Request,
  rawBody: string,
): TelnyxSignatureResult {
  return verifyTelnyxSignature(
    rawBody,
    req.headers.get(TELNYX_SIGNATURE_HEADER),
    req.headers.get(TELNYX_TIMESTAMP_HEADER),
  );
}

// ── Fault vocabulary ───────────────────────────────────────────────────────
// Mirrors `heromail.ts`: every adapter call will return `T | TelnyxFault`,
// with `faultOf()` as the type guard. An adapter that does not classify its
// errors collapses dead account / bad key / rate limit / genuine stockout into
// one message, so users are told to "try another country" while the whole
// product is down and the escalation console.error never fires.

export interface TelnyxFault {
  telnyxFault: true;
  type: ProviderErrorType;
  status: number;
  code?: string;
  detail?: string;
}

export function faultOf<T>(v: T | TelnyxFault): v is TelnyxFault {
  return typeof v === "object" && v !== null &&
    (v as TelnyxFault).telnyxFault === true;
}

/**
 * Map a Telnyx error onto the shared vocabulary.
 *
 * ⚠️ PROVISIONAL — the code list below is from the published error reference
 * and has NOT been confirmed against live responses. Confirm each one during
 * the probe session before trusting it, the way `classifyHerosmsFault` was.
 *
 * The default is `TRANSPORT_ERROR`, never `OUT_OF_STOCK`. Guessing stockout
 * for an unknown failure is what sends a user country-shopping during an
 * outage — and on this line there is no other country to shop to, so it would
 * read as the product simply not working.
 */
export function classifyTelnyxFault(status: number, code?: string): ProviderErrorType {
  if (status === 401 || status === 403) return "AUTH_ERROR";
  if (status === 429) return "RATE_LIMITED";
  // 10015 is "No coverage found ... based on the provided search parameters",
  // observed live for every country Telnyx does not sell SMS+voice in.
  if (code === "10015") return "OUT_OF_STOCK";
  // 40310 "Invalid 'to' address" and 40331 "Missing whitelisted destinations"
  // are our bugs, not stock problems — never let them read as a stockout.
  if (status === 402) return "BALANCE_ERROR";
  return "TRANSPORT_ERROR";
}

// ── HTTP core ──────────────────────────────────────────────────────────────

const API = "https://api.telnyx.com/v2";

function apiKey(): string {
  const k = Deno.env.get("TELNYX_API_KEY");
  if (!k) throw new Error("Missing env var TELNYX_API_KEY");
  return k;
}

async function call<T>(
  method: string, path: string, body?: unknown,
): Promise<T | TelnyxFault> {
  let resp: Response;
  try {
    resp = await fetch(API + path, {
      method,
      headers: {
        authorization: `Bearer ${apiKey()}`,
        "content-type": "application/json",
      },
      body: body === undefined ? undefined : JSON.stringify(body),
      // One slow call must not eat the whole ~150s edge budget.
      signal: AbortSignal.timeout(20_000),
    });
  } catch (e) {
    return { telnyxFault: true, type: "TRANSPORT_ERROR", status: 0, detail: String(e) };
  }

  const text = await resp.text();
  let parsed: Record<string, unknown> = {};
  try {
    parsed = text ? JSON.parse(text) : {};
  } catch {
    // Telnyx is consistently JSON; an unparseable body means a proxy or an
    // outage page, which is transport, not a business refusal.
    return {
      telnyxFault: true, type: "TRANSPORT_ERROR", status: resp.status,
      detail: text.slice(0, 200),
    };
  }

  const errs = parsed.errors as Array<Record<string, unknown>> | undefined;
  if (!resp.ok || errs) {
    const first = errs?.[0] ?? {};
    const code = first.code === undefined ? undefined : String(first.code);
    return {
      telnyxFault: true,
      type: classifyTelnyxFault(resp.status, code),
      status: resp.status,
      code,
      detail: String(first.detail ?? first.title ?? text.slice(0, 200)),
    };
  }
  return (parsed.data ?? parsed) as T;
}

// ── Numbers ────────────────────────────────────────────────────────────────

export interface AvailableNumber {
  phoneNumber: string;
  type: string;
  /** What Telnyx charges US per month, in cents. RECORD THIS AT PURCHASE —
   *  neither the order response nor the number resource ever reports a cost
   *  again, so this quote is the only chance to capture it. */
  monthlyCents: number;
  upfrontCents: number;
  reservable: boolean;
  region: string | null;
}

const cents = (v: unknown) => Math.round(parseFloat(String(v ?? "0")) * 100);

/** Live availability. NEVER cache this — stock is per (country, area code) and
 *  genuinely runs out, the same rule `email-domains` follows for HeroSMS. */
export async function searchNumbers(opts: {
  country: string; areaCode?: string; limit?: number;
}): Promise<AvailableNumber[] | TelnyxFault> {
  const p = new URLSearchParams();
  p.set("filter[country_code]", opts.country);
  p.set("filter[phone_number_type]", "local");
  p.append("filter[features][]", "sms");
  p.append("filter[features][]", "voice");
  p.set("filter[limit]", String(opts.limit ?? 10));
  if (opts.areaCode) p.set("filter[national_destination_code]", opts.areaCode);

  const r = await call<Array<Record<string, unknown>>>("GET", "/available_phone_numbers?" + p);
  if (faultOf(r)) return r;

  return r.map((n) => {
    const ci = (n.cost_information ?? {}) as Record<string, unknown>;
    const regions = (n.region_information ?? []) as Array<Record<string, string>>;
    return {
      phoneNumber: String(n.phone_number),
      type: String(n.phone_number_type),
      monthlyCents: cents(ci.monthly_cost),
      upfrontCents: cents(ci.upfront_cost),
      reservable: n.reservable === true,
      // Prefer the human-meaningful label; the raw first entry is often an
      // obscure rate centre nobody recognises.
      region: regions.find((x) => x.region_type === "location")?.region_name ??
              regions.find((x) => x.region_type === "state")?.region_name ?? null,
    };
  });
}

/** Buy. ASYNCHRONOUS — the order starts `pending`; poll `getOrder`. Measured
 *  under 5s, but a webhook outage must not strand a purchase, so the caller
 *  polls rather than waiting on an event. */
export async function orderNumber(
  phoneNumber: string, customerReference: string,
): Promise<{ orderId: string; status: string } | TelnyxFault> {
  const r = await call<Record<string, unknown>>("POST", "/number_orders", {
    phone_numbers: [{ phone_number: phoneNumber }],
    customer_reference: customerReference,
  });
  if (faultOf(r)) return r;
  return { orderId: String(r.id), status: String(r.status) };
}

export async function getOrder(
  orderId: string,
): Promise<{ status: string; numbers: Array<{ e164: string; status: string }> } | TelnyxFault> {
  const r = await call<Record<string, unknown>>("GET", `/number_orders/${orderId}`);
  if (faultOf(r)) return r;
  const nums = (r.phone_numbers ?? []) as Array<Record<string, unknown>>;
  return {
    status: String(r.status),
    numbers: nums.map((n) => ({
      e164: String(n.phone_number),
      // ⚠️ 'requirement-info-pending' means the number is bought and UNUSABLE
      // pending regulatory documents. Treat it as a failure, not as progress.
      status: String(n.status ?? n.requirements_status ?? ""),
    })),
  };
}

export async function findNumberId(e164: string): Promise<string | null | TelnyxFault> {
  const r = await call<Array<Record<string, unknown>>>(
    "GET", "/phone_numbers?" + new URLSearchParams({ "filter[phone_number]": e164 }));
  if (faultOf(r)) return r;
  return r.length ? String(r[0].id) : null;
}

/** ⚠️ messaging_profile_id is NOT settable here — that is the `/messaging`
 *  sub-resource (10027). This endpoint takes customer_reference and tags. */
export async function setCustomerReference(
  numberId: string, reference: string,
): Promise<true | TelnyxFault> {
  const r = await call("PATCH", `/phone_numbers/${numberId}`,
                       { customer_reference: reference });
  return faultOf(r) ? r : true;
}

export async function attachMessagingProfile(
  numberId: string, profileId: string,
): Promise<true | TelnyxFault> {
  const r = await call("PATCH", `/phone_numbers/${numberId}/messaging`,
                       { messaging_profile_id: profileId });
  return faultOf(r) ? r : true;
}

/** Stops the monthly charge. The number returns to Telnyx's pool and WILL be
 *  re-sold, so the UI must say the number is genuinely gone. */
export async function releaseNumber(numberId: string): Promise<true | TelnyxFault> {
  const r = await call("DELETE", `/phone_numbers/${numberId}`);
  return faultOf(r) ? r : true;
}

/** Every number we own, for the orphan reconciler. `customer_reference` is the
 *  join back to phone_lines.id — a number with no live line is money leaking. */
export async function listOwnedNumbers(
  page = 1, size = 250,
): Promise<Array<{ id: string; e164: string; status: string; reference: string | null }> | TelnyxFault> {
  const r = await call<Array<Record<string, unknown>>>(
    "GET", `/phone_numbers?page[number]=${page}&page[size]=${size}`);
  if (faultOf(r)) return r;
  return r.map((n) => ({
    id: String(n.id),
    e164: String(n.phone_number),
    status: String(n.status),
    reference: (n.customer_reference as string | null) ?? null,
  }));
}

// ── Messaging ──────────────────────────────────────────────────────────────

/** ⚠️ `whitelisted_destinations` is REQUIRED (40331). It is the list of
 *  countries the profile may SEND to, not where the number lives. */
export async function createMessagingProfile(opts: {
  name: string; webhookUrl: string; destinations: string[]; dailySpendUsd?: string;
}): Promise<{ id: string } | TelnyxFault> {
  const r = await call<Record<string, unknown>>("POST", "/messaging_profiles", {
    name: opts.name,
    webhook_url: opts.webhookUrl,
    webhook_api_version: "2",
    whitelisted_destinations: opts.destinations,
    // The only cost ceiling that still holds when our backend is down.
    ...(opts.dailySpendUsd
      ? { daily_spend_limit: opts.dailySpendUsd, daily_spend_limit_enabled: true }
      : {}),
  });
  if (faultOf(r)) return r;
  return { id: String(r.id) };
}

export async function sendMessage(opts: {
  from: string; to: string; text: string; profileId?: string;
}): Promise<{ id: string; parts: number } | TelnyxFault> {
  const r = await call<Record<string, unknown>>("POST", "/messages", {
    from: opts.from,
    to: opts.to,
    text: opts.text,
    ...(opts.profileId ? { messaging_profile_id: opts.profileId } : {}),
  });
  if (faultOf(r)) return r;
  return { id: String(r.id), parts: Number(r.parts ?? 1) };
}

// ── Balance ────────────────────────────────────────────────────────────────

export async function getBalance(): Promise<{ usd: number } | TelnyxFault> {
  const r = await call<Record<string, unknown>>("GET", "/balance");
  if (faultOf(r)) return r;
  return { usd: parseFloat(String(r.available_credit ?? r.balance ?? "0")) };
}
