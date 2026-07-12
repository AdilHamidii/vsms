// VirtualSMS (virtualsms.io) adapter — modern REST API.
//   Base: https://virtualsms.io/api/v1
//   Auth: X-API-Key: vsms_...   (NOT Bearer, NOT the api.virtualsms.de handler_api)
// Real physical SIMs (aggregated, e.g. herosms) → higher WhatsApp/Google
// acceptance than VoIP pools, but LIMITED live stock (tens of numbers, ~8
// countries in stock at a time). So we treat it as the primary provider where
// it has stock and fall back to SMSPVA for coverage (see create-order).
//
// Shapes verified against the live API + docs. Balance/prices are USD.

const BASE = "https://virtualsms.io/api/v1";

function key(): string {
  const k = Deno.env.get("VIRTUALSMS_API_KEY");
  if (!k) throw new Error("VIRTUALSMS_API_KEY env var not set");
  return k;
}

async function req<T>(method: "GET" | "POST", path: string, body?: unknown): Promise<T> {
  const resp = await fetch(`${BASE}${path}`, {
    method,
    headers: {
      "X-API-Key": key(),
      "Accept": "application/json",
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  const text = await resp.text();
  let json: unknown;
  try { json = JSON.parse(text); } catch { json = { success: false, error: text.slice(0, 160) }; }
  return json as T;
}

// ─────────── Ordering ───────────

export interface BuyResult {
  ok: boolean;
  orderId?: string;      // UUID
  phoneNumber?: string;  // full number incl. country code
  costUsd?: number;
  expiresAt?: string;
  error?: string;
}

/** POST /customer/purchase — rent a number. service/country are VirtualSMS
 *  codes: service short code ("wa","tg","ig") + 2-letter ISO country ("FR"). */
export async function buyNumber(service: string, country: string): Promise<BuyResult> {
  const d = await req<{
    success: boolean; order_id?: string; phone_number?: string;
    price?: number; expires_at?: string; error?: string;
  }>("POST", "/customer/purchase", { service, country });
  if (!d.success) return { ok: false, error: d.error ?? "purchase_failed" };
  return {
    ok: true,
    orderId: d.order_id,
    phoneNumber: d.phone_number,
    costUsd: typeof d.price === "number" ? d.price : undefined,
    expiresAt: d.expires_at,
  };
}

export interface OrderStatus {
  state: "waiting" | "received" | "canceled" | "expired" | "unknown";
  code?: string;      // extracted OTP digits
  fullText?: string;  // raw SMS body
}

const STATE_MAP: Record<string, OrderStatus["state"]> = {
  waiting: "waiting", completed: "received", cancelled: "canceled",
  canceled: "canceled", expired: "expired",
};

/** GET /customer/order/{id} — poll for the SMS. The code lives in
 *  messages[].content (full text); we extract the numeric OTP. */
export async function getOrder(orderId: string): Promise<OrderStatus> {
  const d = await req<{
    success: boolean; status?: string; sms_received?: boolean;
    messages?: { sender?: string; content?: string; received_at?: string }[];
  }>("GET", `/customer/order/${encodeURIComponent(orderId)}`);
  const state = STATE_MAP[d.status ?? ""] ?? "unknown";
  const msg = d.messages?.[0];
  if (msg?.content) {
    return { state: "received", code: extractCode(msg.content), fullText: msg.content };
  }
  return { state };
}

/** POST /customer/cancel/{id} — full refund while waiting. Blocked in the
 *  first 2 minutes (HTTP 425). Returns refund_amount on success. */
export async function cancelOrder(orderId: string): Promise<{ ok: boolean; refundUsd?: number; error?: string }> {
  const d = await req<{ success: boolean; refund_amount?: number; error?: string; seconds_remaining?: number }>(
    "POST", `/customer/cancel/${encodeURIComponent(orderId)}`,
  );
  if (!d.success) return { ok: false, error: d.error ?? "cancel_failed" };
  return { ok: true, refundUsd: d.refund_amount };
}

/** POST /customer/swap/{id} — replace a non-delivering number with a fresh one
 *  for the same service/country at no extra charge (2-min hold applies). Better
 *  than cancel when the combo is fine but the specific SIM went bad. */
export async function swapNumber(orderId: string): Promise<{ ok: boolean; newOrderId?: string; phoneNumber?: string; error?: string }> {
  const d = await req<{ success: boolean; order_id?: string; phone_number?: string; error?: string }>(
    "POST", `/customer/swap/${encodeURIComponent(orderId)}`,
  );
  if (!d.success) return { ok: false, error: d.error ?? "swap_failed" };
  return { ok: true, newOrderId: d.order_id, phoneNumber: d.phone_number };
}

/** Pull the OTP out of a full SMS body ("Your code is 12345" → "12345"). */
export function extractCode(text: string): string {
  const m = text.match(/(\d[\d\s-]{3,7}\d)/);
  return m ? m[1].replace(/[\s-]/g, "") : text.trim();
}

// ─────────── Catalog / pricing / stock (for sync) ───────────

export interface VsService { id: string; name: string; category?: string; price?: number; timeout_seconds?: number }
export interface VsCountry { id: string; name?: string; code?: string; total_phones?: number; available_phones?: number; price?: number }

/** GET /services — curated service list with floor prices. */
export async function listServices(): Promise<VsService[]> {
  const d = await req<{ services?: VsService[] }>("GET", "/services");
  return d.services ?? [];
}

/** GET /countries?service=X — countries with LIVE stock for a service. This is
 *  the authoritative availability source (we build routes only from these). */
export async function listCountriesForService(service: string): Promise<VsCountry[]> {
  const d = await req<{ countries?: VsCountry[] }>("GET", `/countries?service=${encodeURIComponent(service)}`);
  return d.countries ?? [];
}

/** GET /price — public, no auth. Exact price + availability for one combo. */
export async function price(service: string, country: string): Promise<{ ok: boolean; priceUsd?: number; available?: boolean }> {
  const resp = await fetch(`${BASE}/price?service=${encodeURIComponent(service)}&country=${encodeURIComponent(country)}`);
  const d = await resp.json().catch(() => ({ success: false })) as { success?: boolean; price?: number; available?: boolean };
  if (!d.success) return { ok: false };
  return { ok: true, priceUsd: d.price, available: d.available };
}

export async function getBalanceUsd(): Promise<number | null> {
  const d = await req<{ success: boolean; balance?: number }>("GET", "/customer/balance");
  return d.success && typeof d.balance === "number" ? d.balance : null;
}
