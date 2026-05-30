import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import { cancelOrder } from "../_shared/smspva.ts";

interface Body { order_id: string; }

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, { status: 405 });

  const userId = await callerUserId(req);
  if (!userId) return json({ error: "unauthorized" }, { status: 401 });

  let body: Body;
  try { body = await req.json(); }
  catch { return json({ error: "invalid_body" }, { status: 400 }); }
  if (!body.order_id) return json({ error: "missing_fields" }, { status: 400 });

  const sb = admin();

  const { data: order, error: oErr } = await sb
    .from("orders")
    .select("id, user_id, status, cost_credits, smspva_id")
    .eq("id", body.order_id)
    .eq("user_id", userId)
    .single();
  if (oErr || !order) return json({ error: "order_not_found" }, { status: 404 });
  if (order.status !== "waiting") {
    return json({ error: "not_cancelable", current_status: order.status }, { status: 409 });
  }

  // Best-effort cancel at SMSPVA — we refund regardless so the user doesn't
  // lose credits when SMSPVA is degraded.
  try {
    if (order.smspva_id) await cancelOrder(order.smspva_id);
  } catch (e) {
    console.error("SMSPVA cancelorder failed (continuing with refund):", e);
  }

  await sb.rpc("wallet_credit", {
    p_user: userId, p_amount: order.cost_credits, p_reason: "refund", p_order: order.id,
  });

  const { data: updated, error: uErr } = await sb
    .from("orders")
    .update({ status: "canceled", closed_at: new Date().toISOString() })
    .eq("id", order.id)
    .select("*").single();
  if (uErr) return json({ error: "update_failed", detail: uErr.message }, { status: 500 });

  return json({ order: updated });
});
