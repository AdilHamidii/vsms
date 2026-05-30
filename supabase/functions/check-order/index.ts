import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import { getSms, isOk } from "../_shared/smspva.ts";

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
    .select("id, user_id, status, otp, smspva_id, smspva_number, expires_at")
    .eq("id", body.order_id)
    .eq("user_id", userId)
    .single();
  if (oErr || !order) return json({ error: "order_not_found" }, { status: 404 });

  if (order.status !== "waiting") {
    return json({ order });
  }

  if (new Date(order.expires_at) <= new Date()) {
    await sb.rpc("expire_order", { p_order: order.id });
    const { data: updated } = await sb.from("orders").select("*").eq("id", order.id).single();
    return json({ order: updated });
  }

  let resp;
  try {
    resp = await getSms(order.smspva_id!);
  } catch (e) {
    return json({ error: "smspva_unreachable", detail: String(e) }, { status: 502 });
  }

  if (isOk(resp) && resp.data.sms?.code) {
    const { data: updated, error: uErr } = await sb
      .from("orders")
      .update({
        status: "received",
        otp: resp.data.sms.code,
        raw_message: resp.data.sms.fullText ?? null,
        arrived_at: new Date().toISOString(),
        closed_at: new Date().toISOString(),
      })
      .eq("id", order.id)
      .select("*").single();
    if (uErr) return json({ error: "update_failed", detail: uErr.message }, { status: 500 });
    return json({ order: updated, arrived: true });
  }

  const { data: current } = await sb.from("orders").select("*").eq("id", order.id).single();
  return json({ order: current });
});
