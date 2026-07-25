// Buy an eSIM data plan: charge credits up-front, purchase at SMSPool, fetch the
// activation profile (QR/LPA + usage), persist. No provider fallback and no
// 20-min auto-refund — an eSIM is a one-shot provisioned profile.

import { handleCors, json } from "../_shared/cors.ts";
import { notifySafe, esc } from "../_shared/telegram.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import { esimPurchase, esimProfile, esimPlans } from "../_shared/smspool.ts";

interface Body { plan_id: string; }

// Mirrors sync-esim-plans: retail_credits = ceil(usd * ESIM_MARGIN / CREDIT_VALUE_USD).
// Inverted, the most we may pay for a plan sold at N credits is
// N * CREDIT_VALUE_USD / ESIM_MARGIN = N * 0.12.
// Keep ESIM_MARGIN in lockstep with sync-esim-plans or the ceiling stops
// matching what we actually charged.
const ESIM_MARGIN = 4;
const CREDIT_VALUE_USD = 0.48;
const MAX_COST_PER_CREDIT_USD = CREDIT_VALUE_USD / ESIM_MARGIN;

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
  const cost = plan.retail_credits as number;

  // ── Live price check ─────────────────────────────────────────────────────
  // SMSPool's /esim/purchase takes only a plan id: it accepts no price cap and
  // its response reports no cost, so nothing downstream can detect a bad buy.
  // Worse, actual_cost_cents used to be filled from the CACHED catalog price,
  // so a loss would show healthy margins in our own tables. sync-esim-plans
  // runs once daily, leaving a 24h window in which SMSPool can raise a price
  // and every sale in that window loses money silently.
  //
  // /esim/plans is the same endpoint sync-esim-plans uses, so this is a fresh
  // quote for the exact plan we are about to buy.
  //
  // Fail-CLOSED on evidence of a bad price, fail-OPEN on a failed lookup: an
  // unreachable SMSPool must not make eSIMs unbuyable, and the cached price
  // already satisfied the 3x margin when it was written. We only override the
  // catalog when we actually have a contradicting number.
  const maxCostUsd = cost * MAX_COST_PER_CREDIT_USD;
  let liveCostUsd: number | null = null;
  try {
    const rows = await esimPlans(String(plan.country_code));
    const match = (rows ?? []).find((p) => String(p.ID) === String(plan.id));
    const usd = match ? parseFloat(String(match.price)) : NaN;
    if (Number.isFinite(usd) && usd > 0) liveCostUsd = usd;
  } catch (e) {
    console.error(`esim: live price lookup failed for ${plan.id} (proceeding on cached):`, e);
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
  const beginRes = begun as { status?: string; order_id?: string } | null;
  if (beginRes?.status === "insufficient") {
    return json({ error: "insufficient_credits", needed: cost }, { status: 402 });
  }
  if (beginRes?.status === "duplicate") {
    // An identical purchase is already in flight for this user+plan.
    return json({ error: "duplicate_request" }, { status: 409 });
  }
  const orderId = beginRes?.order_id;
  if (!orderId) {
    return json({ error: "spend_failed" }, { status: 500 });
  }

  /** Close the reserved row and return the credits, claim-gated so a
   *  concurrent closer cannot cause a double refund (the create-order bug). */
  const failEsim = async (reason: string) => {
    const { data: claimed } = await sb
      .from("esim_orders")
      .update({ status: "canceled", updated_at: new Date().toISOString() })
      .eq("id", orderId)
      .eq("status", "provisioning")
      .select("id");
    if (!claimed || claimed.length === 0) return;
    await sb.rpc("wallet_credit", {
      p_user: userId, p_amount: cost, p_reason: "refund",
    });
    console.warn(`create-esim-order failed plan=${plan.id} reason=${reason} order=${orderId}`);
  };

  const buy = await esimPurchase(plan.id);
  if (!buy.ok || !buy.transactionId) {
    await failEsim(buy.errorType ?? "purchase_failed");
    // Classify, don't echo. buy.error is SMSPool's own prose, which matches no
    // case in APIError and fell through to "Something went wrong on our side"
    // — blaming our infrastructure for SMSPool being out of stock, the exact
    // bug the provider_unreachable rename fixed for SMS.
    const code = buy.errorType === "OUT_OF_STOCK"
      ? "esim_out_of_stock"
      : buy.errorType === "AUTH_ERROR" || buy.errorType === "BALANCE_ERROR"
      ? "provider_unreachable"
      : "esim_purchase_failed";
    return json({ error: code }, { status: 503 });
  }

  // Fetch the QR/activation profile (best-effort; a provisioning eSIM can be
  // re-fetched later via check-esim-usage).
  let profile = null as Awaited<ReturnType<typeof esimProfile>> | null;
  try { profile = await esimProfile(buy.transactionId); } catch { /* keep provisioning */ }

  const { data: order, error: insErr } = await sb
    .from("esim_orders")
    .insert({
      user_id: userId,
      plan_id: plan.id,
      smspool_tx: buy.transactionId,
      cost_credits: cost,
      // The FRESH quote when we have one. This column previously echoed the
      // cached catalog price, which made it useless as a cost record — margin
      // analysis over it was circular and could never reveal drift.
      actual_cost_cents: liveCostUsd != null
        ? Math.round(liveCostUsd * 100)
        : plan.last_cost_cents,
      status: profile?.ok ? "installed" : "provisioning",
      activation_code: profile?.activationCode ?? null,
      smdp_address: profile?.smdp ?? null,
      matching_id: profile?.matchingId ?? null,
      apn: profile?.apn ?? null,
      sim_pin: profile?.pin ?? null,
      sim_puk: profile?.puk ?? null,
      data_total_mb: profile?.dataTotalMb ?? null,
      data_used_mb: profile?.dataUsedMb ?? null,
      activated: profile?.activated ?? false,
    })
    .select("*").single();

  if (insErr || !order) {
    // The eSIM is already provisioned at SMSPool (can't un-buy). Make the user
    // whole; we eat the wholesale cost on this rare failure.
    await refund();
    return json({ error: "order_persist_failed", detail: insErr?.message }, { status: 500 });
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
