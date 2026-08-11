// Buy an eSIM data plan: charge credits up-front, order at eSIM Access, poll
// briefly for the allocated profile (allocation is ASYNC, ≤~30s), persist.
// No provider fallback and no 20-min auto-refund — an eSIM is a one-shot
// provisioned profile. If the in-request poll misses the allocation, the row
// stays 'provisioning' and check-esim-usage (which the shipped client polls
// every 8s on the detail screen) finishes the job.

import { handleCors, json } from "../_shared/cors.ts";
import { notifySafe, esc } from "../_shared/telegram.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import {
  cancelEsim, dataMbFromBytes, listPackages, orderEsim, parseLpa, queryEsim,
  type EaProfile,
} from "../_shared/esimaccess.ts";

interface Body { plan_id: string; }

// Mirrors sync-esim-plans: retail_credits = ceil(usd * ESIM_MARGIN / CREDIT_VALUE_USD).
// Inverted, the most we may pay for a plan sold at N credits is
// N * CREDIT_VALUE_USD / ESIM_MARGIN = N * 0.12.
// Keep ESIM_MARGIN in lockstep with sync-esim-plans or the ceiling stops
// matching what we actually charged.
const ESIM_MARGIN = 4;
const CREDIT_VALUE_USD = 0.48;
const MAX_COST_PER_CREDIT_USD = CREDIT_VALUE_USD / ESIM_MARGIN;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, { status: 405 });

  const userId = await callerUserId(req);
  if (!userId) return json({ error: "unauthorized" }, { status: 401 });

  let body: Body;
  try { body = await req.json(); }
  catch { return json({ error: "invalid_body" }, { status: 400 }); }
  if (!body.plan_id) return json({ error: "missing_fields" }, { status: 400 });

  const sb = admin();

  const { data: plan, error: pErr } = await sb
    .from("esim_plans")
    .select("id, retail_credits, status, last_cost_cents, country_code")
    .eq("id", body.plan_id).single();
  if (pErr || !plan) return json({ error: "unknown_plan" }, { status: 404 });
  if (plan.status !== "active" || plan.retail_credits == null) {
    return json({ error: "plan_unavailable" }, { status: 409 });
  }

  // Provider ownership gate — the refuseRetired() equivalent the eSIM path
  // never had. Only eSIM Access plans ('ea:<packageCode>') are orderable: a
  // legacy SMSPool row that somehow came back active must never have its id
  // sent to a vendor that assigns different meanings to the same numbers
  // (the esim_plans PK landmine, closed 2026-08-10).
  if (typeof plan.id !== "string" || !plan.id.startsWith("ea:")) {
    return json({ error: "plan_unavailable" }, { status: 409 });
  }
  const packageCode = plan.id.slice(3);
  const cost = plan.retail_credits as number;

  // ── Live price check ─────────────────────────────────────────────────────
  // sync-esim-plans runs once daily, leaving a 24h window in which the
  // provider can move a price. package/list with the exact packageCode is a
  // fresh quote for the exact plan we are about to buy.
  //
  // Fail-CLOSED on evidence of a bad price, fail-OPEN on a failed lookup: an
  // unreachable provider must not make eSIMs unbuyable, and the cached price
  // already satisfied the margin when it was written. We only override the
  // catalog when we actually have a contradicting number. The price ECHO on
  // the order call below is the second, provider-side half of this guard.
  const maxCostUsd = cost * MAX_COST_PER_CREDIT_USD;
  let liveCostUsd: number | null = null;
  {
    const quote = await listPackages(packageCode);
    if (quote.ok) {
      const match = quote.packages.find((p) => p.packageCode === packageCode);
      const usd = match && typeof match.price === "number" ? match.price / 10_000 : NaN;
      if (Number.isFinite(usd) && usd > 0) liveCostUsd = usd;
    } else {
      console.error(`esim: live price lookup failed for ${plan.id} (proceeding on cached): ${quote.error}`);
    }
  }

  if (liveCostUsd != null && liveCostUsd > maxCostUsd) {
    console.error(
      `esim BLOCKED ${plan.id}: live $${liveCostUsd.toFixed(2)} exceeds ` +
      `$${maxCostUsd.toFixed(2)} ceiling for ${cost} credits — catalog is stale`,
    );
    // Nothing has been charged yet: the spend happens below. Refusing here
    // costs a sale; letting it through costs real money on every sale.
    return json({ error: "margin_too_low" }, { status: 409 });
  }

  // ── Pre-charge provider-balance guard (mirrors create-order's) ──────────
  // Refuse BEFORE charging when eSIM Access is broke: poll-active-orders
  // writes esimaccess_health every minute, and if that reading is fresh and
  // below this order's own ceiling the purchase can only end charge-then-
  // refund. Fails OPEN on stale or missing data — a dead poller must not make
  // eSIMs unbuyable. The SMSPool era had NO such guard (documented gap).
  try {
    const { data: h } = await sb
      .from("app_config").select("value").eq("key", "esimaccess_health").maybeSingle();
    const health = h?.value as { balance_usd?: number; checked_at?: string } | null;
    const fresh = !!health?.checked_at &&
      Date.now() - new Date(health.checked_at).getTime() < 5 * 60 * 1000;
    if (fresh && typeof health?.balance_usd === "number" && health.balance_usd < maxCostUsd) {
      console.error(
        `create-esim-order: pre-charge refusal — esimaccess $${health.balance_usd} ` +
        `below $${maxCostUsd.toFixed(2)} for plan ${plan.id}`,
      );
      try {
        EdgeRuntime.waitUntil(notifySafe(
          `🚨 <b>eSIM order refused — provider balance too low</b>\n` +
          `have $${health.balance_usd.toFixed(2)}, this order needs up to ` +
          `$${maxCostUsd.toFixed(2)} (plan ${esc(plan.id)})\n` +
          `User was NOT charged. Top up eSIM Access.`,
        ));
      } catch { /* paging must never affect the order path */ }
      return json({ error: "provider_unreachable" }, { status: 503 });
    }
  } catch (e) {
    console.error("esim balance guard failed (proceeding):", e);
  }

  // Dedupe + charge in ONE transaction under a per-user advisory lock, the
  // same shape begin_order uses for SMS. This function used to call
  // wallet_spend and only insert the row ~20 lines later, after a provider
  // round-trip — so a double-tap bought two eSIMs and charged twice, and a
  // worker death in that window charged with no order row, no refund and no
  // trace. That is exactly the failure that produced "258 spends vs 126
  // orders" on the SMS side.
  const { data: begun, error: beginErr } = await sb.rpc("begin_esim_order", {
    p_user: userId, p_plan: plan.id, p_credits: cost,
  });
  if (beginErr) {
    return json({ error: "spend_failed", detail: beginErr.message }, { status: 500 });
  }
  // `reason`, NOT `status`. begin_esim_order returns
  // jsonb_build_object('ok', false, 'reason', 'insufficient'|'duplicate_request').
  // Reading `status` made BOTH branches below dead code, so running out of
  // credits and double-tapping both fell through to spend_failed/500 and the
  // app said "We couldn't complete that" instead of "Not enough credits — tap
  // Top up" or "That purchase is already going through". No money moved either
  // way (the SQL rolls back before charging); it was purely the wrong message
  // on the two most likely failures.
  const beginRes = begun as { ok?: boolean; reason?: string; order_id?: string } | null;
  if (beginRes?.reason === "insufficient") {
    return json({ error: "insufficient_credits", needed: cost }, { status: 402 });
  }
  if (beginRes?.reason === "duplicate_request") {
    // An identical purchase is already in flight for this user+plan.
    return json({ error: "duplicate_request" }, { status: 409 });
  }
  const orderId = beginRes?.order_id;
  if (!orderId) {
    return json({ error: "spend_failed" }, { status: 500 });
  }

  /** Close the reserved row and return the credits — ONE transaction.
   *  fail_esim_order_claim locks the row, re-checks 'provisioning', flips to
   *  'failed' and refunds atomically; a refund failure rolls the flip back so
   *  the row stays live and the next closer retries. The old claim-then-refund
   *  pair left a killed worker's row terminal with the money kept. */
  const failEsim = async (reason: string) => {
    const { data: didClose, error: closeErr } = await sb.rpc("fail_esim_order_claim", {
      p_order: orderId,
    });
    if (closeErr) {
      console.error(`failEsim: fail_esim_order_claim FAILED order=${orderId} reason=${reason}: ${closeErr.message}`);
      return;
    }
    if (!didClose) return;   // already closed elsewhere
    console.warn(`create-esim-order failed plan=${plan.id} reason=${reason} order=${orderId}`);
  };

  // ── Provider order ───────────────────────────────────────────────────────
  // transactionId = our order UUID: eSIM Access treats a duplicate id as the
  // SAME request, so the single retry below can never buy a second profile —
  // a property no SMS provider offered, and the only reason a retry is safe.
  //
  // The price is ALWAYS echoed (live quote, else the cached catalog price):
  // their /esim/order has no maxPrice cap and its success response reports no
  // cost, so the echo is the only order-time price guard. Genuine drift fails
  // 200005/200006 (PRICE_DRIFT) → refund → honest margin_too_low, instead of
  // silently paying more than the catalog priced.
  const costUsdForOrder = liveCostUsd ?? (plan.last_cost_cents as number) / 100;
  const priceTenK = Math.round(costUsdForOrder * 10_000);

  let buy = await orderEsim(orderId, packageCode, priceTenK);
  if (!buy.ok && (buy.errorType === "BUSY" || buy.errorType === "TRANSPORT_ERROR" ||
                  buy.errorType === "RATE_LIMITED")) {
    await sleep(1500);
    buy = await orderEsim(orderId, packageCode, priceTenK);
  }

  if (!buy.ok) {
    // Log the PROVIDER'S OWN message, not just our classification — when three
    // SMSPool purchases failed on 2026-07-30 there was no recoverable reason
    // anywhere in the system because only the errorType was printed.
    console.error(
      `esim purchase FAILED plan=${plan.id} user=${userId} ` +
      `type=${buy.errorType ?? "unclassified"} detail=${buy.error ?? "(none)"}`,
    );
    await failEsim(buy.errorType ?? "purchase_failed");
    try {
      const extra =
        buy.errorType === "BALANCE_ERROR"
          ? `\n💸 eSIM Access balance is SHORT of ~$${costUsdForOrder.toFixed(2)} — top up.`
          : buy.errorType === "BAD_PACKAGE"
          ? `\n🧭 OUR catalog/mapping is wrong for this plan (package unknown at provider) — not a stockout.`
          : "";
      EdgeRuntime.waitUntil(notifySafe(
        `🚨 <b>eSIM purchase failed</b>\n` +
        `plan <b>${esc(plan.id)}</b> · ${cost} credits · refunded\n` +
        `${buy.errorType ?? "unclassified"}: ${esc(buy.error ?? "no detail")}${extra}`,
      ));
    } catch { /* paging must never affect the order path */ }
    // Classify, don't echo — provider prose matches no case in APIError and
    // falls through to "Something went wrong on our side". Existing codes ONLY:
    // the shipped client maps these and nothing else.
    if (buy.errorType === "PRICE_DRIFT") {
      // Charged and refunded above; the catalog reprices on the next sync.
      return json({ error: "margin_too_low" }, { status: 409 });
    }
    const code = buy.errorType === "OUT_OF_STOCK"
      ? "esim_out_of_stock"
      : buy.errorType === "AUTH_ERROR" || buy.errorType === "BALANCE_ERROR" ||
        buy.errorType === "BAD_PACKAGE"
      ? "provider_unreachable"
      : "esim_purchase_failed";
    return json({ error: code }, { status: 503 });
  }

  // ── Persist the provider order id IMMEDIATELY, before any polling. ───────
  // A worker killed mid-poll must not leave a PAID profile unlocatable: with
  // ea_order_no on the row, check-esim-usage can finish the allocation later;
  // without it the row is stuck 'provisioning' forever (the expiry sweep only
  // touches rows with expires_at set). Claim-gated on 'provisioning' exactly
  // like create-order:441. `provider` is written explicitly as belt-and-braces
  // for the deploy window where begin_esim_order still inserts the default.
  const { data: reserved, error: resErr } = await sb
    .from("esim_orders")
    .update({
      provider: "esimaccess",
      ea_order_no: buy.orderNo,
      // The FRESH quote when we have one — actual_cost_cents used to echo the
      // cached catalog price, which made margin analysis circular. The price
      // echo above guarantees we paid no more than this figure.
      actual_cost_cents: Math.round(costUsdForOrder * 100),
      updated_at: new Date().toISOString(),
    })
    .eq("id", orderId)
    .eq("status", "provisioning")
    .select("*").single();

  if (resErr || !reserved) {
    // The profile is (or will be) allocated at the provider but we cannot
    // record where. Reclaim the wholesale if it is still cancellable, make the
    // user whole, and page — this is the one path where money left twice.
    console.error(`esim order_persist_failed order=${orderId} orderNo=${buy.orderNo}: ${resErr?.message}`);
    try {
      const q = await queryEsim({ orderNo: buy.orderNo });
      if (q.ok && q.profile?.esimTranNo) {
        const c = await cancelEsim(q.profile.esimTranNo);
        if (!c.ok) console.error(`esim persist-fail cancel refused: ${c.error}`);
      }
    } catch { /* best-effort reclaim only */ }
    await failEsim("order_persist_failed");
    try {
      EdgeRuntime.waitUntil(notifySafe(
        `🚨 <b>eSIM order persist FAILED</b> — provider orderNo <b>${esc(buy.orderNo)}</b>, ` +
        `our order ${esc(orderId)}. Wholesale cancel attempted; verify by hand.`,
      ));
    } catch { /* ignore */ }
    return json({ error: "order_persist_failed", detail: resErr?.message }, { status: 500 });
  }

  // ── Short in-request allocation poll (~10s worst case). ─────────────────
  // Allocation typically completes inside 30s; catching it here hands the QR
  // to the client in the purchase response. Missing it is fine — the row
  // stays 'provisioning' and the detail screen's 8s check-esim-usage loop
  // completes it. A real fault stops the poll; ALLOCATING (profile: null)
  // keeps waiting.
  let profile: EaProfile | null = null;
  for (const delayMs of [2000, 3000, 5000]) {
    await sleep(delayMs);
    const q = await queryEsim({ orderNo: buy.orderNo });
    if (!q.ok) { console.error(`esim allocation poll fault order=${orderId}: ${q.error}`); break; }
    if (q.profile) { profile = q.profile; break; }
  }

  let order = reserved;
  if (profile?.ac) {
    const lpa = parseLpa(profile.ac);
    const { data: fulfilled, error: fulErr } = await sb
      .from("esim_orders")
      .update({
        status: "installed",
        ea_tran_no: profile.esimTranNo,
        iccid: profile.iccid,
        activation_code: profile.ac,
        smdp_address: lpa.smdp,
        matching_id: lpa.matchingId,
        apn: profile.apn,
        sim_pin: profile.pin,
        sim_puk: profile.puk,
        data_total_mb: profile.totalVolume != null ? dataMbFromBytes(profile.totalVolume) : null,
        // 0 is a real reading, not a missing one — the shipped client renders
        // an unwritten column as zero usage anyway; a written 0 is honest.
        data_used_mb: 0,
        updated_at: new Date().toISOString(),
      })
      .eq("id", orderId)
      .eq("status", "provisioning")
      .select("*").single();
    if (fulErr || !fulfilled) {
      // The purchase itself SUCCEEDED and ea_order_no is already persisted —
      // check-esim-usage self-heals this row. Do not refund a delivered eSIM
      // over a cosmetic write failure.
      console.error(`esim fulfil-write failed order=${orderId} (self-heals via poll): ${fulErr?.message}`);
    } else {
      order = fulfilled;
    }
  }

  // Operator alert — same non-blocking contract as iap-verify: never awaited,
  // never throws, and the per-minute sweep re-sends if Telegram is down.
  try {
    EdgeRuntime.waitUntil(alertEsim(sb, {
      id: order.id, credits: cost, planId: plan.id, status: order.status,
    }));
  } catch (e) {
    console.error("esim alert dispatch failed (ignored):", e);
  }

  return json({ order });
});

async function alertEsim(
  sb: ReturnType<typeof admin>,
  e: { id: string; credits: number; planId: string; status: string },
): Promise<void> {
  try {
    const { data: claimed } = await sb
      .from("telegram_events")
      .insert({ kind: "esim", ref: String(e.id) })
      .select("ref").maybeSingle();
    if (!claimed) return;
    await notifySafe(
      `🌍 <b>eSIM purchased</b>\n${e.credits} credits · plan ${esc(e.planId)} · ${esc(e.status)}`,
    );
  } catch (err) {
    console.error("alertEsim failed (ignored):", err);
  }
}
