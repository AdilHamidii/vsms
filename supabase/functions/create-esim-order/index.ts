// Buy an eSIM data plan: charge credits up-front, purchase at SMSPool, fetch the
// activation profile (QR/LPA + usage), persist. No provider fallback and no
// 20-min auto-refund — an eSIM is a one-shot provisioned profile.

import { handleCors, json } from "../_shared/cors.ts";
import { notifySafe, esc } from "../_shared/telegram.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import { esimPurchase, esimProfile } from "../_shared/smspool.ts";

interface Body { plan_id: string; }

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
    .select("id, retail_credits, status, last_cost_cents")
    .eq("id", body.plan_id).single();
  if (pErr || !plan) return json({ error: "unknown_plan" }, { status: 404 });
  if (plan.status !== "active" || plan.retail_credits == null) {
    return json({ error: "plan_unavailable" }, { status: 409 });
  }
  const cost = plan.retail_credits as number;

  const { data: spent, error: spendErr } = await sb.rpc("wallet_spend", {
    p_user: userId, p_amount: cost, p_reason: "spend",
  });
  if (spendErr) return json({ error: "spend_failed", detail: spendErr.message }, { status: 500 });
  if (spent === false) return json({ error: "insufficient_credits", needed: cost }, { status: 402 });

  const refund = () => sb.rpc("wallet_credit", { p_user: userId, p_amount: cost, p_reason: "refund" });

  const buy = await esimPurchase(plan.id);
  if (!buy.ok || !buy.transactionId) {
    await refund();
    return json({ error: buy.error ?? "esim_purchase_failed" }, { status: 503 });
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
      actual_cost_cents: plan.last_cost_cents,
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
