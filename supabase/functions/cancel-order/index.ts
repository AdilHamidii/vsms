import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import { markSuccess, poll, release, type Provider } from "../_shared/providers.ts";

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
    .select("id, user_id, status, cost_credits, provider, smspva_id")
    .eq("id", body.order_id)
    .eq("user_id", userId)
    .single();
  if (oErr || !order) return json({ error: "order_not_found" }, { status: 404 });
  if (order.status !== "waiting") {
    return json({ error: "not_cancelable", current_status: order.status }, { status: 409 });
  }

  // Last-chance poll before releasing the number: median delivery (53s) and
  // median cancel (58s) sit five seconds apart, so cancels routinely race a
  // code that is ALREADY at the provider. One extra round-trip turns
  // "cancel" into "cancel unless the code just arrived" — the user gets the
  // thing they paid for instead of a refund, and we dodge SMSPVA's harshest
  // karma penalty (-0.5 for an SMS that arrived but was never fetched).
  // Best-effort: any poll failure falls through to the normal cancel.
  if (order.smspva_id) {
    try {
      const last = await poll((order.provider ?? "smspva") as Provider, order.smspva_id);
      if (last.state === "received" && last.code) {
        const { data: got } = await sb
          .from("orders")
          .update({
            status: "received",
            otp: last.code,
            raw_message: last.fullText ?? null,
            arrived_at: new Date().toISOString(),
            closed_at: new Date().toISOString(),
          })
          .eq("id", order.id)
          .eq("status", "waiting")
          .select("*");
        if (got && got.length > 0) {
          await markSuccess((order.provider ?? "smspva") as Provider, order.smspva_id);
          console.warn(`cancel-order: code was in flight for ${order.id} — delivered instead of canceled`);
          return json({ order: got[0], arrived: true });
        }
      }
    } catch { /* fall through to the normal cancel */ }
  }

  // Atomically claim the cancel: flip waiting -> canceled ONLY if it's still
  // waiting. If a code landed (or it expired) in the race window, this matches
  // 0 rows and we must NOT refund — otherwise a well-timed cancel could pocket
  // the delivered code AND get the credits back.
  const { data: claimed, error: uErr } = await sb
    .from("orders")
    .update({ status: "canceled", closed_at: new Date().toISOString() })
    .eq("id", order.id)
    .eq("status", "waiting")
    .select("*");
  if (uErr) return json({ error: "update_failed", detail: uErr.message }, { status: 500 });
  if (!claimed || claimed.length === 0) {
    const { data: current } = await sb.from("orders").select("*").eq("id", order.id).single();
    return json({ error: "not_cancelable", current_status: current?.status }, { status: 409 });
  }

  // We won the flip — now it's safe to refund and best-effort release the number
  // at its provider (virtualsms enforces a 2-min hold; a failed release there
  // just means we eat the number, but the user is still made whole).
  await sb.rpc("wallet_credit", {
    p_user: userId, p_amount: order.cost_credits, p_reason: "refund", p_order: order.id,
  });
  if (order.smspva_id) {
    await release((order.provider ?? "smspva") as Provider, order.smspva_id);
  }

  return json({ order: claimed[0] });
});
