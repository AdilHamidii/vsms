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

  const patch: Record<string, unknown> = {
    provider_status: act.status,
    updated_at: new Date().toISOString(),
  };
  if (next.code) {
    patch.code = next.code;
    patch.raw_message = act.message ?? null;
  }
  if (next.status !== "waiting") {
    patch.status = next.status;
    patch.closed_at = new Date().toISOString();
  }

  // Atomic claim. Every status write in this codebase is gated on the row still
  // being live — the one place that skipped it could hand a user a working code
  // they had already been refunded for.
  const { data: claimed, error: upErr } = await sb
    .from("email_orders").update(patch)
    .eq("id", order.id).eq("status", "waiting")
    .select("*").maybeSingle();
  if (upErr) {
    console.error(`check-email-order: update failed order=${order.id}: ${upErr.message}`);
    return json({ order });
  }
  if (!claimed) return json({ order });   // the cron closed it first — it wins

  // Refund a PAID activation that ended without a code. Free ones have nothing
  // to give back. `code is not null` is the test, never status.
  if (!claimed.code && claimed.status !== "waiting" && (claimed.cost_credits ?? 0) > 0) {
    const { error: refundErr } = await sb.rpc("wallet_move_email", {
      p_user: userId, p_amount: claimed.cost_credits,
      p_reason: "refund", p_email_order: claimed.id,
    });
    if (refundErr) {
      console.error(
        `check-email-order: REFUND FAILED order=${claimed.id} user=${userId} ` +
        `credits=${claimed.cost_credits}: ${refundErr.message}`,
      );
    }
  }

  return json({ order: claimed });
});
