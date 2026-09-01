// Buy a temporary email address for one service.
//
// Third product line. Unlike SMS there is no country and no operator: the
// provider needs the TARGET SITE (which we take from `services.domain`) and a
// mail domain. Both price and stock vary by that pair, so this function quotes
// live and never trusts a cached catalog — there is no email catalog table by
// design.
//
// Pricing (owner, 2026-07-31): gmail.com costs 1 credit; outlook.com and
// hotmail.com are FREE and are the DEFAULT. The free tier is bounded server-side
// by begin_email_order: the lifetime allowance keyed on mailbox AND device
// (push token), plus a per-IP daily cap (`app_config.email_free_ip_daily_cap`).
// The IP is hashed HERE and passed as `p_ip_hash` — the function never sees a
// raw address. Added 2026-09-01 against a farm that ran 75 signups from two
// phones to harvest free facebook.com mailboxes (see migration 20260901100000).

import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import {
  listDomains, buyActivation, faultOf, CURRENCY_USD,
} from "../_shared/heromail.ts";

interface Body { service_id: string; domain: string; }

/** The domains we resell, and what we charge. Anything else is refused
 *  outright: the provider also lists 19 Yandex TLDs that no Western site
 *  accepts, and selling them would be selling a guaranteed failure. */
// icloud.com REMOVED 2026-07-31 (owner decision): issuing throwaway addresses on
// Apple's own consumer domain, from an app on Apple's store, is an avoidable
// review risk for a tier that earned nothing. This map is the ENFORCEMENT — the
// guard below rejects any domain absent from it with `domain_unavailable`, so
// removing the key is sufficient and no separate blocklist is needed. Existing
// orders already in flight are unaffected; only new ones are refused.
// gmail.com REMOVED 2026-08-26 (owner decision): the HeroSMS gmail pool stopped
// delivering ~2026-08-10 — 1 code in its last 36 orders, 0 of the last 23,
// while outlook/hotmail delivered normally in the same window. It was the only
// paid tier (1 credit) and every failure charge-and-refunded, so users paid,
// failed, retried. Re-add the key when the `email-domain-gmail.com` watchdog
// evidence says the pool delivers again — the removal IS the enforcement, same
// as icloud. Keep in lockstep with email-domains' copy.
const PRICING: Record<string, number> = {
  "outlook.com": 0,
  "hotmail.com": 0,
};

/** Same shape as the SMS ceiling: the most we may pay for something sold at N
 *  credits, plus flat headroom so a route sitting exactly on the boundary does
 *  not fail the instant the vendor moves a cent.
 *
 *  The FREE tier cannot use a margin ratio — N=0 makes any ceiling 0 — so it
 *  gets an absolute cap instead.
 *
 *  ⚠️ Owner decision 2026-08-13: "free emails should always get accepted."
 *  The cap was $0.02 (~6x the $0.0034 list price), which silently made the
 *  free tier unavailable for any service whose mailboxes price higher —
 *  facebook quotes $0.051 on BOTH free domains, so the most-wanted target was
 *  never free, and the refusal rendered SMS copy ("costs more than expected").
 *  $1.00 is a GLITCH GUARD in the MAX_WHOLESALE_CENTS tradition, not a price
 *  policy: every real-world quote passes; a mis-parsed $99 must not be bought
 *  for $0. Worst-case exposure is bounded by email_free_daily_cap (3/user/day),
 *  not by this constant. */
/** ⚠️ 0.30 UNTIL 2026-08-18, i.e. stale by two weeks. `NET_USD_PER_CREDIT` is
 *  one measured fact about the whole business — what a credit actually nets
 *  after Apple's cut, derived from real receipts — not a per-product knob. It
 *  was corrected 0.30 → 0.40 on 08-05 in `create-order` and `sync-prices` and
 *  this third copy was missed, leaving the e-mail line's order-time ceiling
 *  ~25% tighter than intended. Non-binding in practice (gmail wholesale is
 *  ~$0.04 against a ceiling of $0.15), which is exactly why nobody noticed.
 *  Re-derive from receipts if the pack mix shifts; change all three together. */
const NET_USD_PER_CREDIT = 0.40;
const MIN_MARGIN = 6.0;
const CEILING_HEADROOM_USD = 0.10;
const FREE_MAX_COST_USD = 1.00;

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, { status: 405 });

  const userId = await callerUserId(req);
  if (!userId) return json({ error: "unauthorized" }, { status: 401 });

  let body: Body;
  try { body = await req.json(); }
  catch { return json({ error: "invalid_body" }, { status: 400 }); }
  if (!body.service_id || !body.domain) {
    return json({ error: "missing_fields" }, { status: 400 });
  }

  const domain = body.domain.trim().toLowerCase();
  const credits = PRICING[domain];
  if (credits === undefined) {
    return json({ error: "domain_unavailable" }, { status: 400 });
  }

  const sb = admin();

  // ── The target site ──────────────────────────────────────────────────────
  // `site` is REQUIRED by the provider. 11 of 265 visible services have no
  // domain, so they cannot offer email at all — refuse here rather than let the
  // provider 422 with a message no user should read.
  const { data: service, error: svcErr } = await sb
    .from("services").select("id, name, domain").eq("id", body.service_id).maybeSingle();
  if (svcErr) {
    console.error(`create-email-order: service read failed: ${svcErr.message}`);
    return json({ error: "service_lookup_failed" }, { status: 500 });
  }
  if (!service) return json({ error: "unknown_service" }, { status: 404 });
  const site = (service.domain ?? "").trim().toLowerCase();
  if (!site) return json({ error: "email_unsupported_service" }, { status: 409 });

  // ── Live quote: price AND stock, for THIS site ───────────────────────────
  const domains = await listDomains(site);
  const listFault = faultOf(domains);
  if (listFault) {
    console.error(`create-email-order: domains(${site}) ${listFault.title}: ${listFault.message}`);
    return json({ error: "provider_unreachable" }, { status: 502 });
  }
  const quote = (domains as Awaited<ReturnType<typeof listDomains>> as
    { name: string; cost: number; count: number }[])
    .find((d) => d.name.toLowerCase() === domain);

  if (!quote) return json({ error: "domain_unavailable" }, { status: 409 });

  // Stock is per (site, domain) and genuinely runs dry — hotmail.com measured
  // TWO available for discord.com while showing 1,028 for google.com. Refusing
  // here is the difference between an honest "out of stock" and a charge that
  // fails at the provider.
  if (!(quote.count > 0)) {
    return json({ error: "email_out_of_stock" }, { status: 409 });
  }

  // ── Margin ceiling on the REAL quoted cost ───────────────────────────────
  const maxCostUsd = credits > 0
    ? (credits * NET_USD_PER_CREDIT) / MIN_MARGIN + CEILING_HEADROOM_USD
    : FREE_MAX_COST_USD;
  if (quote.cost > maxCostUsd) {
    console.error(
      `create-email-order: margin refused ${site}/${domain} cost=$${quote.cost} ` +
      `max=$${maxCostUsd.toFixed(4)} credits=${credits}`,
    );
    return json({ error: "margin_too_low" }, { status: 409 });
  }

  // ── Charge (or, for the free tier, just claim a slot) ────────────────────
  const { data: begun, error: beginErr } = await sb.rpc("begin_email_order", {
    p_user: userId, p_service: service.id, p_site: site,
    p_domain: domain, p_credits: credits,
    p_ip_hash: await clientIpHash(req),
  });
  if (beginErr) {
    console.error(`create-email-order: begin_email_order failed: ${beginErr.message}`);
    return json({ error: "spend_failed" }, { status: 500 });
  }
  const res = begun as
    {
      ok?: boolean; reason?: string; order_id?: string; cap?: number;
      used?: number; grants?: number;
    } | null;

  if (res?.reason === "insufficient")       return json({ error: "insufficient_credits" }, { status: 402 });
  if (res?.reason === "duplicate_request")  return json({ error: "duplicate_request" }, { status: 409 });
  if (res?.reason === "free_limit_reached") {
    return json({ error: "free_limit_reached", cap: res.cap ?? 3 }, { status: 429 });
  }
  // Per-IP daily cap on FREE addresses (subscribers are exempt). Rendered with
  // the client's existing `free_limit_reached` copy ("used today's free
  // addresses… try again tomorrow, or subscribe"), which is exactly right, so
  // no client change is needed.
  if (res?.reason === "ip_limit_reached") {
    return json({ error: "free_limit_reached", cap: res.cap ?? 3 }, { status: 429 });
  }
  // Lifetime free allowance used up, not subscribed. 402, not 429 — this is
  // "payment required", and waiting does not make it go away the way a rate
  // limit does.
  if (res?.reason === "subscription_required") {
    return json({
      error: "subscription_required",
      used: res.used ?? null,
      grants: res.grants ?? null,
    }, { status: 402 });
  }
  // Subscribed, but the SHARED free-domain inventory has a stated hard stop
  // per subscriber per day (`app_config.email_sub_daily_cap`) — one looping
  // subscriber must not be able to drain stock for everyone else.
  if (res?.reason === "daily_cap_reached") {
    return json({ error: "daily_cap_reached", cap: res.cap ?? 25 }, { status: 429 });
  }
  const orderId = res?.order_id;
  if (!res?.ok || !orderId) {
    console.error(`create-email-order: unexpected begin result ${JSON.stringify(res)}`);
    return json({ error: "spend_failed" }, { status: 500 });
  }

  // ── Reserve at the provider ──────────────────────────────────────────────
  const bought = await buyActivation(site, domain);
  const buyFault = faultOf(bought);
  if (buyFault) {
    console.error(
      `create-email-order: buy FAILED ${site}/${domain} user=${userId} ` +
      `order=${orderId} ${buyFault.title}: ${buyFault.message}`,
    );
    await failEmail(sb, orderId, userId, credits);
    const code = buyFault.type === "OUT_OF_STOCK"
      ? "email_out_of_stock"
      : buyFault.type === "BALANCE_ERROR" || buyFault.type === "AUTH_ERROR"
      ? "provider_unreachable"
      : "email_purchase_failed";
    return json({ error: code }, { status: 503 });
  }

  const act = bought as Exclude<typeof bought, { ok: false }>;

  // A redenomination would silently move every cost by ~90x — SMS-Activate did
  // exactly that with no field rename. Record, do not fail: we already hold the
  // address and the user is waiting.
  if (act.currency !== CURRENCY_USD) {
    console.error(
      `create-email-order: UNEXPECTED CURRENCY ${act.currency} (want ${CURRENCY_USD}) ` +
      `order=${orderId} — cost arithmetic is suspect`,
    );
  }

  // ── Persist, claim-gated ─────────────────────────────────────────────────
  const { data: claimed, error: upErr } = await sb
    .from("email_orders")
    .update({
      provider_id: String(act.id),
      email: act.email,
      provider_status: act.status,
      actual_cost_cents: Math.round(act.cost * 100),
      updated_at: new Date().toISOString(),
    })
    .eq("id", orderId)
    .eq("status", "waiting")      // atomic claim — never overwrite a terminal row
    .select("*")
    .single();

  // Destructure the error. This exact omission is why every failed eSIM
  // purchase once kept the user's money: `claimed` came back empty, the
  // function returned, and nothing refunded.
  if (upErr || !claimed) {
    console.error(
      `create-email-order: persist FAILED order=${orderId} provider_id=${act.id} ` +
      `email=${act.email} err=${upErr?.message ?? "no row claimed"}`,
    );
    await failEmail(sb, orderId, userId, credits);
    return json({ error: "order_persist_failed" }, { status: 500 });
  }

  return json({ order: claimed });
});

/** SHA-256 hex of the caller's IP, or null when no proxy header is present
 *  (then only the mailbox + device keys gate the free path). The first
 *  `x-forwarded-for` entry is the client as seen by Supabase's edge proxy. */
async function clientIpHash(req: Request): Promise<string | null> {
  const xff = req.headers.get("x-forwarded-for") ?? "";
  const ip = (xff.split(",")[0] ?? "").trim() ||
    (req.headers.get("cf-connecting-ip") ?? "").trim();
  if (!ip) return null;
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(ip));
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Close a live row and refund if it was paid — ONE transaction.
 *
 *  close_email_order_claim locks the row, re-checks 'waiting', flips and
 *  refunds atomically; a refund failure rolls the flip back so the next closer
 *  (or the 5-minute sweep) retries. The old claim-then-refund pair left a
 *  killed worker's row terminal with the money kept. Double refunds stay
 *  impossible via the partial unique index on (email_order_id) where
 *  reason='refund'. */
async function failEmail(
  // deno-lint-ignore no-explicit-any
  sb: any, orderId: string, _userId: string, _credits: number,
): Promise<void> {
  const { error: closeErr } = await sb.rpc("close_email_order_claim", {
    p_order: orderId, p_status: "failed",
  });
  if (closeErr) {
    console.error(`failEmail: close_email_order_claim FAILED order=${orderId}: ${closeErr.message}`);
  }
}
