// Refresh one email activation from the provider.
//
// Same reconcile invariant as the SMS side: **the DB row is the authority on
// whether an order ended**, never the provider. A provider that is sick is
// exactly when you most need an answer and least able to get one, so a failed
// provider read returns the stored row rather than an error the client will
// swallow into an endless "waiting".

import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import { getActivation, faultOf } from "../_shared/heromail.ts";
import { mapProviderStatus, EMAIL_WINDOW_SECONDS } from "../_shared/emailStatus.ts";

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

  // Scoped to the caller: the service role bypasses RLS, so the ownership check
  // has to be explicit here or any user could read any activation.
  const { data: order, error: readErr } = await sb
    .from("email_orders").select("*")
    .eq("id", body.order_id).eq("user_id", userId).maybeSingle();
  if (readErr) {
    console.error(`check-email-order: read failed: ${readErr.message}`);
    return json({ error: "order_lookup_failed" }, { status: 500 });
  }
  if (!order) return json({ error: "unknown_order" }, { status: 404 });

  // Already ended, or never got an address — nothing to ask the provider.
  if (order.status !== "waiting" || !order.provider_id) {
    return json({ order });
  }

  const live = await getActivation(order.provider_id);
  const fault = faultOf(live);
  if (fault) {
    // Do NOT invent a terminal state. Hand back what we know; the cron sweep
    // owns expiry, so a flaky provider cannot strand this row.
    console.error(
      `check-email-order: provider read failed order=${order.id} ` +
      `${fault.title}: ${fault.message}`,
    );
    return json({ order });
  }

  const act = live as Exclude<typeof live, { ok: false }>;
  const next = mapProviderStatus(act.status, act.value, order.created_at, EMAIL_WINDOW_SECONDS);

  // Nothing to write: still waiting and no code. Keep the row untouched so
  // `updated_at` stays meaningful.
  if (next.status === "waiting" && !next.code) {
    if (act.status !== order.provider_status) {
      await sb.from("email_orders")
        .update({ provider_status: act.status, updated_at: new Date().toISOString() })
        .eq("id", order.id).eq("status", "waiting");
    }
    return json({ order: { ...order, provider_status: act.status } });
  }

  // Atomic write-and-refund. close_email_order_claim locks the row, re-checks
  // 'waiting' (every status write in this codebase is gated on the row still
  // being live — the one place that skipped it could hand a user a working
  // code they had already been refunded for), records the code/provider
  // status, and refunds a PAID codeless terminal row in the SAME transaction.
  // The old patch-then-refund pair could strand a terminal row with the money
  // kept when the worker died between the two round-trips.
  const { data: didWrite, error: closeErr } = await sb.rpc("close_email_order_claim", {
    p_order: order.id,
    p_status: next.status,
    p_code: next.code ?? null,
    p_raw: next.code ? (act.message ?? null) : null,
    p_provider_status: act.status ?? null,
  });
  if (closeErr) {
    console.error(`check-email-order: close failed order=${order.id}: ${closeErr.message}`);
    return json({ order });
  }
  if (!didWrite) return json({ order });   // the cron closed it first — it wins

  const { data: fresh } = await sb
    .from("email_orders").select("*").eq("id", order.id).maybeSingle();
  return json({ order: fresh ?? order });
});
