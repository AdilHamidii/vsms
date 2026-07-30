// HeroSMS adapter — SMS-Activate's `handler_api` protocol.
//
// HeroSMS is the successor to SMS-Activate, which closed 2025-12-22 (its own
// site serves the notice; all three of its API hostnames are NXDOMAIN). The
// closure page names HeroSMS and says "We provided our technologies to the
// HeroSMS", and the wire protocol is SMS-Activate's `handler_api` verbatim.
//
// Base is `hero-sms.com/stubs/handler_api.php`. There is NO `api.` subdomain —
// `api.hero-sms.com` is NXDOMAIN, unlike every other provider we integrate.
//
// ── The four wire forms ─────────────────────────────────────────────────────
// This protocol does NOT have one response encoding. Assuming it does is the
// single easiest way to write an adapter that looks fine and silently
// mis-reads production:
//
//   1. JSON object          — getCountries, getPrices, getNumberV2, getStatusV2
//   2. JSON error envelope  — {"title":"BAD_KEY","details":"Unauthorized"}
//   3. bare colon-text      — getNumber ("ACCESS_NUMBER:id:phone"), getStatus
//                             ("STATUS_OK:1234"), setStatus, getBalance
//                             ("ACCESS_BALANCE:10.91"). HTTP 200 throughout.
//   4. Cloudflare HTML      — HTTP 403, `server: cloudflare`, NOT an API error.
//
// Form 4 is not theoretical: it was hit live on 2026-07-30 after ~25 probes in
// a few minutes. There is an unpublished per-second request limit — the vendor
// acknowledged one publicly while pitching webhooks ("no need to poll the API
// for SMS, spending your per-second request limit") but never published the
// number or the breach response. It arrives as HTML with no Retry-After, so it
// MUST be classified RATE_LIMITED. Classifying it AUTH_ERROR pages the owner
// for a healthy key; classifying it OUT_OF_STOCK tells users "try another
// country" while we are merely throttled.
//
// ── Currency ────────────────────────────────────────────────────────────────
// SMS-Activate redenominated prices RUB -> USD on 2025-02-04 and added a
// `currency` parameter, with NO field rename and NO version bump. Integrations
// with hardcoded thresholds were silently off by ~90x overnight. Every
// price-bearing call here pins `currency=840` (USD) explicitly. An unpinned
// `maxPrice` is the sharpest edge: after a redenomination our ceiling becomes
// either absurdly permissive or unfillable, and WRONG_MAX_PRICE gives no hint
// that the UNIT moved rather than the number.

import type { ProviderErrorType } from "./providers.ts";

const API = "https://hero-sms.com/stubs/handler_api.php";

/** Hard per-call timeout. Every adapter in this codebase has one: the ~150s
 *  edge-worker kill budget depends on no single provider call being able to
 *  hang. */
const TIMEOUT_MS = 10_000;

/** ISO-4217 numeric for USD. Pinned on every price-bearing call — see header. */
export const CURRENCY_USD = 840;

function apiKey(): string {
  return Deno.env.get("HEROSMS_API_KEY") ?? "";
}

export type Wire =
  | { kind: "json"; data: Record<string, unknown> }
  | { kind: "text"; text: string }
  | { kind: "blocked"; status: number }
  | { kind: "transport"; error: string };

/** Single entry point. Returns the raw wire form; typed wrappers interpret it.
 *  Deliberately never throws — callers branch on `kind`. */
async function call(
  action: string,
  params: Record<string, string | number> = {},
): Promise<Wire> {
  const q = new URLSearchParams({ api_key: apiKey(), action });
  for (const [k, v] of Object.entries(params)) q.set(k, String(v));

  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(`${API}?${q}`, {
      signal: ctl.signal,
      headers: { accept: "application/json, text/plain, */*" },
    });
    const body = await res.text();
    const trimmed = body.trim();

    // Form 4: an edge block is NOT an API response.
    //
    // Detect on STATUS plus an HTML BODY — deliberately NOT on content-type.
    // HeroSMS serves EVERY response as `content-type: text/html; charset=UTF-8`,
    // including both the JSON of getPrices and the bare text of getBalance.
    // Keying on the header therefore misclassifies every successful call as a
    // block: measured live 2026-07-30, it made getBalanceUsd() return null (so
    // no health row was ever written, and an absent row reads as healthy) and
    // would have failed every order with no_numbers_available.
    if (res.status === 403 || res.status === 429 ||
        trimmed.startsWith("<!DOCTYPE") || trimmed.toLowerCase().startsWith("<html")) {
      return { kind: "blocked", status: res.status };
    }

    if (trimmed.startsWith("{") || trimmed.startsWith("[")) {
      try {
        return { kind: "json", data: JSON.parse(trimmed) as Record<string, unknown> };
      } catch {
        // Malformed JSON is a transport fault, not a business error.
        return { kind: "transport", error: `unparseable_json:${trimmed.slice(0, 80)}` };
      }
    }
    return { kind: "text", text: trimmed };
  } catch (e) {
    return { kind: "transport", error: String(e) };
  } finally {
    clearTimeout(timer);
  }
}

/** Pull the error token out of whichever envelope carried it, or null when the
 *  response is a success.
 *
 *  THREE error shapes exist and a real client in the wild gets this wrong:
 *  the `hero-sms` npm package gates on `'title' in data && 'details' in data`,
 *  so `{"status":"error","error":"NO_ACTIVATIONS"}` fails its error check and
 *  is returned to the caller AS DATA. A reconciler built on that concludes
 *  nothing is stranded when the opposite is true — on exactly the endpoint you
 *  need after a charge/row mismatch. Handle both JSON shapes. */
export function errorTokenOf(w: Wire): string | null {
  if (w.kind === "blocked") return `HTTP_${w.status}_BLOCKED`;
  if (w.kind === "transport") return "TRANSPORT_ERROR";
  if (w.kind === "json") {
    const d = w.data;
    if (typeof d.title === "string" && d.details !== undefined) return d.title;
    if (d.status === "error" && typeof d.error === "string") return d.error;
    return null;
  }
  // Bare text: success sentinels all start with ACCESS_ or STATUS_.
  const t = w.text.toUpperCase();
  if (t.startsWith("ACCESS_") || t.startsWith("STATUS_")) return null;
  return w.text;
}

/** Map a HeroSMS error token onto the router's shared taxonomy.
 *
 *  Unlike SMSPVA — whose vocabulary is undocumented, forcing substring
 *  guessing — handler_api's error set is a fixed enum, so this is an exact
 *  match table. Anything unrecognised is logged and returns undefined rather
 *  than being invented, so the real vocabulary is learned from production.
 *
 *  BANNED carries a suffix ("BANNED:2026-08-01 12:00:00"), so it is matched by
 *  prefix. NO_ACTIVATIONS is matched EXACTLY — never by prefix or startsWith —
 *  because of the one-character collision with NO_ACTIVATION. */
export function classifyHerosmsFault(raw: string): ProviderErrorType | undefined {
  const t = raw.trim().toUpperCase();

  if (t === "NO_NUMBERS" || t === "NO_NUMBER") return "OUT_OF_STOCK";
  if (t === "NO_BALANCE" || t === "LOW_BALANCE") return "BALANCE_ERROR";
  if (t === "BAD_KEY" || t === "ERROR_NO_KEY" || t === "UNAUTHORIZED") return "AUTH_ERROR";
  if (t.startsWith("BANNED")) return "AUTH_ERROR";
  if (t === "WRONG_MAX_PRICE") return "PRICE_NOT_FOUND";
  if (t === "HTTP_403_BLOCKED" || t === "HTTP_429_BLOCKED") return "RATE_LIMITED";
  if (t === "TRANSPORT_ERROR") return "TRANSPORT_ERROR";
  // BAD_ACTION / BAD_SERVICE / WRONG_SERVICE / BAD_STATUS are OUR bug — a
  // malformed request — not a provider outage. Surface as AUTH_ERROR so it
  // pages rather than silently reading as "no numbers here".
  if (t === "BAD_ACTION" || t === "BAD_SERVICE" || t === "WRONG_SERVICE" ||
      t === "BAD_STATUS" || t === "ERROR_SQL") return "AUTH_ERROR";

  console.error(`herosms: unclassified error "${raw}" — add it to classifyHerosmsFault`);
  return undefined;
}

// ── Reads ───────────────────────────────────────────────────────────────────

/** Balance in USD, or null when unreadable.
 *  Wire form: bare text `ACCESS_BALANCE:10.91`. */
export async function getBalanceUsd(): Promise<number | null> {
  const w = await call("getBalance", { currency: CURRENCY_USD });
  if (w.kind !== "text") return null;
  const m = w.text.match(/^ACCESS_BALANCE:([\d.]+)$/i);
  if (!m) return null;
  const n = Number(m[1]);
  return Number.isFinite(n) ? n : null;
}

export interface HeroPrice {
  /** Wholesale cost in USD. */
  cost: number;
  /** Total numbers available on this route. */
  count: number;
  /** Numbers backed by a PHYSICAL SIM rather than VoIP.
   *
   *  The most valuable field this provider exposes and the reason for the
   *  migration. Confirmed 6/6 against HeroSMS's own web UI: every country it
   *  labels "Only virtual" returns physicalCount 0. Meta's properties reject
   *  VoIP ranges — they are ~53% of our order volume at ~12% delivery — and on
   *  SMSPVA we could only INFER VoIP by regex-matching operator names against
   *  /^(Donor|Other_|MVNO_|Total_)/. This turns that guess into a number we can
   *  read before selling the route. */
  physicalCount: number;
}

/** Prices for one service across every country, keyed by numeric country id.
 *  Wire form: JSON, `{"48":{"wa":{cost,count,physicalCount}}}`. */
export async function getPricesForService(
  service: string,
): Promise<Record<string, HeroPrice>> {
  const w = await call("getPrices", { service, currency: CURRENCY_USD });
  if (w.kind !== "json") return {};
  const out: Record<string, HeroPrice> = {};
  for (const [countryId, byService] of Object.entries(w.data)) {
    const row = (byService as Record<string, unknown>)?.[service] as
      | Record<string, unknown>
      | undefined;
    if (!row) continue;
    const cost = Number(row.cost);
    if (!Number.isFinite(cost)) continue;
    out[countryId] = {
      cost,
      count: Number(row.count) || 0,
      physicalCount: Number(row.physicalCount) || 0,
    };
  }
  return out;
}

/** Wholesale price for one (country, service), or null. */
export async function getPrice(
  country: string | number,
  service: string,
): Promise<number | null> {
  const w = await call("getPrices", { service, country, currency: CURRENCY_USD });
  if (w.kind !== "json") return null;
  const row = (w.data[String(country)] as Record<string, unknown> | undefined)?.[service] as
    | Record<string, unknown>
    | undefined;
  const cost = Number(row?.cost);
  return Number.isFinite(cost) ? cost : null;
}

// ── Order lifecycle ─────────────────────────────────────────────────────────

export interface HeroBuyResult {
  ok: boolean;
  orderId?: string;
  /** Full E.164 WITH a leading "+". See the normalisation note below. */
  phoneNumber?: string;
  costUsd?: number;
  /** Provider's own hold deadline, epoch seconds, when it reports one. */
  expiresAt?: number;
  error?: string;
  errorType?: ProviderErrorType;
}

/** Reserve a number.
 *
 *  Prefers `getNumberV2`, which returns JSON carrying `activationCost` and
 *  `activationEndTime` — so cost attribution and expiry are READ rather than
 *  inferred. SMSPVA gives neither, forcing a getBalance-bracket for cost and a
 *  hardcoded window for expiry; both are guesses this provider makes
 *  unnecessary. Falls back to the v1 text form if V2 is unavailable.
 *
 *  NUMBER FORMAT: handler_api returns full international digits WITHOUT a
 *  leading "+". It is normalised to "+<digits>" here. Do NOT prepend the
 *  country dial code the way the SMSPVA branch does — SMSPVA returns a
 *  NATIONAL number, this returns international, and prepending would produce a
 *  doubled country code. */
export async function buyNumber(
  country: string | number,
  service: string,
  operator?: string | null,
  maxPriceUsd?: number,
): Promise<HeroBuyResult> {
  const params: Record<string, string | number> = {
    service,
    country,
    currency: CURRENCY_USD,
  };
  if (operator) params.operator = operator;
  if (maxPriceUsd != null && Number.isFinite(maxPriceUsd)) {
    params.maxPrice = Number(maxPriceUsd.toFixed(4));
  }

  const v2 = await call("getNumberV2", params);
  const v2err = errorTokenOf(v2);

  if (v2.kind === "json" && !v2err) {
    const d = v2.data;
    const id = d.activationId ?? d.id;
    const phone = d.phoneNumber ?? d.phone;
    if (id != null && phone != null) {
      const cost = Number(d.activationCost);
      const endsAt = typeof d.activationEndTime === "string"
        ? Math.floor(Date.parse(d.activationEndTime.replace(" ", "T") + "Z") / 1000)
        : undefined;
      return {
        ok: true,
        orderId: String(id),
        phoneNumber: normalizeE164(String(phone)),
        costUsd: Number.isFinite(cost) ? cost : undefined,
        expiresAt: Number.isFinite(endsAt as number) ? endsAt : undefined,
      };
    }
  }

  // BAD_ACTION means this deployment has no V2 — fall back rather than fail.
  if (v2err && v2err.toUpperCase() !== "BAD_ACTION") {
    return { ok: false, error: v2err, errorType: classifyHerosmsFault(v2err) };
  }

  const v1 = await call("getNumber", params);
  const v1err = errorTokenOf(v1);
  if (v1err) return { ok: false, error: v1err, errorType: classifyHerosmsFault(v1err) };
  if (v1.kind !== "text") {
    return { ok: false, error: "unexpected_getnumber_shape", errorType: "TRANSPORT_ERROR" };
  }
  // ACCESS_NUMBER:<id>:<phone>
  const parts = v1.text.split(":");
  if (parts.length < 3) {
    return { ok: false, error: `malformed:${v1.text.slice(0, 60)}`, errorType: "TRANSPORT_ERROR" };
  }
  return { ok: true, orderId: parts[1], phoneNumber: normalizeE164(parts[2]) };
}

function normalizeE164(raw: string): string {
  const digits = raw.replace(/[^\d]/g, "");
  return digits ? `+${digits}` : "";
}

export interface HeroStatus {
  state: "waiting" | "received" | "canceled" | "expired" | "unknown";
  code?: string;
  fullText?: string;
}

/** Poll one activation.
 *  Wire form: bare text — STATUS_WAIT_CODE / STATUS_OK:<code> / STATUS_CANCEL. */
export async function getStatus(orderId: string): Promise<HeroStatus> {
  const w = await call("getStatus", { id: orderId });
  const err = errorTokenOf(w);
  if (err) {
    // A blocked/throttled poll is NOT "the order vanished" — report unknown so
    // the caller keeps the order alive and retries next tick.
    console.error(`herosms getStatus ${orderId}: ${err}`);
    return { state: "unknown" };
  }
  if (w.kind !== "text") return { state: "unknown" };
  const t = w.text;
  const up = t.toUpperCase();
  if (up.startsWith("STATUS_OK")) {
    const code = t.slice(t.indexOf(":") + 1).trim();
    return { state: "received", code, fullText: code };
  }
  if (up === "STATUS_WAIT_CODE" || up === "STATUS_WAIT_RETRY") return { state: "waiting" };
  if (up === "STATUS_CANCEL") return { state: "canceled" };
  return { state: "unknown" };
}

/** setStatus codes. 8 = cancel (refunds the reservation), 6 = finish/complete
 *  (marks the activation used — the markSuccess analogue), 3 = request another
 *  code on the SAME number (free), 1 = number ready / SMS sent. */
export const STATUS_READY = 1;
export const STATUS_RETRY = 3;
export const STATUS_FINISH = 6;
export const STATUS_CANCEL = 8;

async function setStatus(orderId: string, status: number): Promise<{ ok: boolean; error?: string }> {
  const w = await call("setStatus", { id: orderId, status });
  const err = errorTokenOf(w);
  if (err) return { ok: false, error: err };
  return { ok: true };
}

/** Mark an activation COMPLETE. Analogous to SMSPVA's blocknumber-on-success:
 *  hygiene that tells the provider the number did its job. Best-effort. */
export async function finish(orderId: string): Promise<{ ok: boolean; error?: string }> {
  return await setStatus(orderId, STATUS_FINISH);
}

/** Cancel an activation and reclaim the wholesale.
 *
 *  handler_api historically refuses a cancel inside the first ~2 minutes with
 *  EARLY_CANCEL_DENIED. That interacts with our own 180s minimum hold: by the
 *  time a user can cancel, the provider will accept it. But the EXPIRY sweep
 *  can fire earlier on a short window, so the caller must treat
 *  EARLY_CANCEL_DENIED as retryable rather than terminal. */
export async function cancel(orderId: string): Promise<{ ok: boolean; error?: string }> {
  return await setStatus(orderId, STATUS_CANCEL);
}

/** Ask for a second code on the SAME number. Free, unlike the billed
 *  getExtraActivation. Not wired into the order flow yet — exposed so the
 *  retry path can use it instead of burning a new reservation. */
export async function requestAnotherCode(orderId: string): Promise<{ ok: boolean; error?: string }> {
  return await setStatus(orderId, STATUS_RETRY);
}

/** Open activations, for reconciling charge-vs-row drift.
 *
 *  Returns an EMPTY LIST for NO_ACTIVATIONS in either JSON envelope — see the
 *  note on `errorTokenOf`. Returns null when the answer is genuinely unknown
 *  (blocked, transport), so a caller can tell "nothing stranded" apart from
 *  "could not check". */
export async function activeActivations(): Promise<Record<string, unknown>[] | null> {
  const w = await call("getActiveActivations");
  const err = errorTokenOf(w);
  if (err) {
    if (err.trim().toUpperCase() === "NO_ACTIVATIONS") return [];
    return null;
  }
  if (w.kind !== "json") return null;
  const d = w.data;
  // The vendor's changelog shows `activeActivations`; their own npm client
  // declares `data`. Accept both rather than betting on one.
  const list = (d.activeActivations ?? d.data) as unknown;
  return Array.isArray(list) ? list as Record<string, unknown>[] : [];
}
