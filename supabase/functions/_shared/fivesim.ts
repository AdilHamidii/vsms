// 5sim.net adapter — REST, Bearer auth, plain-text errors.
//
// Probed live 2026-08-03 (real purchase + cancel on usa/virtual51/aol, $0.0081,
// fully refunded). Four things here cost real money if you get them wrong.
//
// 1. ⚠️ `status: "RECEIVED"` DOES NOT MEAN A CODE ARRIVED.
//    Our freshly-bought order came back `{"status":"RECEIVED","sms":[]}` and the
//    docs' own example shows `{"status":"RECEIVED","sms":[{...,"code":"09363"}]}`
//    — the SAME status with and without a code. Their vocabulary is
//    PENDING (preparing) / RECEIVED (waiting for SMS) / CANCELED / TIMEOUT /
//    FINISHED / BANNED, so "RECEIVED" means the NUMBER was received, not the
//    message. `sms[].code` is the ONLY authority. This is the eSIM status-literal
//    bug wearing a friendlier word: encoding a guess about a vendor's vocabulary
//    is the most expensive recurring mistake in this codebase.
//
// 2. ⚠️ A STOCKOUT RETURNS HTTP 200, and so does a BAD COUNTRY.
//    `buy/activation/notacountry/any/facebook` → 200 `no free phones`, byte for
//    byte what a genuine stockout returns. So a MAPPING DEFECT is invisible
//    behind a stockout unless the caller already knows the codes were valid.
//    sync-5sim counts unmapped and out-of-stock separately for this reason.
//
// 3. Errors are PLAIN TEXT, never JSON, and the status code alone is not enough
//    (200 can be a failure, 400 covers six unrelated causes). Classify on the
//    body.
//
// 4. There is NO maxPrice parameter. HeroSMS enforces our cap provider-side; 5sim
//    cannot. The buy response does carry `price`, so create-order's post-fill
//    `actual_cost_over_ceiling` release is the ONLY price guard on this provider
//    — which is why its pre-flight bound must be the tight `maxCostUsd`, not the
//    loose MAX_REVENUE_FRACTION one that is only safe for a capped provider.

import type { ProviderErrorType } from "./providers.ts";

const BASE = "https://5sim.net/v1";
// Reads are cheap and retried by the caller; the BUY is not — an aborted-but-
// successful allocation is a paid orphan, so it gets the long timeout.
const TIMEOUT_MS = 10_000;
const BUY_TIMEOUT_MS = 30_000;

function token(): string | null {
  return Deno.env.get("FIVESIM_API_KEY") ?? null;
}

type Wire =
  | { kind: "json"; status: number; data: unknown }
  | { kind: "text"; status: number; text: string }
  | { kind: "transport"; detail: string };

/** Single entry point. NEVER throws — every fault becomes a Wire. */
async function call(path: string, timeoutMs = TIMEOUT_MS, auth = true): Promise<Wire> {
  const key = token();
  if (auth && !key) return { kind: "text", status: 401, text: "NO_KEY" };
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const res = await fetch(`${BASE}/${path}`, {
      headers: {
        Accept: "application/json",
        ...(auth && key ? { Authorization: `Bearer ${key}` } : {}),
      },
      signal: ctl.signal,
    });
    const body = await res.text();
    // Errors are plain text; successes are JSON. Try JSON, fall back to text —
    // and keep the status either way, because 200 + "no free phones" is a real
    // and common failure.
    try {
      return { kind: "json", status: res.status, data: JSON.parse(body) };
    } catch {
      return { kind: "text", status: res.status, text: body.trim().slice(0, 200) };
    }
  } catch (e) {
    // Abort, DNS, TLS, socket. MUST NOT be classified as a stockout — see
    // classifyFivesimFault.
    return { kind: "transport", detail: String(e).slice(0, 160) };
  } finally {
    clearTimeout(timer);
  }
}

/** Map 5sim's plain-text faults onto the router's taxonomy.
 *
 *  Returning `undefined` is DANGEROUS: providers.ts treats
 *  `undefined || OUT_OF_STOCK` as "the pinned pool is dry, retry unpinned", so an
 *  unclassified TRANSPORT failure on a call that already allocated a number buys
 *  a SECOND one. That exact bug shipped on the SMSPVA path. Transport faults are
 *  therefore classified FIRST and never fall through.
 *
 *  Full documented vocabulary (5sim docs, buy/activation):
 *    200  no free phones
 *    400  not enough user balance | not enough rating | select country |
 *         select operator | bad country | bad operator | no product | server offline
 *    500  internal error
 */
export function classifyFivesimFault(status: number, raw: string): ProviderErrorType | undefined {
  const t = (raw ?? "").toLowerCase().trim();

  if (t === "transport_error") return "TRANSPORT_ERROR";
  if (status === 0) return "TRANSPORT_ERROR";

  // Genuine scarcity. The ONLY thing that may map here — see the header note
  // about a bad country returning this same string.
  if (t.includes("no free phones")) return "OUT_OF_STOCK";

  // Money. Pages the owner via create-order's alertProviderFault.
  if (t.includes("not enough user balance")) return "BALANCE_ERROR";

  // Account-level restriction: 5sim lowers `rating` for abusive cancel patterns
  // and blocks buying below a floor. It is not scarcity and must not read as it.
  if (t.includes("not enough rating")) return "AUTH_ERROR";

  if (status === 401 || status === 403 || t === "no_key" || t.includes("unauthorized")) {
    return "AUTH_ERROR";
  }
  if (status === 429 || t.includes("rate limit")) return "RATE_LIMITED";

  // Malformed request. Deliberately AUTH_ERROR, matching herosms.ts: these mean
  // OUR mapping or code is wrong, and they must page rather than tell the user
  // to "try another country" — a mapping regression that reads as a stockout is
  // invisible for days.
  if (
    t.includes("no product") || t.includes("bad country") || t.includes("bad operator") ||
    t.includes("select country") || t.includes("select operator")
  ) {
    return "AUTH_ERROR";
  }

  if (t.includes("server offline") || t.includes("internal error") || status >= 500) {
    return "TRANSPORT_ERROR";
  }

  console.error(`5sim: unclassified error status=${status} body=${raw?.slice(0, 120)}`);
  return undefined;
}

function faultOf(w: Wire): { error: string; errorType?: ProviderErrorType } {
  if (w.kind === "transport") {
    return { error: `TRANSPORT_ERROR: ${w.detail}`, errorType: "TRANSPORT_ERROR" };
  }
  const raw = w.kind === "text" ? w.text : JSON.stringify(w.data).slice(0, 200);
  return { error: raw, errorType: classifyFivesimFault(w.status, raw) };
}

// ── Balance ─────────────────────────────────────────────────────────────────

export async function getBalanceUsd(): Promise<number | null> {
  const w = await call("user/profile");
  if (w.kind !== "json") return null;
  const b = (w.data as { balance?: unknown }).balance;
  return typeof b === "number" && Number.isFinite(b) ? b : null;
}

// ── Prices (GUEST — no key needed, and none is sent) ─────────────────────────

export interface FivePool {
  cost: number;
  count: number;
  /** 30-day delivery rate. UNDOCUMENTED field — see sync-5sim. */
  rate720?: number;
  [k: string]: unknown;
}
/** country -> product -> operator -> pool */
export type FivePrices = Record<string, Record<string, Record<string, FivePool>>>;

/** One country at a time. The all-countries form is a single 9.1 MB response;
 *  per-country is ~0.1-0.6 MB, which keeps peak memory bounded inside the edge
 *  runtime and lets a partial run still write what it got. */
export async function getPricesForCountry(country: string): Promise<FivePrices | null> {
  const w = await call(`guest/prices?country=${encodeURIComponent(country)}`, TIMEOUT_MS, false);
  if (w.kind !== "json") {
    console.warn(`5sim: prices fetch failed for ${country}:`, faultOf(w).error);
    return null;
  }
  return w.data as FivePrices;
}

// ── Purchase ────────────────────────────────────────────────────────────────

export interface FiveBuyResult {
  ok: boolean;
  orderId?: string;
  phoneNumber?: string;
  costUsd?: number;
  expiresAt?: number; // epoch seconds
  operator?: string;
  error?: string;
  errorType?: ProviderErrorType;
}

/** `operator` may be a concrete pool slug or "any". No price cap exists. */
export async function buyActivation(
  country: string,
  operator: string,
  product: string,
): Promise<FiveBuyResult> {
  const w = await call(
    `user/buy/activation/${encodeURIComponent(country)}/${encodeURIComponent(operator)}/${encodeURIComponent(product)}`,
    BUY_TIMEOUT_MS,
  );
  if (w.kind !== "json") return { ok: false, ...faultOf(w) };

  const d = w.data as Record<string, unknown>;
  const id = d.id;
  const phone = d.phone;
  // Require BOTH before calling it a success. A JSON body we do not recognise
  // must never be read as a fill — that is how the HeroSMS v1 fallback once
  // bought a second number.
  if (id == null || typeof phone !== "string" || !phone) {
    return {
      ok: false,
      error: `unexpected buy shape: ${JSON.stringify(d).slice(0, 160)}`,
      errorType: undefined,
    };
  }
  const price = typeof d.price === "number" ? d.price : undefined;
  const exp = typeof d.expires === "string" ? Math.floor(Date.parse(d.expires) / 1000) : undefined;
  return {
    ok: true,
    orderId: String(id),
    phoneNumber: phone.startsWith("+") ? phone : `+${phone}`,
    costUsd: price,
    expiresAt: Number.isFinite(exp) ? exp : undefined,
    operator: typeof d.operator === "string" ? d.operator : undefined,
  };
}

// ── Status ──────────────────────────────────────────────────────────────────

export interface FiveStatus {
  state: "waiting" | "received" | "canceled" | "expired" | "unknown";
  code?: string;
  fullText?: string;
}

/** THE CODE COMES FROM `sms[]`, NEVER FROM `status`. See the header. */
export async function getStatus(orderId: string): Promise<FiveStatus> {
  const w = await call(`user/check/${encodeURIComponent(orderId)}`);
  if (w.kind !== "json") {
    const f = faultOf(w);
    // "order not found" is terminal; anything else means we could not ask, and
    // `unknown` keeps the order alive rather than inventing a terminal state.
    if (f.error.toLowerCase().includes("order not found")) return { state: "expired" };
    console.error(`5sim: status read failed order=${orderId}: ${f.error}`);
    return { state: "unknown" };
  }
  const d = w.data as { status?: unknown; sms?: unknown };

  // Code first, status second — deliberately. A terminal status can arrive in
  // the same payload as a delivered code (FINISHED with sms populated), and
  // throwing the code away to honour the status would lose a paid delivery.
  const sms = Array.isArray(d.sms) ? d.sms as Record<string, unknown>[] : [];
  for (let i = sms.length - 1; i >= 0; i--) {
    const c = sms[i]?.code;
    if (typeof c === "string" && c.trim()) {
      return {
        state: "received",
        code: c.trim(),
        fullText: typeof sms[i]?.text === "string" ? sms[i].text as string : undefined,
      };
    }
  }

  switch (String(d.status ?? "").toUpperCase()) {
    // Both mean "no SMS yet". RECEIVED is 5sim's word for "number received".
    case "PENDING":
    case "RECEIVED":
      return { state: "waiting" };
    case "CANCELED":
      return { state: "canceled" };
    case "TIMEOUT":
    case "FINISHED":
    case "BANNED":
      return { state: "expired" };
    default:
      console.error(`5sim: unknown order status ${String(d.status)} order=${orderId}`);
      return { state: "unknown" };
  }
}

// ── Lifecycle. All best-effort; callers swallow. ────────────────────────────

async function lifecycle(verb: string, orderId: string): Promise<{ ok: boolean; error?: string }> {
  const w = await call(`user/${verb}/${encodeURIComponent(orderId)}`);
  if (w.kind === "json") return { ok: true };
  const f = faultOf(w);
  // Already terminal — treat as done, not as a failure to retry forever.
  const t = f.error.toLowerCase();
  if (t.includes("order not found") || t.includes("order expired")) return { ok: true };
  return { ok: false, error: f.error };
}

/** Mark the activation complete. Call ONLY after a code arrived. */
export const finish = (orderId: string) => lifecycle("finish", orderId);

/** Release the number and refund the wholesale. */
export const cancel = (orderId: string) => lifecycle("cancel", orderId);

/** Ban the number so 5sim does not re-issue it. Refuses with `order has sms`
 *  once a code landed, which is correct and is treated as success. */
export const ban = (orderId: string) => lifecycle("ban", orderId);
