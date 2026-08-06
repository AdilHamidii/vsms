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
  /** False when Telnyx omitted `cost_information` entirely and the figures
   *  above are the measured US/CA fallback rather than a quote. The float
   *  guard must not treat a guess as a quote. */
  costKnown: boolean;
  reservable: boolean;
  region: string | null;
}

const cents = (v: unknown) => Math.round(parseFloat(String(v ?? "0")) * 100);

/** 🔴 `cost_information` MISSING IS NOT `cost_information` ZERO.
 *
 *  `cents(undefined)` is 0, and the float guard in `reserve-line-number` adds
 *  its numbers up before comparing them against the Telnyx balance — so a
 *  response that simply omitted the costs degraded a real check into
 *  "do we have 50 cents?" and would have waved through a purchase we could not
 *  afford. Apple has already charged $9.99 by the time we find out.
 *
 *  Measured 2026-08-05: US and CA local are both a flat $1.00 upfront +
 *  $1.00/month, every type probed. So an absent figure falls back to that
 *  measured rate rather than to zero, and `costKnown` says which it was. This
 *  is the same distinction as HeroSMS's `herosms_real_count`: null means "not
 *  probed", 0 means "probed, nothing there", and collapsing them is how a
 *  guard stops guarding. */
const FALLBACK_UPFRONT_CENTS = 100;
const FALLBACK_MONTHLY_CENTS = 100;

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
    const costKnown = ci.monthly_cost != null || ci.upfront_cost != null;
    return {
      phoneNumber: String(n.phone_number),
      type: String(n.phone_number_type),
      monthlyCents: ci.monthly_cost != null
        ? cents(ci.monthly_cost) : FALLBACK_MONTHLY_CENTS,
      upfrontCents: ci.upfront_cost != null
        ? cents(ci.upfront_cost) : FALLBACK_UPFRONT_CENTS,
      costKnown,
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

/** A hold on a specific number while the user decides.
 *
 *  ⚠️ **UNPROVEN AGAINST THE LIVE API.** Everything else in this file was
 *  written after probing; this was not, because the account balance is $2.33
 *  and the GB incident cost $3.83 by trusting a field that meant nothing. The
 *  documented behaviour is a free ~30-minute hold, and `searchNumbers` does
 *  report `reservable: true` — but "documented" and "measured" are different
 *  things in this file, so:
 *
 *  - `reserve-line-number` snapshots the Telnyx balance either side of the
 *    FIRST call and records the delta, which settles the cost question with
 *    one real invocation.
 *  - Every caller must treat a fault as ORDINARY. The store screen already
 *    renders a number with no hold as "Available now" rather than showing a
 *    countdown, so a reservation failing costs nothing but the countdown.
 *
 *  Returns `expiresAt` as an ISO string when Telnyx supplies one. A hold with
 *  no expiry is returned as `null` rather than invented — the UI keys its
 *  countdown on exactly that.
 */
export async function reserveNumber(
  phoneNumber: string, customerReference: string,
): Promise<{ reservationId: string; expiresAt: string | null } | TelnyxFault> {
  const r = await call<Record<string, unknown>>("POST", "/number_reservations", {
    phone_numbers: [{ phone_number: phoneNumber }],
    customer_reference: customerReference,
  });
  if (faultOf(r)) return r;

  const nums = (r.phone_numbers ?? []) as Array<Record<string, unknown>>;
  const mine = nums.find((n) => String(n.phone_number) === phoneNumber) ?? nums[0];
  const exp = mine?.expired_at ?? r.expired_at ?? null;
  return {
    reservationId: String(r.id),
    expiresAt: exp ? String(exp) : null,
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

// ── Voice: credential connections and WebRTC tokens ────────────────────────
//
// ⚠️ **UNPROVEN AGAINST THE LIVE API**, like `reserveNumber` and for the same
// reason — these were written from the docs, not from probing, because the
// account balance does not currently support exercising voice end to end.
// Everything else in this file was probed first. Treat the shapes below as
// provisional and re-verify before trusting them in production.
//
// A per-line CREDENTIAL CONNECTION is deliberate: inbound to a DID then rings
// only that DID's registrations, so user A can never be rung for user B's
// number. The alternative — one shared connection — makes that separation a
// matter of application logic rather than provider configuration.
//
// The Call Control alternative was rejected outright: routing inbound calls
// through an edge function puts a Deno cold start on the ring path (300–1500ms
// of dead air) and makes every inbound call fail during any incident that takes
// the edge layer down. That is precisely the scenario `run_watchdog` is written
// in pure SQL to survive.

export async function createCredentialConnection(opts: {
  name: string; pushCredentialId?: string;
}): Promise<{ id: string } | TelnyxFault> {
  const r = await call<Record<string, unknown>>("POST", "/credential_connections", {
    connection_name: opts.name,
    user_name: opts.name,
    // Telnyx requires a password on the connection even though the client
    // authenticates with a short-lived token rather than these credentials.
    password: crypto.randomUUID().replace(/-/g, ""),
    ...(opts.pushCredentialId
      ? { ios_push_credential_id: opts.pushCredentialId }
      : {}),
  });
  if (faultOf(r)) return r;
  return { id: String(r.id) };
}

/** A login for one line's connection. Cache the id on
 *  `phone_lines.provider_credential_id`: DELETING it on lapse is what makes
 *  suspension real rather than client-side theatre. */
export async function createTelephonyCredential(opts: {
  connectionId: string; name: string;
}): Promise<{ id: string } | TelnyxFault> {
  const r = await call<Record<string, unknown>>("POST", "/telephony_credentials", {
    connection_id: opts.connectionId,
    name: opts.name,
  });
  if (faultOf(r)) return r;
  return { id: String(r.id) };
}

/** Short-lived JWT the iOS client feeds to `TxConfig`.
 *
 *  ⚠️ NEVER ship the Telnyx API key to a device. This endpoint exists so the
 *  client holds a credential scoped to one line and expiring on its own, rather
 *  than a key that can buy numbers. */
export async function mintCredentialToken(
  credentialId: string,
): Promise<{ token: string } | TelnyxFault> {
  const r = await call<unknown>(
    "POST", `/telephony_credentials/${credentialId}/token`);
  if (faultOf(r)) return r;
  // This endpoint returns a bare JWT as text/plain on some API versions and a
  // wrapped object on others — accept both rather than guessing.
  if (typeof r === "string") return { token: r };
  const obj = r as Record<string, unknown>;
  const tok = obj.token ?? obj.data ?? null;
  // TRANSPORT_ERROR, not a stockout: the call SUCCEEDED and the body was not
  // what we expected. Never classify an unknown failure as OUT_OF_STOCK — that
  // is what sends users country-shopping during an outage, and on this line
  // there is no other country to shop to.
  if (!tok) {
    return {
      telnyxFault: true, type: "TRANSPORT_ERROR", status: 200,
      detail: "no token in response",
    };
  }
  return { token: String(tok) };
}

export async function deleteTelephonyCredential(
  credentialId: string,
): Promise<true | TelnyxFault> {
  const r = await call<unknown>("DELETE", `/telephony_credentials/${credentialId}`);
  if (faultOf(r)) return r;
  return true;
}

/** Point a number's VOICE at a connection. Like messaging, this is NOT settable
 *  on the main number resource — it lives on the /voice sub-resource, and the
 *  main one returns 10027 "not reachable here". */
export async function attachVoiceConnection(
  numberId: string, connectionId: string,
): Promise<true | TelnyxFault> {
  const r = await call<unknown>("PATCH", `/phone_numbers/${numberId}/voice`, {
    connection_id: connectionId,
  });
  if (faultOf(r)) return r;
  return true;
}

// ── Call detail records ────────────────────────────────────────────────────
//
// ⚠️ **WRITTEN FROM THE DOCS, NOT PROBED** — the same caveat as the voice block
// above, and for the same reason: there is no line to place a call on yet. The
// FIRST real CDR poll is the probe. `sync-telnyx-cdr` records every fault and
// the shape of the first record it sees into `app_config.telnyx_cdr_probe`, so
// the unknowns below become answerable from one production run rather than
// from a second reading of the documentation.
//
// Three things that are genuinely uncertain and are handled defensively:
//  - the billed-duration field name (`billed_duration_secs` is documented;
//    `duration_millis` also appears in examples),
//  - whether `cost` is a string, a number, or an object with a currency,
//  - whether `call_session_id` is present on every record type or only on
//    legs. We match on session id and fall back to leg id.

export interface TelnyxCallRecord {
  sessionId: string | null;
  legId: string | null;
  billedSeconds: number | null;
  costCents: number | null;
  /** The EXACT amount. `costCents` rounds a $0.004 leg to 0, which is what
   *  made per-message cost recording useless — see line_messages.
   *  provider_cost_usd. Arithmetic reads this; display reads the cents. */
  costUsd: number | null;
  hangupCause: string | null;
  direction: string | null;
  raw: Record<string, unknown>;
}

function firstNumber(o: Record<string, unknown>, keys: string[]): number | null {
  for (const k of keys) {
    const v = o[k];
    if (v == null) continue;
    const n = typeof v === "number" ? v : parseFloat(String(v));
    if (Number.isFinite(n)) return n;
  }
  return null;
}

/** Normalises whatever shape a record arrives in. Returns `null` for a record
 *  we cannot key on at all rather than inventing an id — settling the wrong
 *  call is worse than settling none. */
export function normaliseCallRecord(
  r: Record<string, unknown>,
): TelnyxCallRecord | null {
  const sessionId = (r.call_session_id ?? r.session_id ?? null) as string | null;
  const legId = (r.call_leg_id ?? r.leg_id ?? null) as string | null;
  if (!sessionId && !legId) return null;

  // Prefer an explicit billed figure; fall back to a duration, in whichever
  // unit it arrives in. Milliseconds are rounded UP to the second so a
  // sub-second call still costs the user something rather than nothing.
  let billed = firstNumber(r, ["billed_duration_secs", "billed_seconds", "duration_secs"]);
  if (billed == null) {
    const ms = firstNumber(r, ["duration_millis", "duration_ms"]);
    if (ms != null) billed = Math.ceil(ms / 1000);
  }

  const costRaw = r.cost ?? r.total_cost ?? null;
  let costCents: number | null = null;
  let costUsd: number | null = null;
  if (costRaw != null) {
    const amount = typeof costRaw === "object"
      ? firstNumber(costRaw as Record<string, unknown>, ["amount", "value"])
      : firstNumber({ v: costRaw }, ["v"]);
    if (amount != null) {
      costUsd = amount;
      // Kept for display and for every existing consumer. It is LOSSY by
      // construction — Telnyx bills fractions of a cent — so anything doing
      // arithmetic must read `costUsd`.
      costCents = Math.round(amount * 100);
    }
  }

  return {
    sessionId,
    legId,
    billedSeconds: billed,
    costCents,
    costUsd,
    hangupCause: (r.hangup_cause ?? r.cause ?? null) as string | null,
    direction: (r.direction ?? null) as string | null,
    raw: r,
  };
}

/** The time-window filter shapes, most-likely first.
 *
 *  🔴 MEASURED, NOT ASSUMED — and the docs-written one is WRONG. The first
 *  production run of `sync-telnyx-cdr` returned
 *  **400 `No FilterType with name end_time was found.`** against
 *  `filter[date_range][start_time]/[end_time]`, which is exactly the shape the
 *  documentation implies. That error is also the clue to the right answer: it
 *  names `end_time` as the unknown filter and NOT `start_time`, so `start_time`
 *  parses as a real FilterType and the `[gte]`/`[lte]` form is the candidate.
 *
 *  Rather than guess again, the caller walks this ladder until one shape
 *  returns 200 and records the winning index. One production run answers what
 *  a second reading of the documentation cannot — the same discipline as
 *  5sim's `fetch_faults` histogram, which settled the 403-vs-429 question on
 *  its first run after weeks of speculation.
 *
 *  The last entry is deliberately EMPTY: no window at all, bounded by page
 *  size. The caller matches records against its own pending set anyway, so an
 *  unfiltered page is degraded but correct — far better than settling nothing
 *  because we cannot name a date field. */
const CDR_WINDOW_SHAPES: Array<(s: string, u: string) => Record<string, string>> = [
  (s, u) => ({ "filter[start_time][gte]": s, "filter[start_time][lte]": u }),
  (s, u) => ({ "filter[created_at][gte]": s, "filter[created_at][lte]": u }),
  (s, u) => ({ "filter[date_range][start_time]": s, "filter[date_range][end_time]": u }),
  () => ({}),
];

export const CDR_SHAPE_COUNT = CDR_WINDOW_SHAPES.length;

/** 🔴 `record_type: "call"` IS NOT A THING — measured, not assumed. The second
 *  probe run returned **400 `No matching record type was found matching given
 *  record type call`**, so the documentation-shaped value was wrong twice over
 *  in the same endpoint.
 *
 *  ⚠️ EVERY VALID TYPE IS QUERIED AND MERGED rather than picking one. The
 *  reason is specific and would otherwise have produced a silent, permanent
 *  bug: no call has ever been placed on this account, so the FIRST valid type
 *  returns `[]` — a perfectly good 200 — and caching it would lock the poller
 *  onto a record type our calls may never appear in. It would then settle
 *  nothing, forever, while reporting success every ten minutes.
 *
 *  Reads are free and there are only a handful of types, so merging removes
 *  the guess entirely. Which types actually carry our legs becomes an
 *  observation once a real call happens — `telnyx_cdr_probe` records the raw
 *  shape of the first record seen. */
const CDR_RECORD_TYPES = [
  "webrtc",        // a credential connection is a WebRTC endpoint
  "sip-trunking",  // the PSTN leg of an outbound call
  "call-control",
  "conference",
] as const;

/** Call detail records since `sinceISO`.
 *
 *  ⚠️ PAGINATED. The first version fetched page one and stopped, which reads as
 *  "there were only 100 records" — so on any busy window the oldest calls
 *  would silently never settle and would keep their full reservation until the
 *  six-hour stale sweep wrote them off at the client's word. A truncated list
 *  that looks complete is the same failure as PostgREST's silent `max_rows`
 *  truncation, and it is invisible for the same reason.
 *
 *  Bounded at `maxPages` because the edge runtime dies at ~150s. Hitting the
 *  cap is reported through `truncated` rather than swallowed, so the caller can
 *  say so instead of quietly under-settling. */
export async function fetchCallDetailRecords(opts: {
  sinceISO: string;
  untilISO: string;
  pageSize?: number;
  maxPages?: number;
  /** Last known-good index from `app_config.telnyx_cdr_shape`. Tried first, so
   *  the steady state is one request rather than a ladder walk. */
  preferShape?: number;
}): Promise<
  | {
      records: TelnyxCallRecord[]; pages: number; truncated: boolean;
      shape: number; types: string[];
    }
  | TelnyxFault
> {
  const size = Math.min(opts.pageSize ?? 250, 250);
  const maxPages = Math.max(opts.maxPages ?? 8, 1);

  const order = [...CDR_WINDOW_SHAPES.keys()];
  const preferred = opts.preferShape;
  if (preferred != null && preferred >= 0 && preferred < order.length) {
    order.splice(order.indexOf(preferred), 1);
    order.unshift(preferred);
  }

  let lastFault: TelnyxFault | null = null;
  const seen = new Set<string>();
  const merged: TelnyxCallRecord[] = [];
  const workingTypes: string[] = [];
  let usedShape = -1;
  let pagesRead = 0;
  let truncated = false;

  for (const shape of order) {
    const windowParams = CDR_WINDOW_SHAPES[shape](opts.sinceISO, opts.untilISO);
    let shapeWorked = false;

    for (const recordType of CDR_RECORD_TYPES) {
      for (let page = 1; page <= maxPages; page++) {
        const params = new URLSearchParams({
          "filter[record_type]": recordType,
          ...windowParams,
          "page[size]": String(size),
          "page[number]": String(page),
        });
        const r = await call<Record<string, unknown>[]>("GET", `/detail_records?${params}`);
        if (faultOf(r)) {
          lastFault = r;
          // A 400 means these PARAMETERS are wrong — either the window shape or
          // this record type. Move on. Anything else (auth, rate limit,
          // transport) will fail identically for every combination and would
          // just burn the request budget.
          if (r.status !== 400) {
            return merged.length > 0
              ? { records: merged, pages: pagesRead, truncated: true,
                  shape: usedShape, types: workingTypes }
              : r;
          }
          break;
        }
        // A 200 proves the window shape parses, whatever this record type
        // returned. That is the fact worth caching.
        shapeWorked = true;
        usedShape = shape;
        if (!workingTypes.includes(recordType)) workingTypes.push(recordType);
        pagesRead++;

        const rows = Array.isArray(r) ? r : [];
        for (const x of rows) {
          const rec = normaliseCallRecord(x as Record<string, unknown>);
          // De-duplicated across record types: one call can legitimately
          // appear in more than one, and settling the same session twice would
          // be double-counting against the allowance.
          if (!rec) continue;
          const key = rec.sessionId ?? rec.legId ?? "";
          if (key && seen.has(key)) continue;
          if (key) seen.add(key);
          merged.push(rec);
        }
        // A short page is the last page. Telnyx's meta block is not relied on:
        // this file's standing rule is that an undocumented field is a guess.
        if (rows.length < size) break;
        if (page === maxPages) truncated = true;
      }
    }

    if (shapeWorked) {
      return { records: merged, pages: pagesRead, truncated, shape: usedShape,
               types: workingTypes };
    }
  }

  return lastFault ?? {
    telnyxFault: true, type: "TRANSPORT_ERROR", status: 400,
    detail: "no working detail_records filter shape",
  };
}

// ── Balance ────────────────────────────────────────────────────────────────

export async function getBalance(): Promise<{ usd: number } | TelnyxFault> {
  const r = await call<Record<string, unknown>>("GET", "/balance");
  if (faultOf(r)) return r;
  return { usd: parseFloat(String(r.available_credit ?? r.balance ?? "0")) };
}
