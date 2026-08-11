// eSIM Access (esimaccess.com) adapter — the eSIM provider since 2026-08-10.
//
// Probed live 2026-08-10 against the real account (balance query, package/list,
// location/list). Five behaviours you cannot guess from the docs alone:
//
// 1. ⚠️ EVERY response is HTTP 200, including logical failures. The envelope is
//    `{success, errorCode, errorMsg, obj}` and `success` is the only authority.
//    Branching on HTTP status reads every failure as a success.
//
// 2. ⚠️ errorCode "200010" ("Profile is being downloaded") is NOT an error — it
//    means "still allocating, poll again". Order allocation is ASYNCHRONOUS
//    (docs: up to ~30s). Mapping it to a failure fails every purchase that
//    takes longer than one poll; it gets its own ALLOCATING type and queryEsim
//    translates it to `{ok:true, profile:null}`.
//
// 3. ⚠️ Money is integer TEN-THOUSANDTHS of a USD everywhere (10000 = $1.00) —
//    package price, order amount, balance. Volumes are BYTES. Keep integer
//    math; ÷100 gives exact cents.
//
// 4. ⚠️ ICCIDs ARE REUSED (their docs say so explicitly). `esimTranNo` is the
//    stable per-eSIM key — store and query by it, never by iccid.
//
// 5. There is NO sandbox. The documented test path is order → /esim/cancel,
//    which refunds the wholesale to our balance while the profile is still
//    GOT_RESOURCE + RELEASED (i.e. not yet installed on a device).
//
// Auth is the single `RT-AccessCode` header (verified live — no signature, no
// timestamp; the console's "secret key" is unused by this API version).
// Rate limit: 8 requests/second account-wide. Timestamps in responses use
// `+0000` offsets, not `Z` — Date.parse handles both.

const BASE = "https://api.esimaccess.com/api/v1/open";
const TIMEOUT_MS = 10_000;
// The catalog is a single ~3,000-package response; the order call is the one
// whose abort would strand paid work — both get longer than the default.
const LIST_TIMEOUT_MS = 25_000;
const ORDER_TIMEOUT_MS = 15_000;

function accessCode(): string | null {
  return Deno.env.get("ESIMACCESS_ACCESS_CODE") ?? null;
}

export type EsimaccessErrorType =
  | "OUT_OF_STOCK"      // 200011 — no profiles available for the package
  | "BALANCE_ERROR"     // 200007 — OUR account balance is short (page owner)
  | "PRICE_DRIFT"       // 200005/200006 — our echoed price no longer matches
  | "ALLOCATING"        // 200010 — profile still being prepared; NOT an error
  | "BAD_PACKAGE"       // 310241/310243 — our catalog/mapping is wrong; page,
                        // never read as a stockout (the fivesim bad-country rule)
  | "BUSY"              // 900001/000001 — transient server side, retryable
  | "AUTH_ERROR"
  | "RATE_LIMITED"      // HTTP 429; account-wide 8 rps
  | "TRANSPORT_ERROR";

export interface EaFault {
  ok: false;
  error: string;
  errorType?: EsimaccessErrorType;
}

export function faultOf(v: unknown): EaFault | null {
  return v && typeof v === "object" && (v as { ok?: unknown }).ok === false
    ? v as EaFault
    : null;
}

interface Envelope {
  success?: boolean;
  errorCode?: string | null;
  // Success payloads use errorMsg; some documented failure examples use
  // errorMessage. Read both rather than trusting either.
  errorMsg?: string | null;
  errorMessage?: string | null;
  obj?: unknown;
}

type Wire =
  | { kind: "json"; status: number; data: Envelope }
  | { kind: "text"; status: number; text: string }
  | { kind: "transport"; detail: string };

/** Single entry point. NEVER throws — every fault becomes a Wire. */
async function call(path: string, body: unknown, timeoutMs = TIMEOUT_MS): Promise<Wire> {
  const key = accessCode();
  if (!key) return { kind: "text", status: 401, text: "NO_KEY" };
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const res = await fetch(`${BASE}/${path}`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "RT-AccessCode": key,
      },
      body: JSON.stringify(body ?? {}),
      signal: ctl.signal,
    });
    const text = await res.text();
    try {
      return { kind: "json", status: res.status, data: JSON.parse(text) as Envelope };
    } catch {
      return { kind: "text", status: res.status, text: text.trim().slice(0, 200) };
    }
  } catch (e) {
    // Abort, DNS, TLS, socket. Classified FIRST and never left undefined — an
    // unclassified transport fault being read as scarcity is the exact bug the
    // SMS adapters paid for (see fivesim.ts).
    return { kind: "transport", detail: String(e).slice(0, 160) };
  } finally {
    clearTimeout(timer);
  }
}

function classifyCode(code: string): EsimaccessErrorType | undefined {
  switch (code) {
    case "200010": return "ALLOCATING";
    case "200011": return "OUT_OF_STOCK";
    case "200007": return "BALANCE_ERROR";
    case "200005":
    case "200006": return "PRICE_DRIFT";
    case "310241":
    case "310243": return "BAD_PACKAGE";
    case "900001":
    case "000001": return "BUSY";
    // Malformed request / header / signature families: OUR code or config is
    // wrong. AUTH_ERROR so it pages rather than telling a user to try again.
    case "000101": case "000102": case "000103": case "000104":
    case "000105": case "000106": case "000107": case "101003":
      return "AUTH_ERROR";
    default:
      return undefined;
  }
}

/** Turn a non-success Wire (or envelope) into a fault. */
function toFault(w: Wire): EaFault {
  if (w.kind === "transport") {
    return { ok: false, error: `TRANSPORT_ERROR: ${w.detail}`, errorType: "TRANSPORT_ERROR" };
  }
  if (w.kind === "text") {
    const t = w.text;
    if (t === "NO_KEY") return { ok: false, error: "ESIMACCESS_ACCESS_CODE not set", errorType: "AUTH_ERROR" };
    if (w.status === 429) return { ok: false, error: t || "rate limited", errorType: "RATE_LIMITED" };
    if (w.status === 401 || w.status === 403) return { ok: false, error: t, errorType: "AUTH_ERROR" };
    if (w.status >= 500) return { ok: false, error: t, errorType: "BUSY" };
    return { ok: false, error: `HTTP ${w.status}: ${t}`, errorType: "TRANSPORT_ERROR" };
  }
  // JSON envelope with success !== true.
  const d = w.data;
  const code = String(d.errorCode ?? "");
  const msg = d.errorMsg ?? d.errorMessage ?? "";
  const type = w.status === 429 ? "RATE_LIMITED" : classifyCode(code);
  if (type === undefined) {
    console.error(`esimaccess: unclassified errorCode=${code} msg=${String(msg).slice(0, 120)}`);
  }
  return { ok: false, error: `${code}: ${String(msg).slice(0, 160)}`, errorType: type };
}

/** success===true → obj; anything else → fault. */
function unwrap(w: Wire): { ok: true; obj: unknown } | EaFault {
  if (w.kind !== "json") return toFault(w);
  if (w.data.success !== true) return toFault(w);
  return { ok: true, obj: w.data.obj };
}

// ── Catalog ─────────────────────────────────────────────────────────────────

export interface EaPackage {
  packageCode: string;
  slug: string;
  /** Provider's plan title ("Japan 1GB 7Days") — NEVER store into
   *  esim_plans.name, which the shipped client renders as the DESTINATION. */
  name: string;
  /** Integer ten-thousandths of a USD (7000 = $0.70). Wholesale. */
  price: number;
  currencyCode: string;
  /** Bytes. */
  volume: number;
  duration: number;
  durationUnit: string;
  /** Comma-joined Alpha-2 list, possibly with a trailing comma ("MX,US,CA,").
   *  Single-country packages carry exactly one code. */
  location: string;
  speed: string | null;
  /** 1 = fixed data total (the only kind we sell); 2/3/4 = day-pass variants. */
  dataType: number;
  activeType: number;
  /** 2 or 3 = top-up-able. Docs call it Boolean; the wire carries ints. */
  supportTopUpType: number;
  locationNetworkList?: { locationName?: string }[];
}

export type EaPackagesResult = { ok: true; packages: EaPackage[] } | EaFault;

/** Full catalog with `{}` (one unpaginated response, ~3,000 packages), or a
 *  single package by code for the order-time re-quote. */
export async function listPackages(packageCode?: string): Promise<EaPackagesResult> {
  const w = await call("package/list", packageCode ? { packageCode } : {}, LIST_TIMEOUT_MS);
  const r = unwrap(w);
  if (!r.ok) return r;
  const list = (r.obj as { packageList?: unknown })?.packageList;
  if (!Array.isArray(list)) {
    return { ok: false, error: "package/list: no packageList in response", errorType: "TRANSPORT_ERROR" };
  }
  return { ok: true, packages: list as EaPackage[] };
}

export interface EaLocation {
  code: string;
  name: string;
  /** 1 = single country, 2 = multi-country region ("EU-42", "GL-139"…). */
  type: number;
}

export type EaLocationsResult = { ok: true; locations: EaLocation[] } | EaFault;

export async function listLocations(): Promise<EaLocationsResult> {
  const w = await call("location/list", {});
  const r = unwrap(w);
  if (!r.ok) return r;
  const list = (r.obj as { locationList?: unknown })?.locationList;
  if (!Array.isArray(list)) {
    return { ok: false, error: "location/list: no locationList in response", errorType: "TRANSPORT_ERROR" };
  }
  return { ok: true, locations: list as EaLocation[] };
}

// ── Ordering ────────────────────────────────────────────────────────────────

export type EaOrderResult = { ok: true; orderNo: string } | EaFault;

/** Place an order for ONE profile of `packageCode`.
 *
 *  `transactionId` is the provider-side idempotency key (≤50 chars — our order
 *  UUID fits): a duplicate id is treated as the SAME request, so retrying after
 *  a transport fault can never buy a second profile. That property is why the
 *  caller is allowed exactly one retry — no SMS provider ever offered it.
 *
 *  `priceTenK` (ten-thousandths USD) is echoed for drift protection: if the
 *  live price no longer matches, the order fails 200005/200006 (PRICE_DRIFT)
 *  instead of silently billing more than the catalog said. Always send it.
 *
 *  Allocation is ASYNC — success returns only `orderNo`; the QR/LPA arrives via
 *  queryEsim, typically within ~30s. */
export async function orderEsim(
  transactionId: string,
  packageCode: string,
  priceTenK?: number,
): Promise<EaOrderResult> {
  const w = await call("esim/order", {
    transactionId,
    packageInfoList: [{
      packageCode,
      count: 1,
      ...(priceTenK != null && Number.isFinite(priceTenK) ? { price: Math.round(priceTenK) } : {}),
    }],
  }, ORDER_TIMEOUT_MS);
  const r = unwrap(w);
  if (!r.ok) return r;
  const orderNo = (r.obj as { orderNo?: unknown })?.orderNo;
  if (typeof orderNo !== "string" || !orderNo) {
    // A success we do not recognise must never be read as a fill.
    return { ok: false, error: `unexpected order shape: ${JSON.stringify(r.obj).slice(0, 160)}` };
  }
  return { ok: true, orderNo };
}

// ── Profile query ───────────────────────────────────────────────────────────

export interface EaProfile {
  /** The stable provider key. ICCIDs are reused; this is not. */
  esimTranNo: string;
  iccid: string | null;
  /** Full LPA activation string: `LPA:1$<smdp>$<matchingId>`. */
  ac: string | null;
  /** RELEASED | DOWNLOAD | INSTALLATION | ENABLED | DISABLED | DELETED */
  smdpStatus: string | null;
  /** GOT_RESOURCE | IN_USE | USED_UP | UNUSED_EXPIRED | USED_EXPIRED |
   *  CANCEL | SUSPENDED | REVOKE (webhooks also spell it REVOKED) */
  esimStatus: string | null;
  activateTime: string | null;
  installationTime: string | null;
  expiredTime: string | null;
  /** Bytes. */
  totalVolume: number | null;
  /** Bytes; the provider updates it every 2-3 hours, and their own example
   *  shows usage EXCEEDING totalVolume — clamp, never assume remaining ≥ 0. */
  orderUsage: number | null;
  pin: string | null;
  puk: string | null;
  apn: string | null;
}

export type EaQueryResult =
  | { ok: true; profile: EaProfile | null }  // null = still allocating
  | EaFault;

/** Fetch the allocated profile by orderNo (ours carry count 1) or esimTranNo.
 *  `pager` is MANDATORY on this endpoint. `profile: null` covers both the
 *  explicit 200010 ALLOCATING code and a success with an empty esimList —
 *  both mean "not ready yet, keep polling", not failure. */
export async function queryEsim(
  key: { orderNo: string } | { esimTranNo: string },
): Promise<EaQueryResult> {
  const w = await call("esim/query", { ...key, pager: { pageNum: 1, pageSize: 20 } });
  const r = unwrap(w);
  if (!r.ok) {
    if (r.errorType === "ALLOCATING") return { ok: true, profile: null };
    return r;
  }
  const list = (r.obj as { esimList?: unknown })?.esimList;
  if (!Array.isArray(list) || list.length === 0) return { ok: true, profile: null };
  const e = list[0] as Record<string, unknown>;
  const str = (v: unknown) => (typeof v === "string" && v !== "" ? v : null);
  const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : null);
  const tranNo = str(e.esimTranNo);
  if (!tranNo) {
    return { ok: false, error: `esim/query row without esimTranNo: ${JSON.stringify(e).slice(0, 160)}` };
  }
  return {
    ok: true,
    profile: {
      esimTranNo: tranNo,
      iccid: str(e.iccid),
      ac: str(e.ac),
      smdpStatus: str(e.smdpStatus),
      esimStatus: str(e.esimStatus),
      activateTime: str(e.activateTime),
      installationTime: str(e.installationTime),
      expiredTime: str(e.expiredTime),
      totalVolume: num(e.totalVolume),
      orderUsage: num(e.orderUsage),
      pin: str(e.pin),
      puk: str(e.puk),
      apn: str(e.apn),
    },
  };
}

// ── Cancel ──────────────────────────────────────────────────────────────────

/** Cancel an UNINSTALLED profile — refunds the wholesale to our balance.
 *  Only allowed while esimStatus = GOT_RESOURCE and smdpStatus = RELEASED;
 *  anything later returns 200002. This is also the live-test mechanism: there
 *  is no sandbox, so "order → verify → cancel" is how a purchase is exercised
 *  without spending the wholesale. */
export async function cancelEsim(esimTranNo: string): Promise<{ ok: true } | EaFault> {
  const w = await call("esim/cancel", { esimTranNo });
  const r = unwrap(w);
  if (!r.ok) return r;
  return { ok: true };
}

// ── Balance ─────────────────────────────────────────────────────────────────

/** Account balance in USD, or null when unreadable (including: no AccessCode
 *  set). Null keeps poll-active-orders' recordBalance from writing, which the
 *  ops surfaces render as "no reading" — never as a healthy zero. */
export async function getBalanceUsd(): Promise<number | null> {
  if (!accessCode()) return null;
  const w = await call("balance/query", {});
  const r = unwrap(w);
  if (!r.ok) return null;
  const bal = (r.obj as { balance?: unknown })?.balance;
  return typeof bal === "number" && Number.isFinite(bal) ? bal / 10_000 : null;
}

// ── Helpers ─────────────────────────────────────────────────────────────────

/** Wire volumes are bytes with GiB marketing sizes (1GB plan = 1073741824),
 *  while the shipped client formats data_mb with a ÷1000 GB threshold. The
 *  hybrid keeps both shapes clean: ≥ ~1 GiB scales GiB→"GB" (5 GiB → 5000 →
 *  "5 GB"), below it rounds MiB (500 MiB → 500 → "500 MB"). A pure ×1000/GiB
 *  conversion would render sub-GB plans as "488 MB". ONE definition shared by
 *  sync-esim-plans, create-esim-order and check-esim-usage — totals written
 *  from different formulas would make the usage gauge drift. */
export function dataMbFromBytes(volume: number): number {
  const gib = volume / 1073741824;
  return gib >= 0.999 ? Math.round(gib * 1000) : Math.round(volume / 1048576);
}

/** Split `LPA:1$<smdp>$<matchingId>` into the two halves the client's manual
 *  install card renders. Returns nulls on anything malformed — a wrong SM-DP+
 *  address is worse than a missing one. */
export function parseLpa(ac: string | null | undefined): { smdp: string | null; matchingId: string | null } {
  if (typeof ac !== "string" || !ac.toUpperCase().startsWith("LPA:")) {
    return { smdp: null, matchingId: null };
  }
  const parts = ac.split("$");
  return {
    smdp: parts[1]?.trim() || null,
    matchingId: parts[2]?.trim() || null,
  };
}
