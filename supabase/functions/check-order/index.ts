import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import { markDead, markSuccess, poll, type OrderProvider } from "../_shared/providers.ts";

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
    // select("*"), not a column list. The terminal-status branch below returns
    // THIS row to the client, and ServerOrder requires service_id, country_id,
    // cost_credits and created_at — none of which were selected, so decoding
    // threw. pollActiveOrder counts that as a poll failure and needs two
    // consecutive before falling back to the authoritative fetch(), so at a 4s
    // cadence the user sat ~8s on "Waiting" for an order that had already ended
    // and refunded — the reconcile invariant re-entering by a different door.
    .select("*")
    .eq("id", body.order_id)
    .eq("user_id", userId)
    .single();
  if (oErr || !order) return json({ error: "order_not_found" }, { status: 404 });

  if (order.status !== "waiting") {
    return json({ order });
  }

  if (new Date(order.expires_at) <= new Date()) {
    await sb.rpc("expire_order", { p_order: order.id });
    // expire_order is plain SQL and cannot talk to the provider — ban + close
    // the dead number here so SMSPVA doesn't re-issue it (their docs require
    // the ban; the request id is otherwise retained ~10 min). Best-effort.
    if (order.smspva_id) {
      await markDead((order.provider ?? "smspva") as OrderProvider, order.smspva_id);
    }
    const { data: updated } = await sb.from("orders").select("*").eq("id", order.id).single();
    return json({ order: updated });
  }

  let result;
  try {
    result = await poll((order.provider ?? "smspva") as OrderProvider, order.smspva_id!);
  } catch (e) {
    return json({ error: "provider_unreachable", detail: String(e) }, { status: 502 });
  }

  if (result.state === "received" && result.code) {
    // ATOMIC CLAIM — .eq("status","waiting") is load-bearing, not decoration.
    //
    // We read this order as "waiting", then spent a network round trip polling
    // the provider. The poll-active-orders cron runs every 60s and can, in that
    // window, independently expire this same order: claim it, refund the
    // credits, and push "no code arrived". Without the guard, this update then
    // overwrites that terminal state back to "received" with a valid OTP — the
    // user keeps the refund AND gets a working code. That is the only path in
    // the lifecycle that could hand out a number for free, and it was the one
    // status write here missing the guard that every other branch has,
    // including the expired/canceled branch directly below.
    const { data: rows, error: uErr } = await sb
      .from("orders")
      .update({
        status: "received",
        otp: result.code,
        raw_message: result.fullText ?? null,
        arrived_at: new Date().toISOString(),
        closed_at: new Date().toISOString(),
      })
      .eq("id", order.id)
      .eq("status", "waiting")
      .select("*");
    if (uErr) return json({ error: "update_failed", detail: uErr.message }, { status: 500 });

    if (rows && rows.length > 0) {
      // Tell SMSPVA the activation succeeded — best-effort account-karma
      // hygiene, never blocks handing the code to the user.
      await markSuccess((order.provider ?? "smspva") as OrderProvider, order.smspva_id!);
      return json({ order: rows[0], arrived: true });
    }

    // Lost the race: something already closed this order. The refund stands and
    // we deliberately do NOT resurrect it — the user has their credits back and
    // can order again. Worth logging: a code arriving after we gave up means
    // the expiry window is too aggressive for this route.
    console.warn(
      `check-order: code arrived for ${order.id} AFTER it was closed — ` +
      `refund stands, code discarded. Expiry may be too short for this route.`,
    );
    const { data: closed } = await sb.from("orders").select("*").eq("id", order.id).single();
    return json({ order: closed, arrived: false, closed: true });
  }

  // The provider has already closed this order (refunded / cancelled / expired
  // on their side). We used to compute that state and then ignore it, leaving
  // the order "waiting" until our own timer — the user stared at a number that
  // was already dead. Close it now and return the credits.
  if (result.state === "expired" || result.state === "canceled") {
    const { data: claimed } = await sb
      .from("orders")
      .update({ status: "expired", closed_at: new Date().toISOString() })
      .eq("id", order.id)
      .eq("status", "waiting")
      .select("id, cost_credits");
    if (claimed && claimed.length > 0) {
      // Same guard as cancel-order and poll-active-orders. A discarded error
      // here leaves the order claimed to 'expired' with the money never moved —
      // and this is the "Check now" path, which must never dead-end silently.
      const { error: refundErr } = await sb.rpc("wallet_credit", {
        p_user: userId, p_amount: claimed[0].cost_credits,
        p_reason: "refund", p_order: order.id,
      });
      if (refundErr) {
        console.error(`check-order: REFUND FAILED order=${order.id} user=${userId} ` +
                      `credits=${claimed[0].cost_credits}: ${refundErr.message} — reverting to waiting`);
        await sb.from("orders")
          .update({ status: "waiting", closed_at: null })
          .eq("id", order.id).eq("status", "expired");
        return json({ error: "refund_failed" }, { status: 500 });
      }
    }
    const { data: fresh } = await sb.from("orders").select("*").eq("id", order.id).single();
    return json({ order: fresh, arrived: false, closed: true });
  }

  const { data: current } = await sb.from("orders").select("*").eq("id", order.id).single();
  return json({ order: current });
});
