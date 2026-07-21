// SMSPVA v2 REST API wrapper (https://docs.smspva.com).
//
// All requests authenticate via the `apikey` header.
// All responses use a uniform envelope:
//   success: { statusCode: 200, data: ... }
//   error:   { statusCode: 4xx|5xx, error: { type, description } }

// NB: docs.smspva.com lists `https://smspva.com` as the server, but that's
// the marketing site (returns 404 HTML for /activation/*). The actual API
// is on the `api.` subdomain. Discovered by probing directly.
const BASE = "https://api.smspva.com";

function apiKey(): string {
  const k = Deno.env.get("SMSPVA_API_KEY");
  if (!k) throw new Error("SMSPVA_API_KEY env var not set");
  return k;
}

export interface SmsPvaError {
  statusCode: number;
  error: { type: string; description: string };
}
export interface SmsPvaSuccess<T> {
  statusCode: number;
  data: T;
}
export type SmsPvaResponse<T> = SmsPvaSuccess<T> | SmsPvaError;

export function isOk<T>(r: SmsPvaResponse<T>): r is SmsPvaSuccess<T> {
  return r.statusCode === 200 && "data" in r && (r as SmsPvaSuccess<T>).data !== undefined;
}

async function call<T>(method: "GET" | "PUT", path: string): Promise<SmsPvaResponse<T>> {
  const resp = await fetch(`${BASE}${path}`, {
    method,
    headers: {
      apikey: apiKey(),
      Accept: "application/json",
    },
  });
  const text = await resp.text();
  try {
    return JSON.parse(text) as SmsPvaResponse<T>;
  } catch {
    // SMSPVA occasionally returns non-JSON on infrastructure errors.
    return {
      statusCode: resp.status,
      error: { type: "UPSTREAM_NON_JSON", description: text.slice(0, 200) },
    };
  }
}

// ─────────── Endpoints ───────────

export interface GetNumberData {
  orderId: number;
  phoneNumber: number | string;     // Number WITHOUT country code
  countryCode?: number | string;
}

/** Reserve a new activation number for (country, service).
 *  `operator` pins a specific pool (optional third path segment) — real
 *  carriers like "Vodafone_UK" vs anonymized donor pools ("DonorAlpha_UK").
 *  Omitted = SMSPVA picks randomly and "the price will depend on it". */
export function getNumber(country: string, service: string, operator?: string) {
  const base = `/activation/number/${encodeURIComponent(country)}/${encodeURIComponent(service)}`;
  return call<GetNumberData>("GET", operator ? `${base}/${encodeURIComponent(operator)}` : base);
}

export interface GetSmsData {
  orderId: number;
  orderExpireIn?: number;
  sms?: {
    code: string;         // Just the OTP digits
    fullText: string;     // Full SMS body
  };
}

/** Poll for the SMS code on an existing order. data.sms is absent while waiting. */
export function getSms(orderId: string | number) {
  return call<GetSmsData>("GET", `/activation/sms/${encodeURIComponent(String(orderId))}`);
}

/** Cancel + refund a waiting order. */
export function cancelOrder(orderId: string | number) {
  return call<{ orderId: number }>("PUT", `/activation/cancelorder/${encodeURIComponent(String(orderId))}`);
}

/** Mark a received number as "used" (signals SMSPVA the activation succeeded). */
export function blockNumber(orderId: string | number) {
  return call<{ orderId: number }>("PUT", `/activation/blocknumber/${encodeURIComponent(String(orderId))}`);
}

/** Ask SMSPVA to re-send the SMS (after the first arrived). */
export function clearSms(orderId: string | number) {
  return call<{ orderId: number }>("PUT", `/activation/clearsms/${encodeURIComponent(String(orderId))}`);
}

/** Per-route price lookup. */
export function getServicePrice(country: string, service: string) {
  return call<{ price: number; country: string; service: string }>(
    "GET",
    `/activation/serviceprice/${encodeURIComponent(country)}/${encodeURIComponent(service)}`,
  );
}

export interface BulkPriceRow {
  service: string;            // e.g. "opt29"
  serviceDescription: string; // e.g. "Telegram"
  country: string;            // e.g. "US"
  price: number;
}

/** Bulk price + service-name discovery. Use this to learn the actual SMSPVA
 *  service codes / countries available on your account. */
export function getAllPrices() {
  return call<BulkPriceRow[][]>("GET", "/activation/servicesprices");
}

/** Per-country price list (short-key format). */
export interface CountryPriceRow {
  s: string;        // service code, e.g. "opt0"
  sd: string;       // service description
  c: string;        // country code
  p: string;        // base price as string, e.g. "0.58"
  po?: Record<string, string>; // optional operator -> price map
}

export function getCountryPrices(country: string) {
  return call<CountryPriceRow[]>(
    "GET",
    `/activation/serviceprice/${encodeURIComponent(country)}`,
  );
}

export function getBalance() {
  return call<{ balance: number }>("GET", "/activation/balance");
}

/** SMSPVA's own per-country conversion quality for a service — a coarse 0-3
 *  score keyed by country code (probed live: instagram ES=3, UK/FR/DE/US=2).
 *  Positive grades seed routes.success_rate via sync-smspva-conversions;
 *  0 is ambiguous (bad OR just unmeasured) and is deliberately ignored. */
export function getConversions(service: string) {
  return call<{ service: string; conversions: Record<string, number> }>(
    "GET",
    `/activation/conversions/${encodeURIComponent(service)}`,
  );
}
