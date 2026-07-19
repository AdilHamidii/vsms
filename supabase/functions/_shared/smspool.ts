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

async function form<T>(path: string, params: Record<string, string | number> = {}): Promise<T> {
  const body = new URLSearchParams({ key: key(), ...toStr(params) });
  const resp = await fetch(`${BASE}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json" },
    body,
  });
  return parse<T>(await resp.text());
}

async function get<T>(path: string, params: Record<string, string | number> = {}): Promise<T> {
  const qs = new URLSearchParams({ key: key(), ...toStr(params) }).toString();
  const resp = await fetch(`${BASE}${path}?${qs}`, { headers: { Accept: "application/json" } });
  return parse<T>(await resp.text());
}

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
  error?: string;
}

/** POST /purchase/sms — rent a number. country/service are numeric SMSPool ids.
 *  maxPriceUsd caps the fill price: the /request/price quote is per cheapest
 *  POOL, but an uncapped purchase can fill from a pricier pool (seen live:
 *  6¢ quote filled at $0.79). */
export async function purchase(
  country: string | number, service: string | number, maxPriceUsd?: number,
): Promise<BuyResult> {
  const params: Record<string, string | number> = { country, service };
  if (maxPriceUsd != null && Number.isFinite(maxPriceUsd)) {
    params.max_price = maxPriceUsd.toFixed(2);
  }
  const d = await form<{
    success?: number; order_id?: string; number?: string | number; phonenumber?: string | number;
    cost?: string; cost_in_cents?: number; message?: string;
  }>("/purchase/sms", params);
  if (!d || d.success !== 1) return { ok: false, error: d?.message ?? "purchase_failed" };
  const raw = String(d.number ?? d.phonenumber ?? "");
  const num = raw ? (raw.startsWith("+") ? raw : `+${raw}`) : "";
  const usd = typeof d.cost_in_cents === "number" ? d.cost_in_cents / 100
    : (d.cost ? parseFloat(d.cost) : undefined);
  return { ok: true, orderId: d.order_id, phoneNumber: num, costUsd: usd };
}

export interface OrderStatus {
  state: "waiting" | "received" | "canceled" | "expired" | "unknown";
  code?: string;
  fullText?: string;
}

/** GET /sms/check — poll for the code. status 3 => received. */
export async function check(orderId: string): Promise<OrderStatus> {
  const d = await get<{
    status?: number; sms?: string; full_sms?: string; code?: string; full_code?: string;
  }>("/sms/check", { orderid: orderId });
  const code = d.sms ?? d.code;
  const full = d.full_sms ?? d.full_code;
  if (d.status === 3 || (code && code !== "0" && code !== "")) {
    return { state: "received", code: extractCode(code ?? full ?? ""), fullText: full ?? undefined };
  }
  if (d.status === 6) return { state: "canceled" };
  return { state: "waiting" };
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

/** POST /request/pricing — the full in-stock price matrix in one call (no success_rate). */
export function getPricingBulk(): Promise<PricingRow[]> {
  return form<PricingRow[]>("/request/pricing");
}

/** GET /service/retrieve_all — {ID, name}. No auth needed but key is harmless. */
export function listServices(): Promise<{ ID: number; name: string }[]> {
  return get<{ ID: number; name: string }[]>("/service/retrieve_all");
}

/** GET /country/retrieve_all — {ID, name, short_name, cc}. */
export function listCountries(): Promise<{ ID: number; name: string; short_name: string; cc?: string }[]> {
  return get("/country/retrieve_all");
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
