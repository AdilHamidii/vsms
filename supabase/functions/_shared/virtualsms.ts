// VirtualSMS (virtualsms.io / api.virtualsms.de) adapter — the SMS-Activate
// "handler_api" protocol: a single endpoint, `action` + params in the query
// string, `api_key` for auth. Real physical SIMs (non-reused) → far higher
// acceptance on WhatsApp/Google than VoIP pools; exposes per-service success
// rate via getListOfTopCountriesByService, which we use to curate the catalog.
//
// Mirrors the shape of smspva.ts so create/check/cancel-order can swap providers
// with minimal change. NOTE: response field names for the V2 JSON endpoints are
// best-effort from the public docs and MUST be verified against a live key
// before cutover (search for VERIFY: below).

const BASE = "https://api.virtualsms.de/stubs/handler_api";

function apiKey(): string {
  const k = Deno.env.get("VIRTUALSMS_API_KEY");
  if (!k) throw new Error("VIRTUALSMS_API_KEY env var not set");
  return k;
}

/** Low-level call. handler_api returns either a plain-text envelope
 *  ("ACCESS_NUMBER:123:1555…", "STATUS_OK:9134") or JSON for the *V2 actions. */
async function call(action: string, params: Record<string, string> = {}): Promise<string> {
  const qs = new URLSearchParams({ api_key: apiKey(), action, ...params });
  const resp = await fetch(`${BASE}?${qs.toString()}`, { method: "GET" });
  return (await resp.text()).trim();
}

async function callJson<T>(action: string, params: Record<string, string> = {}): Promise<T> {
  const text = await call(action, params);
  try {
    return JSON.parse(text) as T;
  } catch {
    // A text error envelope where JSON was expected (e.g. NO_BALANCE, BAD_KEY).
    throw new Error(`virtualsms ${action} returned non-JSON: ${text.slice(0, 120)}`);
  }
}

// ─────────── Ordering ───────────

export interface GetNumberResult {
  ok: boolean;
  activationId?: string;
  phoneNumber?: string;      // full number incl. country code
  costUsd?: number;
  error?: string;            // handler_api sentinel, e.g. NO_NUMBERS, NO_BALANCE
}

/** Reserve a one-time number for (service, country). service/country are the
 *  provider's own identifiers (service short code e.g. "wa"; numeric country id).
 *  getNumberV2 returns JSON: VERIFY exact keys against a live response. */
export async function getNumber(service: string, country: string): Promise<GetNumberResult> {
  const text = await call("getNumberV2", { service, country });
  // Text sentinel path (NO_NUMBERS / NO_BALANCE / BAD_SERVICE / etc.)
  if (!text.startsWith("{")) return { ok: false, error: text };
  try {
    const d = JSON.parse(text) as {
      activationId?: number | string;
      phoneNumber?: string;      // VERIFY: may be "phone" or "number"
      activationCost?: number | string;
    };
    return {
      ok: true,
      activationId: d.activationId !== undefined ? String(d.activationId) : undefined,
      phoneNumber: d.phoneNumber,
      costUsd: d.activationCost !== undefined ? Number(d.activationCost) : undefined,
    };
  } catch {
    return { ok: false, error: text.slice(0, 120) };
  }
}

export interface SmsStatus {
  state: "waiting" | "received" | "canceled" | "unknown";
  code?: string;       // parsed OTP
  fullText?: string;   // full SMS body if available
}

/** Poll an activation. getStatusV2 returns JSON with the SMS payload;
 *  the text getStatus returns STATUS_WAIT_CODE / STATUS_OK:{code}. */
export async function getStatus(activationId: string): Promise<SmsStatus> {
  const text = await call("getStatusV2", { id: activationId });
  if (text.startsWith("{")) {
    // VERIFY: doc shows sms payload; exact keys (sms/verificationCode/text) TBD.
    const d = JSON.parse(text) as {
      sms?: { code?: string; text?: string } | { code?: string; text?: string }[];
      verificationCode?: string;
    };
    const sms = Array.isArray(d.sms) ? d.sms[0] : d.sms;
    const code = sms?.code ?? d.verificationCode;
    if (code) return { state: "received", code, fullText: sms?.text };
    return { state: "waiting" };
  }
  // Text envelope.
  if (text.startsWith("STATUS_OK")) {
    const code = text.split(":")[1];
    return { state: "received", code };
  }
  if (text === "STATUS_WAIT_CODE" || text === "STATUS_WAIT_RETRY") return { state: "waiting" };
  if (text === "STATUS_CANCEL") return { state: "canceled" };
  return { state: "unknown" };
}

/** setStatus status codes (SMS-Activate standard): 8 = cancel(+refund),
 *  6 = finish/complete, 3 = request another SMS. */
export function cancelOrder(activationId: string): Promise<string> {
  return call("setStatus", { id: activationId, status: "8" });
}
export function finishOrder(activationId: string): Promise<string> {
  return call("setStatus", { id: activationId, status: "6" });
}

// ─────────── Catalog / pricing / metrics (for sync-prices) ───────────

/** getPrices → nested { country: { service: { cost, count } } }. Used to rebuild
 *  routes. VERIFY nesting/keys against live output. */
export function getPrices(): Promise<Record<string, Record<string, { cost: number; count: number }>>> {
  return callJson("getPrices");
}

export function getCountries(): Promise<unknown> {
  return callJson("getCountries");
}

export function getServicesList(country?: string): Promise<unknown> {
  return callJson("getServicesList", country ? { country } : {});
}

/** getListOfTopCountriesByService → success-rate metrics per service, used to
 *  hide/rank routes by real delivery rate. Returns NO_METRICS when sparse. */
export function getTopCountriesByService(service: string): Promise<unknown> {
  return callJson("getListOfTopCountriesByService", { service });
}

export function getBalance(): Promise<string> {
  return call("getBalance"); // "ACCESS_BALANCE:12.34"
}
