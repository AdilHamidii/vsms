// Buy a temporary email address for one service.
//
// Third product line. Unlike SMS there is no country and no operator: the
// provider needs the TARGET SITE (which we take from `services.domain`) and a
// mail domain. Both price and stock vary by that pair, so this function quotes
// live and never trusts a cached catalog — there is no email catalog table by
// design.
//
// Pricing (owner, 2026-07-30): gmail.com and icloud.com cost 1 credit,
// outlook.com and hotmail.com are FREE. The free tier is bounded server-side by
// begin_email_order's per-user daily cap, which is the only thing standing
// between us and unbounded spend now that there is no credit gate.

import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import {
  listDomains, buyActivation, faultOf, CURRENCY_USD,
} from "../_shared/heromail.ts";

interface Body { service_id: string; domain: string; }

/** The four we resell, and what we charge. Anything else is refused outright:
 *  the provider also lists 19 Yandex TLDs that no Western site accepts, and
 *  selling them would be selling a guaranteed failure. */
const PRICING: Record<string, number> = {
  "gmail.com": 1,
  "icloud.com": 1,
  "outlook.com": 0,
  "hotmail.com": 0,
};

/** Same shape as the SMS ceiling: the most we may pay for something sold at N
 *  credits, plus flat headroom so a route sitting exactly on the boundary does
 *  not fail the instant the vendor moves a cent.
 *
 *  The FREE tier cannot use a margin ratio — N=0 makes any ceiling 0 — so it
 *  gets an absolute cap instead. At $0.0034 list, $0.02 is ~6x headroom and
 *  still refuses anything that has quietly become expensive. */
const NET_USD_PER_CREDIT = 0.30;
const MIN_MARGIN = 6.0;
const CEILING_HEADROOM_USD = 0.10;
const FREE_MAX_COST_USD = 0.02;

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
  });
  if (beginErr) {
    console.error(`create-email-order: begin_email_order failed: ${beginErr.message}`);
    return json({ error: "spend_failed" }, { status: 500 });
  }
  const res = begun as
    { ok?: boolean; reason?: string; order_id?: string; cap?: number } | null;

  if (res?.reason === "insufficient")       return json({ error: "insufficient_credits" }, { status: 402 });
  if (res?.reason === "duplicate_request")  return json({ error: "duplicate_request" }, { status: 409 });
  if (res?.reason === "free_limit_reached") {
    return json({ error: "free_limit_reached", cap: res.cap ?? 3 }, { status: 429 });
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

/** Close a live row and refund if it was paid.
 *
 *  Claim-gated so a concurrent poller cannot double-refund, and backed by the
 *  partial unique index on (email_order_id) where reason='refund' if it ever is. */
async function failEmail(
  // deno-lint-ignore no-explicit-any
  sb: any, orderId: string, userId: string, credits: number,
): Promise<void> {
  const { data: claimed, error: claimErr } = await sb
    .from("email_orders")
    .update({ status: "failed", closed_at: new Date().toISOString(), updated_at: new Date().toISOString() })
    .eq("id", orderId)
    .eq("status", "waiting")
    .select("id");
  if (claimErr) {
    console.error(`failEmail: claim failed order=${orderId}: ${claimErr.message}`);
    return;
  }
  if (!claimed || claimed.length === 0) return;   // already closed elsewhere

  if (credits <= 0) return;                       // free tier: nothing to give back

  const { error: refundErr } = await sb.rpc("wallet_move_email", {
    p_user: userId, p_amount: credits, p_reason: "refund", p_email_order: orderId,
  });
  if (refundErr) {
    console.error(
      `failEmail: REFUND FAILED order=${orderId} user=${userId} ` +
      `credits=${credits}: ${refundErr.message}`,
    );
  }
}
