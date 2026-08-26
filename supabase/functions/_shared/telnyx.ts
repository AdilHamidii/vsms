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
  if (status === 402) return "BALANCE_ERROR";
  // 🔴 A MALFORMED REQUEST IS OUR BUG AND MUST NEVER READ AS A STOCKOUT.
  // Telnyx reuses code 10015 for plain validation failures, not only for "no
  // coverage found" — so the `user_name` defect fixed below surfaced to users
  // as OUT_OF_STOCK, i.e. "no numbers available, try another country", for a
  // fault that had nothing to do with stock and that no user action could
  // clear. Observed live in `app_config.telnyx_voice_faults` on 2026-08-17.
  //
  // This guard comes BEFORE the code check deliberately: 400 and 422 mean the
  // request was rejected before Telnyx ever looked at inventory, so stock
  // cannot be the answer whatever the code says.
  if (status === 400 || status === 422) return "TRANSPORT_ERROR";
  // 10015 is "No coverage found ... based on the provided search parameters",
  // observed live for every country Telnyx does not sell SMS+voice in.
  if (code === "10015") return "OUT_OF_STOCK";
  // 40310 "Invalid 'to' address" and 40331 "Missing whitelisted destinations"
  // are our bugs, not stock problems — never let them read as a stockout.
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
    // 🔴 "TELNYX IS CONSISTENTLY JSON" IS FALSE, AND IT THREW AWAY A GOOD
    // TOKEN. `POST /telephony_credentials/{id}/token` answers **201 with a
    // bare JWT as text/plain**. This branch turned that success into a
    // TRANSPORT_ERROR, so `mint-line-token` returned `provider_unreachable`
    // and no call could be placed — even though Telnyx had just issued the
    // credential. Caught on the very first successful mint, 2026-08-17, by the
    // `status` field added to `telnyx_voice_faults`: a fault carrying **201**
    // is a contradiction in terms.
    //
    // `mintCredentialToken` already anticipates this ("returns a bare JWT as
    // text/plain on some API versions") and branches on `typeof r === "string"`
    // — but that branch was UNREACHABLE, because this one converted the body
    // to a fault first. Hand the raw text back on a successful status and let
    // the caller decide; every other endpoint returns JSON and is unaffected.
    if (resp.ok) return text as unknown as T;
    // A non-2xx with an unparseable body really is a proxy or an outage page.
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

/// 🔴 `user_name` IS A SIP USERNAME, NOT A LABEL — and passing our readable
/// connection name there made calling IMPOSSIBLE for every subscriber from the
/// day the feature shipped.
///
/// Telnyx requires it to be **4–32 characters, alphanumeric only**, with at
/// least one letter among the first five. We sent `vsms-<line-uuid>`: 41
/// characters AND hyphenated, so `POST /credential_connections` returned a
/// validation error on every single call. No line ever received a connection, a
/// credential or a voice attach — all five sold showed null across
/// `provider_connection_id`, `provider_credential_id` and
/// `provider_voice_attached` — so outbound AND inbound calling were unreachable
/// by construction while the paywall advertised them.
///
/// Recorded live in `app_config.telnyx_voice_faults` at 2026-08-17T00:31:39Z:
/// "Must contain only letters and numbers; no spacing allowed" — one minute
/// after a paying subscriber's fifth failed dial, four minutes before they
/// cancelled.
///
/// `connection_name` is a display label and keeps the readable form; only the
/// SIP fields are constrained. Deriving both from ONE string is what hid this:
/// the constraint lives on one field while the value looked perfectly fine.
const SIP_MAX = 32;

/** Alphanumeric, <= 32 chars, guaranteed to start with a letter. The `vsms`
 *  prefix satisfies the "letter among the first five" rule on its own, so the
 *  remainder can be pure hex. 24 hex chars of a v4 UUID is ~96 bits — far past
 *  any collision concern on an account holding one connection per line. */
function sipSafe(seed: string): string {
  return ("vsms" + seed.replace(/[^a-zA-Z0-9]/g, "")).slice(0, SIP_MAX);
}

/** A SIP password Telnyx will accept. `randomUUID()` is hex, so roughly 10% of
 *  the time its first five characters are all digits — which trips the same
 *  "at least one letter early" rule that broke `user_name`, and would have
 *  turned this into an INTERMITTENT failure the moment the username was fixed.
 *  Seeding a letter in front removes the class outright. */
function sipPassword(): string {
  return "v" + crypto.randomUUID().replace(/-/g, "").slice(0, 24);
}

export async function createCredentialConnection(opts: {
  name: string; pushCredentialId?: string;
}): Promise<{ id: string } | TelnyxFault> {
  const r = await call<Record<string, unknown>>("POST", "/credential_connections", {
    connection_name: opts.name,
    user_name: sipSafe(opts.name),
    // Telnyx requires a password on the connection even though the client
    // authenticates with a short-lived token rather than these credentials.
    password: sipPassword(),
    ...(opts.pushCredentialId
      ? { ios_push_credential_id: opts.pushCredentialId }
      : {}),
  });
  if (faultOf(r)) return r;
  return { id: String(r.id) };
}

/**
 * The Outbound Voice Profile a connection needs before it can place ANY call.
 *
 * 🔴 NOTHING IN THIS REPO EVER CREATED ONE. `phone_lines.provider_voice_profile_id`
 * has existed since the first line migration and both provisioning paths pass
 * `p_voice_profile: null` — a column with no writer, which is the third
 * instance of that shape here after `line_subscriptions` and
 * `line_threads.blocked`. Telnyx requires a profile on the connection to place
 * an outbound call, so this was a SECOND reason calling never worked, sitting
 * behind the invalid SIP username and equally silent.
 *
 * ⚠️ `whitelisted_destinations` is where the money risk lives. A new profile
 * allows US/CA only, which is correct for the plan's minute allowance. Adding a
 * country here makes it DIALLABLE — it does not make it PRICED, and the two must
 * move together: `voice_rates.enabled` is the price half, this is the
 * permission half, and enabling either alone is a bug. Some destinations also
 * need Level 2 verification on the account before Telnyx will activate them.
 *
 * `daily_spend_limit` is the backstop that turns an International Revenue Share
 * Fraud attempt into a capped loss. It is deliberately set even though the
 * credit reservation already bounds each call: the reservation protects the
 * ALLOWANCE, this protects the ACCOUNT.
 */
export async function createOutboundVoiceProfile(opts: {
  name: string;
  destinations?: string[];
  dailySpendLimitUsd?: string;
}): Promise<{ id: string } | TelnyxFault> {
  const r = await call<Record<string, unknown>>("POST", "/outbound_voice_profiles", {
    name: opts.name,
    traffic_type: "conversational",
    service_plan: "global",
    enabled: true,
    // US/CA unless told otherwise — the plan's own territory, and the only
    // destinations whose rates the minute allowance can absorb.
    whitelisted_destinations: opts.destinations ?? ["US", "CA"],
    daily_spend_limit_enabled: true,
    daily_spend_limit: opts.dailySpendLimitUsd ?? "5.00",
  });
  if (faultOf(r)) return r;
  return { id: String(r.id) };
}

/**
 * Re-point an EXISTING profile at a new destination list.
 *
 * Needed because `whitelisted_destinations` is fixed at creation, so widening
 * the catalog does nothing for lines already provisioned — the customer who
 * subscribed yesterday would keep yesterday's permissions forever, with no
 * error anywhere. `sync-voice-destinations` calls this for every profile we
 * know about, on a schedule, so the answer to "did the widening reach live
 * lines?" is a query rather than a hope.
 */
export async function updateOutboundVoiceProfile(
  profileId: string, destinations: string[],
): Promise<true | TelnyxFault> {
  const r = await call<Record<string, unknown>>(
    "PATCH", `/outbound_voice_profiles/${profileId}`,
    { whitelisted_destinations: destinations });
  if (faultOf(r)) return r;
  return true;
}

/** Point a credential connection at its outbound profile. Without this the
 *  connection can register and receive, but every outbound call is rejected.
 *
 *  🔴 THE FIELD IS NESTED UNDER `outbound`, NOT TOP-LEVEL — and this function
 *  sent it top-level from 2026-08-06 until 2026-08-18. Telnyx returned 200
 *  and changed NOTHING (its documented silent-no-op on a misplaced field —
 *  the third time this file has hit that pattern, after `messaging_profile_id`
 *  and `features.sms.international_inbound`). So every connection was marked
 *  `provider_voice_attached = true` in OUR database while Telnyx held no
 *  profile at all, and every outbound dial was rejected before a session
 *  existed: 0 of 7 calls ever produced a `provider_call_session_id`, and the
 *  device showed "music ducks for a few seconds and comes back" — CallKit
 *  activating audio, the INVITE being refused, the session torn down. This
 *  was diagnosed as a device-side bug for twelve days.
 *
 *  Verified 2026-08-18 by reading connection 3028594732042290885 back
 *  through `probe-telnyx-connection`: `outbound.outbound_voice_profile_id`
 *  was NULL on a line we had recorded as attached.
 *
 *  So this function now (a) sends the documented shape and (b) READS THE
 *  CONNECTION BACK and only returns true if the profile is actually there.
 *  A 200 is not evidence on this API; the read-back is. */
export async function attachOutboundProfile(
  connectionId: string, profileId: string,
): Promise<true | TelnyxFault> {
  const r = await call<Record<string, unknown>>(
    "PATCH", `/credential_connections/${connectionId}`,
    { outbound: { outbound_voice_profile_id: profileId } });
  if (faultOf(r)) return r;
  // Read-back: the only proof that survives a silent no-op.
  const back = await call<{ outbound?: { outbound_voice_profile_id?: string | null } }>(
    "GET", `/credential_connections/${connectionId}`);
  if (faultOf(back)) return back;
  const held = back.outbound?.outbound_voice_profile_id ?? null;
  if (held !== profileId) {
    return {
      telnyxFault: true,
      // TRANSPORT_ERROR is the honest bucket: the request "succeeded" and the
      // provider did not do what it acknowledged — retryable, not a stockout,
      // not auth, not balance.
      type: "TRANSPORT_ERROR",
      status: 200,
      detail: `attachOutboundProfile: PATCH returned 200 but read-back holds ` +
              `${JSON.stringify(held)} — expected ${profileId}. Field shape may have changed.`,
    };
  }
  return true;
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
  //
  // ✅ CONFIRMED text/plain on 2026-08-17, on the first mint that ever
  // succeeded: HTTP 201 with the raw JWT as the whole body. This branch was
  // unreachable until `call()` stopped treating an unparseable OK body as a
  // fault — see the note there.
  //
  // TRIMMED, because a trailing newline survives every check we make and then
  // fails inside `TxConfig` on the device, where the only symptom is a call
  // that will not connect and nothing logged server-side.
  if (typeof r === "string") {
    const t = r.trim();
    return t
      ? { token: t }
      : { telnyxFault: true, type: "TRANSPORT_ERROR", status: 200,
          detail: "empty token body" };
  }
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
  /** Telnyx's own rounded-up figure (`billed_sec`), recorded for margin work
   *  and NEVER used for the allowance — see normaliseCallRecord. */
  providerBilledSeconds: number | null;
  costCents: number | null;
  /** The EXACT amount. `costCents` rounds a $0.004 leg to 0, which is what
   *  made per-message cost recording useless — see line_messages.
   *  provider_cost_usd. Arithmetic reads this; display reads the cents. */
  costUsd: number | null;
  hangupCause: string | null;
  direction: string | null;
  /** `webrtc` / `sip-trunking` / … — decides which record wins in a merge. */
  recordType: string | null;
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
  // 🔴 `telnyx_session_id` FIRST, AND `session_id` IS A TRAP. Measured against
  // live records 2026-08-26 (probe-telnyx-connection, mode "cdr"): a `webrtc`
  // record carries BOTH, and they are different uuids —
  //   telnyx_session_id: 475d4f74-9fc8-11f1-9a10-1273ee35360b  ← ours
  //   session_id:        5ea3db0a-c658-4494-8901-d0847b03cbdf  ← the SDK's own
  // This function used to read `call_session_id ?? session_id`, so it
  // normalised 43 of 43 webrtc rows onto the WRONG uuid and the exact-string
  // match in sync-telnyx-cdr could never succeed. `sip-trunking` records carry
  // no `session_id` at all and were dropped outright, 0 of 50.
  //
  // The old keys are kept as fallbacks but ranked LAST: they are what the
  // documentation describes, they cost nothing, and nothing observed so far
  // uses them.
  const sessionId = (r.telnyx_session_id ?? r.call_session_id ?? r.session_id ?? null) as string | null;
  // `id` is the LEG on both record types (webrtc and sip-trunking both had
  // id === telnyx_leg_id), which is why it is an acceptable fallback here and
  // would be wrong as a session fallback above.
  const legId = (r.telnyx_leg_id ?? r.call_leg_id ?? r.leg_id ?? r.id ?? null) as string | null;
  if (!sessionId && !legId) return null;

  // ⚠️ `call_sec` and `billed_sec` are the REAL field names — none of the four
  // documented ones below appears on a live record, so even a correctly
  // matched record used to normalise to `billedSeconds: null` and be skipped
  // as unmatched. Three separate defects had to line up for a settlement, and
  // all three were present.
  //
  // 🔴 WE SETTLE ON `call_sec`, NOT `billed_sec`, AND THAT IS A PRODUCT
  // DECISION. Telnyx bills in 60-second increments — the 2026-08-24 call ran
  // 249s and billed 300s — but the allowance we sell is 100 MINUTES OF TALKING,
  // and rounding a user's meter up to the provider's billing granularity would
  // charge them 51 seconds they did not use. Their rounding is their cost
  // model, not our product. `providerBilledSeconds` carries their figure for
  // margin work, so nothing is lost; `costUsd` is unaffected either way.
  let billed = firstNumber(r, [
    "call_sec",
    "billed_duration_secs", "billed_seconds", "duration_secs",
  ]);
  if (billed == null) {
    const ms = firstNumber(r, ["duration_millis", "duration_ms"]);
    if (ms != null) billed = Math.ceil(ms / 1000);
  }
  // Their rounded figure, recorded and never used for the allowance.
  const providerBilled = firstNumber(r, ["billed_sec", "billed_duration_secs"]);

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
    providerBilledSeconds: providerBilled,
    costCents,
    costUsd,
    hangupCause: (r.hangup_cause ?? r.cause ?? null) as string | null,
    direction: (r.direction ?? null) as string | null,
    recordType: (r.record_type ?? null) as string | null,
    raw: r,
  };
}

/** One call, assembled from every record that describes it.
 *
 *  🔴 A WebRTC→PSTN call writes TWO records with the SAME `telnyx_session_id`
 *  and DIFFERENT costs — measured live on the 2026-08-24 call:
 *
 *  | record_type  | call_sec | billed_sec | cost   | hangup_cause    |
 *  |--------------|----------|------------|--------|-----------------|
 *  | webrtc       | 249      | 300        | $0.010 | (absent)        |
 *  | sip-trunking | 249      | 300        | $0.025 | NORMAL_CLEARING |
 *
 *  Both are real charges — the WebRTC leg and the PSTN leg — so the wholesale
 *  cost of that call is **$0.035**, and taking either record alone understates
 *  it (by 71% or by 29%). Costs are therefore SUMMED across the pair.
 *
 *  Everything else is taken from the `sip-trunking` record where it exists: it
 *  is the only one carrying `hangup_cause` and `answered_at`. Duration is the
 *  max, which is a no-op while both agree and fails toward over-billing rather
 *  than under-billing if they ever diverge — the standing rule for this table
 *  (an over-charge is bounded, visible in the ledger and refundable by hand;
 *  an under-charge is unbounded, invisible and repeatable).
 *
 *  Without this merge the same call would settle twice against the allowance,
 *  once per record type — `settle_call_claim`'s row lock makes the second a
 *  no-op today, but that is a guard being leaned on, not a design. */
export function mergeCallRecords(records: TelnyxCallRecord[]): TelnyxCallRecord[] {
  const byKey = new Map<string, TelnyxCallRecord>();
  for (const r of records) {
    const key = r.sessionId ?? r.legId;
    if (!key) continue;
    const prev = byKey.get(key);
    if (!prev) { byKey.set(key, { ...r }); continue; }

    // Prefer the sip-trunking record as the base — hangup_cause / answered_at.
    const base = r.recordType === "sip-trunking" ? { ...r } : { ...prev };
    const other = r.recordType === "sip-trunking" ? prev : r;

    base.billedSeconds = Math.max(base.billedSeconds ?? 0, other.billedSeconds ?? 0) || null;
    base.providerBilledSeconds =
      Math.max(base.providerBilledSeconds ?? 0, other.providerBilledSeconds ?? 0) || null;
    // Summed, not maxed. Both legs are billed.
    base.costUsd = (base.costUsd ?? 0) + (other.costUsd ?? 0) || null;
    base.costCents = base.costUsd == null ? null : Math.round(base.costUsd * 100);
    base.hangupCause = base.hangupCause ?? other.hangupCause;
    base.legId = base.legId ?? other.legId;
    base.sessionId = base.sessionId ?? other.sessionId;
    byKey.set(key, base);
  }
  return [...byKey.values()];
}

/** 🔴 THE WINDOW FILTER IS `filter[date_range]=last_30_days`, IT IS THE ONLY
 *  ONE PROVEN TO RETURN ROWS, AND THE LADDER THAT USED TO LIVE HERE IS GONE.
 *
 *  Settled by probe on 2026-08-26 (`probe-telnyx-connection`, mode "cdr"),
 *  against a month of real calls on the live account:
 *
 *  | shape                                   | HTTP | rows |
 *  |-----------------------------------------|------|------|
 *  | `filter[date_range]=last_30_days`       | 200  | **43 webrtc / 50 sip-trunking** |
 *  | no window at all                        | 200  | **43 / 50** |
 *  | `filter[start_time][gte]/[lte]`         | 200  | **0 on every record type** |
 *  | `filter[created_at][gte]/[lt]`          | 200  | **0 on every record type** |
 *  | `filter[date_range][start_time]/[end_…]`| 400  | `No FilterType with name end_time was found` |
 *
 *  🔴 THE LADDER IS DELETED BECAUSE IT IS THE BUG, NOT THE FIX. It accepted a
 *  **200 as proof a shape works**, cached the winning index in
 *  `app_config.telnyx_cdr_shape`, and `filter[start_time][gte]` answers 200
 *  and matches nothing — so it locked onto a dead filter on 2026-08-06 and
 *  settled zero records for twenty days while reporting success every ten
 *  minutes. That is the same silent-no-op-on-200 this adapter has now hit
 *  FOUR times (`messaging_profile_id`, `features.sms.international_inbound`,
 *  `outbound_voice_profile_id`, and this). **On this API a 200 is not
 *  evidence. Only rows are.**
 *
 *  ⚠️ DO NOT "IMPROVE" THIS INTO A NARROWER BUCKET WITHOUT PROBING IT FIRST.
 *  `last_30_days` is the only value observed to work; Telnyx documents no enum
 *  we could confirm, and an unproven bucket would fail in exactly the way that
 *  caused this outage — 200, zero rows, indistinguishable from a quiet hour.
 *  Thirty days of records is ~50 rows at current volume and is bounded by
 *  `maxPages` regardless, so there is nothing to win here and a repeat of a
 *  twenty-day silent outage to lose.
 *
 *  The caller matches records against its own pending set, so a window wider
 *  than the lookback is harmless: it costs a few extra rows per page, never a
 *  wrong settlement. */
const CDR_DATE_RANGE = "last_30_days";

/** Telnyx caps `page[size]` at 50. We sent 250 for twenty days; it was
 *  tolerated rather than fatal (the probe got the same 43 rows either way),
 *  but an over-max value is one API revision away from becoming a 400 or a
 *  silent empty page, which is the failure this file exists to avoid. */
const CDR_MAX_PAGE_SIZE = 50;

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
 *  shape of the first record seen.
 *
 *  ✅ OBSERVED 2026-08-26: `webrtc` and `sip-trunking` both carry our calls —
 *  the SAME call, one record each, joined by `telnyx_session_id`. See
 *  `mergeCallRecords`. `call-control` and `conference` returned zero rows and
 *  are kept because they cost one request each and a future call-control leg
 *  would otherwise be invisible. */
const CDR_RECORD_TYPES = [
  "webrtc",        // a credential connection is a WebRTC endpoint
  "sip-trunking",  // the PSTN leg of an outbound call
  "call-control",
  "conference",
] as const;

/** Call detail records for the fixed 30-day window.
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
 *  say so instead of quietly under-settling.
 *
 *  🔴 `sinceISO`/`untilISO` ARE NO LONGER SENT TO TELNYX and are kept only for
 *  the caller's own bookkeeping. There is no window-shape ladder any more and
 *  no cached "winning shape": both were the bug — see `CDR_DATE_RANGE`. The
 *  window is `last_30_days`, always, and the caller matches against its own
 *  pending set, so a wider window costs rows and never correctness.
 *
 *  Records are MERGED per call before returning (`mergeCallRecords`): a
 *  WebRTC→PSTN call writes one `webrtc` and one `sip-trunking` record with the
 *  same `telnyx_session_id` and different costs. */
export async function fetchCallDetailRecords(opts: {
  sinceISO: string;
  untilISO: string;
  pageSize?: number;
  maxPages?: number;
}): Promise<
  | {
      records: TelnyxCallRecord[]; pages: number; truncated: boolean;
      /** Kept in the return shape so the heartbeat keeps its field, but it is
       *  now a constant: there is one window shape and it is proven. */
      shape: string; types: string[];
      /** Rows Telnyx returned BEFORE normalisation and merging. The gap
       *  between this and `records.length` is what twenty days of silent
       *  failure looked like, and it is now visible in the heartbeat. */
      rawRows: number;
    }
  | TelnyxFault
> {
  const size = Math.min(opts.pageSize ?? CDR_MAX_PAGE_SIZE, CDR_MAX_PAGE_SIZE);
  const maxPages = Math.max(opts.maxPages ?? 8, 1);

  const collected: TelnyxCallRecord[] = [];
  const workingTypes: string[] = [];
  let pagesRead = 0;
  let rawRows = 0;
  let truncated = false;
  let sawOk = false;
  let lastFault: TelnyxFault | null = null;

  for (const recordType of CDR_RECORD_TYPES) {
    for (let page = 1; page <= maxPages; page++) {
      const params = new URLSearchParams({
        "filter[record_type]": recordType,
        "filter[date_range]": CDR_DATE_RANGE,
        "page[size]": String(size),
        "page[number]": String(page),
      });
      const r = await call<Record<string, unknown>[]>("GET", `/detail_records?${params}`);
      if (faultOf(r)) {
        lastFault = r;
        // A 400 means THIS record type is not valid on this account — the
        // window is fixed and proven, so it cannot be the window. Move to the
        // next type. Anything else (auth, rate limit, transport) will fail
        // identically for every type and would just burn the request budget.
        if (r.status !== 400) {
          return collected.length > 0
            ? { records: mergeCallRecords(collected), pages: pagesRead,
                truncated: true, shape: CDR_DATE_RANGE, types: workingTypes, rawRows }
            : r;
        }
        break;
      }
      sawOk = true;
      if (!workingTypes.includes(recordType)) workingTypes.push(recordType);
      pagesRead++;

      const rows = Array.isArray(r) ? r : [];
      rawRows += rows.length;
      for (const x of rows) {
        const rec = normaliseCallRecord(x as Record<string, unknown>);
        // Dropped records are NOT silent any more — `rawRows` above counts what
        // arrived, so `rawRows > records.length` is legible in the heartbeat
        // instead of reading as "Telnyx returned nothing". That ambiguity is
        // precisely what hid the wrong-id-field half of this bug.
        if (!rec) continue;
        collected.push(rec);
      }
      // A short page is the last page. Telnyx's meta block is not relied on:
      // this file's standing rule is that an undocumented field is a guess.
      if (rows.length < size) break;
      if (page === maxPages) truncated = true;
    }
  }

  if (!sawOk) {
    return lastFault ?? {
      telnyxFault: true, type: "TRANSPORT_ERROR", status: 400,
      detail: "no detail_records record type answered",
    };
  }

  return {
    records: mergeCallRecords(collected),
    pages: pagesRead, truncated, shape: CDR_DATE_RANGE, types: workingTypes, rawRows,
  };
}

// ── Balance ────────────────────────────────────────────────────────────────

export async function getBalance(): Promise<{ usd: number } | TelnyxFault> {
  const r = await call<Record<string, unknown>>("GET", "/balance");
  if (faultOf(r)) return r;
  return { usd: parseFloat(String(r.available_credit ?? r.balance ?? "0")) };
}
