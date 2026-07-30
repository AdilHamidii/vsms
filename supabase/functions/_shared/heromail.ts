// HeroSMS temporary-EMAIL adapter.
//
// Same vendor, same API key, same balance as `herosms.ts` — and NOTHING else in
// common. This is a second, unrelated protocol living on the same account:
//
//                    SMS (herosms.ts)          EMAIL (this file)
//   base             /stubs/handler_api.php    /api/v1
//   shape            query params + actions    REST resources
//   auth             ?api_key=<key>            Authorization: ApiKey <key>
//   responses        4 wire forms (see there)  always JSON
//   errors           bare text (BAD_KEY)       {"title","details"[,"errors"]}
//
// Keeping them apart is deliberate. Folding email into the SMS adapter would
// mean one module with two auth schemes and two error vocabularies, and the
// classifier is the exact thing that must not get muddled — an adapter that
// fails to set `errorType` collapses dead account / bad key / rate limit /
// genuine stockout into one code, so users are told "try again" while the
// product is down and the escalation console.error never fires.
//
// ── Auth, and why it cost time ──────────────────────────────────────────────
// The scheme is `Authorization: ApiKey <key>`. It is NOT Bearer, not
// `X-Api-Key`, and not the `?api_key=` query param the SMS side uses. Every one
// of those returns `{"title":"Unauthenticated."}` — the SAME response an
// unknown route gives after auth, so a wrong scheme is easy to misread as "this
// API does not exist". It does exist; probed live 2026-07-30.
//
// ── Verified contract (probed live 2026-07-30, real purchases) ──────────────
//   GET    /emails/domains?site=<site>  -> {"data":[{name,cost,count}]}
//                                         `site` is REQUIRED (422 without it)
//   POST   /emails  {site,domain}       -> 201 {"data":{...Activation}}
//   GET    /emails/{id}                 -> 200 {"data":{...Activation}}
//   GET    /emails                      -> {"data":[...],"meta":{page,size,total}}
//   DELETE /emails/{id}                 -> 400 EARLY_CANCEL_DENIED inside 2 min
//
// ── The 2-minute cancel floor is the vendor's, not ours ─────────────────────
// DELETE inside the first 120s returns HTTP 400
// `{"title":"EARLY_CANCEL_DENIED","details":"You can't cancel activation in
// first 2 minutes"}`. Verified twice: denied at 106s, on the same activation.
// So a "cancel" button that is live before then produces a guaranteed failure
// with a title no user should ever read. Callers must respect
// EMAIL_MIN_HOLD_SECONDS — the same lesson as the SMS side's 180s hold, except
// here the provider enforces it and we cannot opt out.
//
// ── Availability is per (site, domain) and moves ────────────────────────────
// `count` is live stock for THAT target site, not a global figure: measured in
// one sweep, hotmail.com had 1,028 for google.com and **2** for discord.com.
// The cheap domains are the scarce ones, so stock has to be read at order time
// and rendered honestly. Never cache it into a catalog table.

import type { ProviderErrorType } from "./providers.ts";

const API = "https://hero-sms.com/api/v1";

/** Hard per-call timeout, matching every other adapter here: the ~150s
 *  edge-worker kill budget depends on no single provider call hanging. */
const TIMEOUT_MS = 10_000;

/** The BUY call gets longer, for the same reason as the SMS side: aborting a
 *  slow-but-successful allocation client-side leaves a paid orphan we cannot
 *  see, because the provider has already reserved and BILLED it. */
const BUY_TIMEOUT_MS = 30_000;

/** ISO-4217 numeric for USD. The API reports `currency: 840` on every
 *  activation; anything else means the vendor redenominated (SMS-Activate did
 *  exactly that, RUB -> USD, with no field rename and no version bump) and our
 *  cost arithmetic is off by ~90x. Callers should assert it. */
export const CURRENCY_USD = 840;

/** Provider-enforced. See the header — DELETE inside this window is refused. */
export const EMAIL_MIN_HOLD_SECONDS = 120;

function apiKey(): string {
  const k = Deno.env.get("HEROSMS_API_KEY");
  if (!k) throw new Error("HEROSMS_API_KEY env var not set");
  return k;
}

/** One activation, as the API returns it. `value` carries the extracted code
 *  and `message` the mail body; both are null while `status` is WAIT. */
export interface MailActivation {
  id: number;
  site: string;
  email: string;
  status: string;
  value: string | null;
  cost: number;
  currency: number;
  date: string;
  message: string | null;
}

export interface MailDomain {
  /** The API calls it `name`, not `domain`. */
  name: string;
  /** Wholesale USD for one activation on this (site, domain). */
  cost: number;
  /** Live stock for THIS site. Small and volatile on the cheap domains. */
  count: number;
}

export interface MailFault {
  ok: false;
  type: ProviderErrorType;
  status: number;
  /** The API's `title`, e.g. "EARLY_CANCEL_DENIED". Never shown to a user. */
  title: string;
  message: string;
}

export function faultOf(v: unknown): MailFault | null {
  return v && typeof v === "object" && (v as MailFault).ok === false
    ? v as MailFault
    : null;
}

/** Map the API's `title` onto the shared vocabulary.
 *
 *  Unlike the SMS protocol these are not suffixed, so exact matching is safe —
 *  but the set is open, so anything unrecognised falls back on HTTP status
 *  rather than defaulting to OUT_OF_STOCK. Guessing "out of stock" for an
 *  unknown failure is what sends a user domain-shopping over an outage. */
export function classifyMailFault(title: string, status: number): ProviderErrorType {
  switch (title.trim().toUpperCase()) {
    case "NO_FREE_EMAILS":
    case "NO_EMAILS":
    case "OUT_OF_STOCK":
    case "DOMAIN_NOT_AVAILABLE":
      return "OUT_OF_STOCK";
    case "NO_BALANCE":
    case "INSUFFICIENT_FUNDS":
      return "BALANCE_ERROR";
    case "UNAUTHENTICATED.":
    case "UNAUTHORIZED":
    case "BAD_KEY":
      return "AUTH_ERROR";
    case "TOO_MANY_REQUESTS":
      return "RATE_LIMITED";
    // EARLY_CANCEL_DENIED is a caller bug, not a provider fault — we asked to
    // cancel inside the 2-minute floor. Surfaced as TRANSPORT_ERROR so it is
    // never mistaken for "the domain ran out".
  }
  if (status === 401 || status === 403) return "AUTH_ERROR";
  if (status === 429) return "RATE_LIMITED";
  return "TRANSPORT_ERROR";
}

async function call<T>(
  method: "GET" | "POST" | "DELETE",
  path: string,
  opts: { body?: unknown; query?: Record<string, string>; timeoutMs?: number } = {},
): Promise<T | MailFault> {
  const url = new URL(`${API}${path}`);
  for (const [k, v] of Object.entries(opts.query ?? {})) url.searchParams.set(k, v);

  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), opts.timeoutMs ?? TIMEOUT_MS);
  let res: Response;
  let raw: string;
  try {
    res = await fetch(url, {
      method,
      signal: ctl.signal,
      headers: {
        // Exact scheme — see the header. Bearer/X-Api-Key/query all 401.
        Authorization: `ApiKey ${apiKey()}`,
        Accept: "application/json",
        ...(opts.body ? { "Content-Type": "application/json" } : {}),
      },
      ...(opts.body ? { body: JSON.stringify(opts.body) } : {}),
    });
    raw = await res.text();
  } catch (e) {
    return {
      ok: false, type: "TRANSPORT_ERROR", status: 0,
      title: "NETWORK", message: String(e),
    };
  } finally {
    clearTimeout(timer);
  }

  let body: unknown;
  try {
    body = JSON.parse(raw);
  } catch {
    // Not JSON. On the SMS side that means a Cloudflare edge block; treat the
    // same way here rather than reporting a parse error nobody can act on.
    return {
      ok: false,
      type: res.status === 429 || res.status === 403 ? "RATE_LIMITED" : "TRANSPORT_ERROR",
      status: res.status,
      title: "NON_JSON",
      message: raw.slice(0, 160),
    };
  }

  if (!res.ok) {
    const b = body as { title?: string; details?: string; errors?: Record<string, string[]> };
    const title = b.title ?? `HTTP_${res.status}`;
    // 422 carries per-field detail in `errors`; without it the message is just
    // "the request was well-formed but…", which says nothing actionable.
    const fieldMsgs = b.errors
      ? Object.entries(b.errors).map(([f, m]) => `${f}: ${m.join(", ")}`).join("; ")
      : "";
    return {
      ok: false,
      type: classifyMailFault(title, res.status),
      status: res.status,
      title,
      message: fieldMsgs || b.details || title,
    };
  }
  return body as T;
}

/** Domains sellable for `site`, with live wholesale and stock.
 *
 *  `site` is required by the API. It is the target the address will be used on
 *  (we pass `services.domain`), and BOTH price and stock vary by it. */
export async function listDomains(site: string): Promise<MailDomain[] | MailFault> {
  const r = await call<{ data: MailDomain[] }>("GET", "/emails/domains", { query: { site } });
  const f = faultOf(r);
  if (f) return f;
  return (r as { data: MailDomain[] }).data ?? [];
}

/** Buy one activation. The address is usable immediately; `status` starts WAIT. */
export async function buyActivation(
  site: string,
  domain: string,
): Promise<MailActivation | MailFault> {
  const r = await call<{ data: MailActivation }>("POST", "/emails", {
    body: { site, domain },
    timeoutMs: BUY_TIMEOUT_MS,
  });
  const f = faultOf(r);
  if (f) return f;
  return (r as { data: MailActivation }).data;
}

/** Current state of one activation. */
export async function getActivation(id: number | string): Promise<MailActivation | MailFault> {
  const r = await call<{ data: MailActivation }>("GET", `/emails/${id}`);
  const f = faultOf(r);
  if (f) return f;
  return (r as { data: MailActivation }).data;
}

/** Release an activation. Refused inside EMAIL_MIN_HOLD_SECONDS — callers must
 *  check the age first rather than relying on the error. */
export async function cancelActivation(id: number | string): Promise<true | MailFault> {
  const r = await call<unknown>("DELETE", `/emails/${id}`);
  const f = faultOf(r);
  return f ?? true;
}

/** True when the provider refused a cancel because the 2-minute floor has not
 *  elapsed. Distinct from a real failure: the activation is still alive and
 *  still ours. */
export function isEarlyCancel(f: MailFault): boolean {
  return f.title.trim().toUpperCase() === "EARLY_CANCEL_DENIED";
}
