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
  let resp: Response;
  try {
    if (method === "POST") {
      resp = await fetch(`${BASE}${path}`, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json" },
        body: new URLSearchParams({ key: key(), ...toStr(params) }),
      });
    } else {
      const qs = new URLSearchParams({ key: key(), ...toStr(params) }).toString();
      resp = await fetch(`${BASE}${path}?${qs}`, { headers: { Accept: "application/json" } });
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

export interface BuyResult {
  ok: boolean;
  orderId?: string;      // SMSPool order_code
  phoneNumber?: string;  // full number incl. country code, "+" prefixed
  costUsd?: number;      // what SMSPool actually charged
  /** Absolute epoch seconds when SMSPool releases the number. Their window is
   *  pool-dependent (docs show 1200s; Foxtrot US runs days) — honour it instead
   *  of assuming, or we abandon a number we already paid for. */
  expiresAt?: number;
  /** Pool (supplier) that actually filled. Recorded so pool strategy can be
   *  validated against OUR outcomes, not just SMSPool's self-report. */
  pool?: string;
  error?: string;
  errorType?: SmspoolErrorType;
}

/** POST /purchase/sms — rent a number. country/service are numeric SMSPool ids.
 *  maxPriceUsd caps the fill price: the /request/price quote is per cheapest
 *  POOL, but an uncapped purchase can fill from a pricier pool (seen live:
 *  6¢ quote filled at $0.79).
 *
 *  `pricing_option: 1` is SMSPool's documented "highest success rate" selector
 *  (0 = cheapest). We ask for quality and let max_price hold the margin line.
 *
 *  We deliberately do NOT pin `pool`. That was our own inference that priciest
 *  pool = best quality; SMSPool's FAQ says to leave pool on auto because it
 *  "automatically picks the best one for you", and our order data disagrees
 *  with the inference anyway (successful fills averaged 13.9¢, failures 42¢ —
 *  expensive fills correlate with FAILURE). The param is still accepted for
 *  a deliberate override. */
export async function purchase(
  country: string | number, service: string | number, maxPriceUsd?: number,
  pool?: string | number,
): Promise<BuyResult> {
  const params: Record<string, string | number> = { country, service, pricing_option: 1 };
  if (maxPriceUsd != null && Number.isFinite(maxPriceUsd)) {
    params.max_price = maxPriceUsd.toFixed(2);
  }
  if (pool != null && pool !== "") params.pool = pool;
  const d = await form<{
    success?: number; order_id?: string; number?: string | number; phonenumber?: string | number;
    cc?: string; cost?: string; cost_in_cents?: number; message?: string;
    expires_in?: number; expiration?: number; pool?: number | string;
  }>("/purchase/sms", params);

  const fault = faultOf(d);
  if (fault) return { ok: false, error: fault.message, errorType: fault.type };
  if (!d || d.success !== 1) return { ok: false, error: d?.message ?? "purchase_failed" };

  // `number` is full E.164 digits; `phonenumber` is only the NATIONAL part with
  // `cc` split out, so falling back to it would build a wrong number (a US
  // "234567890" would become +234567890 — Nigeria). Rebuild from cc if needed.
  const num = d.number != null && String(d.number) !== ""
    ? `+${String(d.number).replace(/^\+/, "")}`
    : (d.phonenumber != null && d.cc ? `+${d.cc}${d.phonenumber}` : "");

  const usd = typeof d.cost_in_cents === "number" ? d.cost_in_cents / 100
    : (d.cost ? parseFloat(d.cost) : undefined);
  const expiresAt = typeof d.expiration === "number" ? d.expiration
    : (typeof d.expires_in === "number" ? Math.floor(Date.now() / 1000) + d.expires_in : undefined);

  return {
    ok: true, orderId: d.order_id, phoneNumber: num, costUsd: usd, expiresAt,
    pool: d.pool != null ? String(d.pool) : undefined,
  };
}

export interface OrderStatus {
  state: "waiting" | "activating" | "received" | "canceled" | "expired" | "unknown";
  code?: string;
  fullText?: string;
}

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

/** GET /sms/check — poll for the code. */
export async function check(orderId: string): Promise<OrderStatus> {
  const d = await get<{
    status?: number; sms?: string; full_sms?: string; code?: string; full_code?: string;
  }>("/sms/check", { orderid: orderId });
  // A fault must never read as "waiting" — a 429 used to be indistinguishable
  // from "no code yet", so throttling quietly ran orders to expiry.
  const fault = faultOf(d);
  if (fault) return { state: "unknown" };

  const code = d.sms ?? d.code;
  const full = d.full_sms ?? d.full_code;
  if (d.status === SP_STATUS.COMPLETED || (code && code !== "0" && code !== "")) {
    return { state: "received", code: extractCode(code ?? full ?? ""), fullText: full ?? undefined };
  }
  switch (d.status) {
    case SP_STATUS.EXPIRED:    return { state: "expired" };
    case SP_STATUS.CANCELLED:
    case SP_STATUS.REFUNDED:   return { state: "canceled" };
    case SP_STATUS.ACTIVATING: return { state: "activating" };
    default:                   return { state: "waiting" };  // 1 pending, 4 resend, 7 processing
  }
}

/** Block until the number leaves "activating". Returns true when it's safe to
 *  hand to the user, false if it never became ready.
 *
 *  SMSPool documents this as "usually takes around a minute", so a short budget
 *  defeats the purpose — the caller would reveal exactly the dead number the
 *  gate exists to withhold. 45s keeps create-order inside Deno's request
 *  budget while covering the documented window. */
export async function waitUntilReady(
  orderId: string, maxMs = 45_000, stepMs = 3_000,
): Promise<boolean> {
  const deadline = Date.now() + maxMs;
  for (;;) {
    const s = await check(orderId).catch(() => null);
    if (!s) return false;                       // API trouble: don't claim ready
    if (s.state !== "activating") return true;
    if (Date.now() + stepMs >= deadline) return false;
    await new Promise((r) => setTimeout(r, stepMs));
  }
}

/** POST /sms/cancel — best-effort. Blocked for the first ~2 min; no-code numbers
 *  auto-refund on expiry regardless. */
export async function cancel(orderId: string): Promise<{ ok: boolean; error?: string }> {
  const d = await form<{ success?: number; message?: string }>("/sms/cancel", { orderid: orderId });
  if (d?.success !== 1) return { ok: false, error: d?.message ?? "cancel_failed" };
  return { ok: true };
}

/** Pull the OTP digits out of a code/body ("Your code is 12345" -> "12345"). */
export function extractCode(text: string): string {
  const m = text.match(/(\d[\d\s-]{3,7}\d)/);
  return m ? m[1].replace(/[\s-]/g, "") : text.trim();
}

// ─────────── Pricing / catalog (for sync) ───────────

/** POST /request/price — exact price + self-reported success_rate for one combo. */
export async function getPrice(country: string | number, service: string | number):
  Promise<{ ok: boolean; priceUsd?: number; highUsd?: number; successRate?: number }> {
  const d = await form<{ price?: string; high_price?: string; success_rate?: number; success?: number }>(
    "/request/price", { country, service },
  );
  const price = d.price != null ? parseFloat(d.price) : NaN;
  if (!Number.isFinite(price)) return { ok: false };
  return {
    ok: true,
    priceUsd: price,
    highUsd: d.high_price != null ? parseFloat(d.high_price) : undefined,
    successRate: typeof d.success_rate === "number" ? d.success_rate : undefined,
  };
}

export interface PricingRow {
  service: number; service_name: string;
  country: number; country_name: string; short_name: string;
  price: string; pool?: number;
}

/** POST /request/pricing — the in-stock price matrix in one call (no success_rate).
 *  `max_price` is a documented server-side filter. Unfiltered this returns
 *  ~120k rows / ~15MB, parsed whole in an edge function every hour — and we
 *  discard everything above the wholesale ceiling anyway, so filtering at the
 *  source is free payload (and headroom against the memory limit). */
export function getPricingBulk(maxPriceUsd?: number): Promise<PricingRow[]> {
  const p: Record<string, string | number> = {};
  if (maxPriceUsd != null && Number.isFinite(maxPriceUsd)) p.max_price = maxPriceUsd.toFixed(2);
  return form<PricingRow[]>("/request/pricing", p);
}

/** Array endpoints must never hand back a fault object — callers iterate the
 *  result, so a 403/429 used to throw a TypeError that aborted the whole sync
 *  with an opaque 500. Empty array lets the caller's own floors decide. */
function asArray<T>(v: unknown): T[] { return Array.isArray(v) ? v as T[] : []; }

/** GET /service/retrieve_all — {ID, name}. No auth needed but key is harmless. */
export async function listServices(): Promise<{ ID: number; name: string }[]> {
  return asArray(await get<unknown>("/service/retrieve_all"));
}

/** GET /country/retrieve_all — {ID, name, short_name, cc, region}. */
export async function listCountries():
  Promise<{ ID: number; name: string; short_name: string; cc?: string; region?: string }[]> {
  return asArray(await get<unknown>("/country/retrieve_all"));
}

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
  Promise<{ ok: boolean; transactionId?: string; error?: string }> {
  const d = await form<{ success?: number; transactionId?: string; message?: string }>(
    "/esim/purchase", { plan: planId },
  );
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

/** POST /sms/all_stock — stock + price + pool + last_update for every
 *  (country, service, pool) in one call. Optional filters narrow it.
 *  Strict superset of /request/pricing: same price matrix, plus the inventory
 *  count that tells us whether a route can actually be filled. */
export interface StockRow {
  country: number; country_name: string;
  service: number; service_name: string;
  pool: number; pool_name: string;
  stock: number; price: string; last_update?: string;
}
export async function allStock(
  filter: { country?: string | number; service?: string | number; pool?: string | number } = {},
): Promise<StockRow[]> {
  const p: Record<string, string | number> = {};
  if (filter.country != null) p.country = filter.country;
  if (filter.service != null) p.service = filter.service;
  if (filter.pool != null) p.pool = filter.pool;
  const d = await form<unknown>("/sms/all_stock", p);
  if (!Array.isArray(d)) return [];
  // SMSPool returns this one double-nested ([[row, ...]]), unlike every other
  // list endpoint. Flatten one level so callers see a plain row array.
  return (d.length && Array.isArray(d[0]) ? (d as unknown[][]).flat() : d) as StockRow[];
}

/** POST /pool/retrieve_valid — pools that can serve this combo, with price and
 *  a custom_area capability flag. */
export interface ValidPool { pool: number; name: string; custom_area?: number; price?: string }

/** The live response is an OBJECT keyed by pool id — {"3":"Charlie","7":"Foxtrot"}
 *  — not the array of {pool,name,custom_area,price} the Postman docs show.
 *  Verified against the live API 2026-07-21. Handle both. */
export async function validPools(service: string | number, country: string | number): Promise<ValidPool[]> {
  const d = await form<unknown>("/pool/retrieve_valid", { service, country });
  if (faultOf(d)) return [];
  if (Array.isArray(d)) return d as ValidPool[];
  if (d && typeof d === "object") {
    return Object.entries(d as Record<string, unknown>)
      .filter(([k]) => /^\d+$/.test(k))
      .map(([k, v]) => ({ pool: Number(k), name: String(v) }));
  }
  return [];
}

/** POST /request/price with an explicit pool — the ONLY endpoint that returns a
 *  per-pool success_rate. SMSPool support defines it as "the overall successful
 *  verifications compared to the unsuccessful verifications for the last 500
 *  records", i.e. a real trailing outcome ratio.
 *
 *  Two values are NOT measurements and must be discarded:
 *    100 — means zero measured pools, not perfect (facebook/ch reported 100 on
 *          both its pools while we went 0-for-9 on it)
 *     30 — a hard floor the API emits for low/no sample
 *  Only 31..99 carries information. */
export async function poolSuccessRate(
  country: string | number, service: string | number, pool: string | number,
): Promise<{ rate: number | null; priceUsd: number | null }> {
  const d = await form<{ price?: string; success_rate?: number }>(
    "/request/price", { country, service, pool },
  );
  if (faultOf(d)) return { rate: null, priceUsd: null };
  const sr = typeof d.success_rate === "number" ? d.success_rate : null;
  const price = d.price != null ? parseFloat(d.price) : NaN;
  return {
    rate: sr != null && sr > 30 && sr < 100 ? sr : null,
    priceUsd: Number.isFinite(price) ? price : null,
  };
}
