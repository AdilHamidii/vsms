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

/** The BUY call gets longer. It is the slowest endpoint in this protocol and
 *  the vendor's own SDK defaults to 30s; at 10s a slow-but-successful
 *  allocation aborts client-side while the provider has already reserved and
 *  BILLED the number, leaving a paid orphan we cannot see. Reads keep the
 *  tighter budget so the per-minute poller stays inside its worker limit. */
const BUY_TIMEOUT_MS = 30_000;

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
  timeoutMs: number = TIMEOUT_MS,
): Promise<Wire> {
  const q = new URLSearchParams({ api_key: apiKey(), action });
  for (const [k, v] of Object.entries(params)) q.set(k, String(v));

  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), timeoutMs);
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
    // Third shape, observed live on getPrices with a bad country:
    // {"status":"false","msg":"country is incorrect"} at HTTP 200. Without
    // this arm it reads as SUCCESS, which is how a failed getNumberV2 could
    // fall through and trigger a SECOND purchase on the v1 path.
    if ((d.status === "false" || d.status === false) && typeof d.msg === "string") {
      return d.msg;
    }
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

  // Suffixed codes MUST be matched by prefix. `WRONG_MAX_PRICE:0.35` carries
  // the minimum acceptable price and `BANNED:<date>` the ban expiry, so an
  // exact match silently misses both. That mattered: WRONG_MAX_PRICE is OUR
  // margin ceiling refusing the buy, and unclassified it reached the user as
  // "no numbers available — try another country", sending them country-shopping
  // over a price problem.
  if (t.startsWith("WRONG_MAX_PRICE")) return "PRICE_NOT_FOUND";
  if (t.startsWith("BANNED")) return "AUTH_ERROR";

  switch (t) {
    // ── Genuinely no stock on this route ─────────────────────────────────
    case "NO_NUMBERS":
    case "SERVICE_NOT_AVAILABLE":
    case "SIM_OFFLINE":
    case "OPERATORS_NOT_FOUND":
      return "OUT_OF_STOCK";

    case "NO_BALANCE":
      return "BALANCE_ERROR";

    // ── Concurrency cap, NOT a stockout ──────────────────────────────────
    // "Account channels limit reached" — the provider's cap on simultaneous
    // activations, carrying {current_threads, max_allowed}. It arrives exactly
    // when we are busiest, and as OUT_OF_STOCK it would tell every user at peak
    // to go try another country.
    case "CHANNELS_LIMIT":
      return "RATE_LIMITED";

    // ── Account / credentials — these must PAGE ──────────────────────────
    // create-order only escalates on BALANCE_ERROR and AUTH_ERROR, so anything
    // that means "the account cannot buy" belongs here or it fails silently
    // forever. NO_KEY is what an unset HEROSMS_API_KEY produces.
    case "BAD_KEY":
    case "NO_KEY":
    case "ACCOUNT_INACTIVE":
      return "AUTH_ERROR";

    // ── OUR malformed request. Also AUTH_ERROR so it pages: a request bug
    // that reads as "no numbers" is indistinguishable from genuine scarcity.
    case "BAD_ACTION":
    case "BAD_SERVICE":
    case "WRONG_SERVICE":
    case "BAD_STATUS":
    case "BAD_DURATION":
    case "WRONG_COUNTRY":
    case "WRONG_CURRENCY":
    case "WRONG_ACTIVATION_ID":
    case "UNPROCESSABLE_ENTITY":
      return "AUTH_ERROR";

    // ── Provider-side transient ──────────────────────────────────────────
    case "SERVER_ERROR":
    case "ERROR_SQL":
    case "PARSE_ERROR":
    case "TRANSPORT_ERROR":
      return "TRANSPORT_ERROR";

    // ── Our own transport sentinels ──────────────────────────────────────
    case "HTTP_403_BLOCKED":
    case "HTTP_429_BLOCKED":
      return "RATE_LIMITED";
  }

  console.error(`herosms: unclassified error "${raw}" — add it to classifyHerosmsFault`);
  return undefined;
}

/** Cancel/release faults that mean "this activation is already finished" —
 *  treat as success, since the goal (stop holding the number) is achieved.
 *  NOT_FOUND is included: a bogus/expired id 404s, and retrying cannot help. */
export function isCancelAlreadyDone(raw: string): boolean {
  const t = raw.trim().toUpperCase();
  return t === "FINISHED" || t === "CANCELED" || t === "REFUNDED" ||
         t === "ACTIVATION_NOT_ACTIVE" || t === "NOT_FOUND" ||
         t === "NO_ACTIVATION" || t === "WRONG_ACTIVATION_ID" ||
         t === "FREE_CANCELLATION_EXPIRED";
}

/** Cancel faults worth retrying LATER rather than dropping.
 *
 *  handler_api refuses a cancel inside the first ~2 minutes
 *  (EARLY_CANCEL_DENIED). Every release() call site fires within that window —
 *  the over-ceiling release and the order_persist_failed release both run
 *  milliseconds after the buy — so without a retry the wholesale is forfeited
 *  and the number stays reserved against the concurrency cap.
 *
 *  OTP_RECEIVED / NEW_OTP_RECEIVED are also retryable-ish, but they mean a code
 *  ARRIVED: cancelling would throw away a delivered SMS, so callers should
 *  fetch it rather than retry the cancel. */
export function isCancelRetryable(raw: string): boolean {
  const t = raw.trim().toUpperCase();
  return t === "EARLY_CANCEL_DENIED" || t === "SERVER_ERROR" ||
         t === "TRANSPORT_ERROR" || t.startsWith("HTTP_");
}

/** The provider says a code arrived — do NOT cancel, fetch it instead. */
export function isCodeArrived(raw: string): boolean {
  const t = raw.trim().toUpperCase();
  return t === "OTP_RECEIVED" || t === "NEW_OTP_RECEIVED";
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
/** Per-service availability for one country, optionally restricted to a single
 *  operator. `{ heroServiceCode: count }`.
 *
 *  This is the ONLY way to see stock for a specific operator: `getPrices`
 *  accepts an `operator` param and silently ignores it, returning the whole
 *  pool either way (probed 2026-07-31). A service ABSENT from the result has no
 *  numbers on that operator at all — which is different from a zero, and is how
 *  badoo/us was found to have no physical SIMs while reporting
 *  physicalCount 3,829 for the country.
 *
 *  Returns null on any failure, so callers can tell "no stock" from "we could
 *  not ask" — hiding a catalog on a failed fetch is the mistake this codebase
 *  has already made once. */
/** Operator names offered for a country. Needs NO api key.
 *
 *  Used to derive real-carrier candidates per country instead of hand-writing a
 *  list for each of the 69 we sell in. Returns [] on failure, which callers must
 *  treat as "could not ask", never as "this country has no carriers". */
export async function getOperators(country: string | number): Promise<string[]> {
  const r = await call("getOperators", { country });
  if (r.kind !== "json" || errorTokenOf(r)) return [];
  const d = (r.data as { countryOperators?: Record<string, string[]> }).countryOperators;
  if (!d) return [];
  const all: string[] = [];
  for (const list of Object.values(d)) if (Array.isArray(list)) all.push(...list);
  return all;
}

export async function getNumbersStatus(
  country: string | number,
  operator?: string | null,
): Promise<Record<string, number> | null> {
  const params: Record<string, string | number> = { country };
  if (operator) params.operator = operator;
  const r = await call("getNumbersStatus", params);
  if (r.kind !== "json" || errorTokenOf(r)) return null;
  const out: Record<string, number> = {};
  for (const [k, v] of Object.entries(r.data as Record<string, unknown>)) {
    const n = Number(v);
    if (Number.isFinite(n)) out[k] = n;
  }
  return out;
}

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

  const v2 = await call("getNumberV2", params, BUY_TIMEOUT_MS);
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

  // Fall back to v1 ONLY on BAD_ACTION (this deployment has no V2).
  //
  // Deliberately a POSITIVE gate. It used to be `if (v2err && !== BAD_ACTION)
  // return error`, so any V2 response that was neither a recognised success
  // NOR a recognised error token fell through to a SECOND getNumber call — a
  // second purchase. Real shapes hit that hole: `{"status":"false","msg":...}`
  // at HTTP 200 (now handled in errorTokenOf), and any text-form V2 reply.
  // With ORDER_ALREADY_EXISTS the duplicate would likely be refused, so the
  // user gets refunded while the FIRST number stays bought and orphaned.
  if (v2err?.toUpperCase() !== "BAD_ACTION") {
    return {
      ok: false,
      error: v2err ?? "unexpected_getnumberv2_shape",
      errorType: classifyHerosmsFault(v2err ?? "PARSE_ERROR"),
    };
  }

  const v1 = await call("getNumber", params, BUY_TIMEOUT_MS);
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
    // Guard the colon: `indexOf` returns -1 on a bare "STATUS_OK", and
    // slice(-1 + 1) = slice(0) would hand the user the literal string
    // "STATUS_OK" as their verification code.
    const i = t.indexOf(":");
    if (i < 0) return { state: "waiting" };
    const code = t.slice(i + 1).trim();
    return code ? { state: "received", code, fullText: code } : { state: "waiting" };
  }
  // Prefix, not equality: STATUS_WAIT_RETRY always carries a ":<lastcode>"
  // suffix, so `=== "STATUS_WAIT_RETRY"` could never match. STATUS_WAIT_RESEND
  // exists too. All three mean the same thing to us — keep waiting.
  if (up.startsWith("STATUS_WAIT")) return { state: "waiting" };
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
  // `data` FIRST. The live response is
  //   {"status":"success","data":[],"activeActivations":{...,"rows":[]}}
  // — `activeActivations` is an OBJECT, so `activeActivations ?? data` never
  // evaluates the right-hand side, Array.isArray fails, and this returned []
  // unconditionally. "Nothing is stranded" was hardcoded, on the one endpoint
  // that exists to find stranded reservations.
  if (Array.isArray(d.data)) return d.data as Record<string, unknown>[];
  const nested = (d.activeActivations as { rows?: unknown } | undefined)?.rows;
  return Array.isArray(nested) ? nested as Record<string, unknown>[] : [];
}
