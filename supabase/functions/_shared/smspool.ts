// SMSPool adapter (smspool.net) — the primary provider.
//   Base: https://api.smspool.net
//   Auth: the API key travels as a form param `key` (NOT a header).
// Country/service identifiers are NUMERIC ids (from /country|service/retrieve_all).
// Numbers come back fully-formed (with country code), like virtualsms.
//
// Shapes confirmed against the live API 2026-07-18. status_id: 1=pending,
// 3=received (code populated), 6=refunded/cancelled.

const BASE = "https://api.smspool.net";

function key(): string {
  const k = Deno.env.get("SMSPOOL_API_KEY");
  if (!k) throw new Error("SMSPOOL_API_KEY env var not set");
  return k;
}

/** SMSPool's documented failure `type`s, plus our own for transport problems.
 *  Previously every non-200 was parsed as if it were a success body, which
 *  made three very different problems indistinguishable:
 *    - 429 rate-limit → parsed to {} → check() read status as undefined and
 *      reported "waiting", so throttling looked exactly like "no code yet"
 *      and the order silently expired.
 *    - 403 bad key → purchase() reported a generic "purchase_failed".
 *    - 400/403 on list endpoints → returned an object where callers expected
 *      an array, throwing a TypeError that aborted the whole sync. */
export type SmspoolErrorType =
  | "OUT_OF_STOCK" | "PRICE_NOT_FOUND" | "BALANCE_ERROR"
  | "RATE_LIMITED" | "AUTH_ERROR" | "TRANSPORT_ERROR";

export interface SmspoolFault {
  ok: false;
  type: SmspoolErrorType;
  status: number;
  message: string;
  /** Per-pool breakdown SMSPool returns on OUT_OF_STOCK — which supplier ran dry. */
  pools?: Record<string, unknown>;
}

/** Non-null when the payload is a documented error rather than a result. */
export function faultOf(v: unknown): SmspoolFault | null {
  return v && typeof v === "object" && (v as SmspoolFault).ok === false &&
         "type" in (v as object) ? v as SmspoolFault : null;
}

function classify(status: number, body: unknown, raw: string): SmspoolFault | null {
  if (status === 429) {
    return { ok: false, type: "RATE_LIMITED", status, message: "rate limited" };
  }
  if (status === 401 || status === 403) {
    return { ok: false, type: "AUTH_ERROR", status, message: "invalid api key" };
  }
  const b = (body ?? {}) as Record<string, unknown>;
  const declared = typeof b.type === "string" ? b.type : null;
  if (declared === "OUT_OF_STOCK" || declared === "PRICE_NOT_FOUND" || declared === "BALANCE_ERROR") {
    return {
      ok: false, type: declared, status,
      // SMSPool wraps these in HTML; strip tags so nothing markup-y can reach a user.
      message: String(b.message ?? "").replace(/<[^>]*>/g, "").trim() || declared,
      pools: b.pools as Record<string, unknown> | undefined,
    };
  }
  if (status >= 400) {
    return {
      ok: false, type: "TRANSPORT_ERROR", status,
      message: String(b.message ?? raw.slice(0, 160)).replace(/<[^>]*>/g, "").trim(),
    };
  }
  return null;
}

async function request<T>(
  path: string, params: Record<string, string | number>, method: "POST" | "GET",
): Promise<T> {
  // Hard per-call timeout: a hung connection must fast-fail, not stall the
  // caller (create-esim-order, the eSIM syncs) up to the 150s worker kill.
  const signal = AbortSignal.timeout(10000);
  let resp: Response;
  try {
    if (method === "POST") {
      resp = await fetch(`${BASE}${path}`, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json" },
        body: new URLSearchParams({ key: key(), ...toStr(params) }),
        signal,
      });
    } else {
      const qs = new URLSearchParams({ key: key(), ...toStr(params) }).toString();
      resp = await fetch(`${BASE}${path}?${qs}`, { headers: { Accept: "application/json" }, signal });
    }
  } catch (e) {
    return { ok: false, type: "TRANSPORT_ERROR", status: 0, message: String(e) } as unknown as T;
  }
  const raw = await resp.text();
  const body = parse<unknown>(raw);
  const fault = classify(resp.status, body, raw);
  return (fault ?? body) as T;
}

const form = <T>(path: string, params: Record<string, string | number> = {}) =>
  request<T>(path, params, "POST");
const get = <T>(path: string, params: Record<string, string | number> = {}) =>
  request<T>(path, params, "GET");

function toStr(p: Record<string, string | number>): Record<string, string> {
  const o: Record<string, string> = {};
  for (const [k, v] of Object.entries(p)) o[k] = String(v);
  return o;
}
function parse<T>(text: string): T {
  try { return JSON.parse(text) as T; }
  catch { return { success: 0, error: text.slice(0, 160) } as unknown as T; }
}

// ─────────── Ordering ───────────


/** SMSPool documents EIGHT status codes; we previously handled only 3 and 6 and
 *  mapped everything else to "waiting" — so expired/cancelled orders polled
 *  until our own timeout, and status 8 was invisible.
 *
 *  8 = "activating" matters most: SMSPool's FAQ states that all modem ports are
 *  busy and "if you send the code while it's still activating, it will not be
 *  received." A number surfaced during status 8 is a guaranteed dead order, so
 *  callers must hold it back until it reaches pending. */
const SP_STATUS = {
  PENDING: 1, EXPIRED: 2, COMPLETED: 3, RESEND: 4,
  CANCELLED: 5, REFUNDED: 6, PROCESSING: 7, ACTIVATING: 8,
} as const;


// ─────────── Pricing / catalog (for sync) ───────────


/** Array endpoints must never hand back a fault object — callers iterate the
 *  result, so a 403/429 used to throw a TypeError that aborted the whole sync
 *  with an opaque 500. Empty array lets the caller's own floors decide. */
function asArray<T>(v: unknown): T[] { return Array.isArray(v) ? v as T[] : []; }


export async function getBalanceUsd(): Promise<number | null> {
  const d = await form<{ balance?: string }>("/request/balance");
  const b = d.balance != null ? parseFloat(d.balance) : NaN;
  return Number.isFinite(b) ? b : null;
}

// ─────────── eSIM (data plans) ───────────
// Confirmed live 2026-07-18. Catalog is per-country (/esim/plans?country=CC);
// purchase returns only a transactionId; the QR/activation + usage come from
// /esim/profile.

export interface EsimPlanRow {
  ID: number;
  dataInGb: number;
  duration: number;      // validity days
  price: string;         // wholesale USD
  speed: string;         // "3G/4G/5G"
  network?: string;      // JSON string of countries+operators
  extendable?: number;
}

/** GET/POST /esim/plans — all data-plan tiers for a 2-letter country code. */
export function esimPlans(countryCode: string): Promise<EsimPlanRow[]> {
  return form<EsimPlanRow[]>("/esim/plans", { country: countryCode });
}

/** POST /esim/purchase — buy a plan by its numeric id. Returns a transactionId
 *  only; the profile (QR/activation) is fetched separately. */
export async function esimPurchase(planId: string | number):
  Promise<{ ok: boolean; transactionId?: string; error?: string; errorType?: SmspoolErrorType }> {
  const d = await form<{ success?: number; transactionId?: string; message?: string }>(
    "/esim/purchase", { plan: planId },
  );
  // Surface the classified fault instead of discarding it. `request()` already
  // builds a SmspoolFault; this function used to throw it away and return only
  // SMSPool's prose, so create-esim-order's `buy.errorType` was always
  // undefined and OUT_OF_STOCK, AUTH_ERROR and BALANCE_ERROR all collapsed into
  // one opaque code — the exact failure the provider_unreachable rename fixed
  // for SMS. It matters most when SMSPool runs dry: every eSIM purchase then
  // fails as "something went wrong on our side" and nothing pages.
  const fault = faultOf(d);
  if (fault) return { ok: false, error: fault.message, errorType: fault.type };
  if (d?.success !== 1 || !d.transactionId) return { ok: false, error: d?.message ?? "esim_purchase_failed" };
  return { ok: true, transactionId: d.transactionId };
}

export interface EsimProfile {
  ok: boolean;
  activationCode?: string;   // full LPA string "LPA:1$smdp$token"
  smdp?: string;
  matchingId?: string;       // the token
  apn?: string;
  /** iOS prompts for this when the line activates; without it the eSIM cannot
   *  come up at all, which reads to the user as "the internet doesn't work". */
  pin?: string;
  puk?: string;
  activated?: boolean;
  dataTotalMb?: number;
  dataUsedMb?: number;
  extendable?: boolean;
  error?: string;
}

/** POST /esim/profile — the delivery payload (LPA/QR + SM-DP+) AND live usage
 *  (remainingData/totalData) for a purchased eSIM, keyed by transactionId. */
export async function esimProfile(transactionId: string): Promise<EsimProfile> {
  const d = await form<{
    success?: number; ac?: string; smdp?: string; activationCode?: string; apn?: string;
    activated?: number; topup?: number; remainingData?: string; totalData?: string;
    pin?: string; puk?: string;
  }>("/esim/profile", { transactionId });
  if (d?.success !== 1) return { ok: false, error: "esim_profile_failed" };
  const total = parseDataMb(d.totalData);
  const remaining = parseDataMb(d.remainingData);
  return {
    ok: true,
    activationCode: d.ac,
    smdp: d.smdp,
    matchingId: d.activationCode,   // SMSPool names the token "activationCode"
    apn: d.apn,
    pin: d.pin ?? undefined,
    puk: d.puk ?? undefined,
    activated: d.activated === 1,
    dataTotalMb: total,
    dataUsedMb: total != null && remaining != null ? Math.max(0, total - remaining) : undefined,
    extendable: d.topup === 1,
  };
}

/** POST /esim/history — list purchased eSIMs (summary). */
export function esimHistory(): Promise<{ data?: unknown[] }> {
  return form("/esim/history");
}

/** "500 MB" / "1.5 GB" -> MB int. */
function parseDataMb(s?: string): number | undefined {
  if (!s) return undefined;
  const m = s.match(/([\d.]+)\s*(MB|GB|KB)?/i);
  if (!m) return undefined;
  const n = parseFloat(m[1]);
  const unit = (m[2] ?? "MB").toUpperCase();
  if (unit === "GB") return Math.round(n * 1000);
  if (unit === "KB") return Math.round(n / 1000);
  return Math.round(n);
}

