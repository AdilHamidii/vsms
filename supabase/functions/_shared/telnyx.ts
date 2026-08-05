// Telnyx adapter — the fourth product line (rentable second numbers).
//
// ⚠️ THIS FILE IS DELIBERATELY INCOMPLETE. It currently contains ONLY the
// webhook signature verifier and the fault vocabulary. The endpoint wrappers
// (numbers, messaging, voice, CDR, balance) are NOT here yet, on purpose:
// this repo's adapters are written AFTER probing the live API, never from the
// documentation. `heromail.ts` is the reference — probing is why the 2-minute
// cancel floor, the `Authorization: ApiKey` scheme and the overloaded `CANCEL`
// status are documented facts rather than guesses, and why `getPrices`
// advertising a price with ZERO stock behind it was caught before it cost
// another customer their session.
//
// The signature verifier is here first because it is the one piece that is
// fully determined without an account: it is pure crypto with a published
// contract, and it is the gate everything else sits behind.
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
  // 422 is Telnyx's "we understood you and refused": number already taken,
  // number no longer available, regulatory requirements unmet.
  if (status === 422 && code && /1001[45]|10015|numbers?_not_available/i.test(code)) {
    return "OUT_OF_STOCK";
  }
  if (status === 402) return "BALANCE_ERROR";
  return "TRANSPORT_ERROR";
}
