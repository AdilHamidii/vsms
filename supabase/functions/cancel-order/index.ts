import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import { markSuccess, poll, release, type Provider } from "../_shared/providers.ts";

// Minimum hold before a paid order may be destroyed (owner decision
// 2026-07-27). Measured: median code arrival 58s, p90 134s, while the median
// CANCEL lands at 57s — users were killing orders one second before the
// typical code. 120s covers the bulk of the arrival distribution without
// running to the full 8-minute expiry.
//
// Applies to reroll as well as the ✕: a reroll releases the number exactly
// like a cancel, so an early reroll throws away an in-flight code just the
// same.
const MIN_HOLD_SECONDS = 120;

// `enforce_min_hold` is sent ONLY by clients that know about the rule.
//
// It is opt-in for a specific, non-obvious reason. Shipped 1.4's
// `rerollNumber` does `if let server = try? await orders.cancel(...)` and then
// creates the replacement order **regardless of whether the cancel
// succeeded**. Enforcing unconditionally would therefore leave the original
// order `waiting` AND charge for a second one — a double charge on the live
// install base. So the server refuses early cancels only for clients that also
// abort the reroll on failure and hide the button until the hold elapses.
// Remove the flag once 1.4 is off the field.
interface Body { order_id: string; enforce_min_hold?: boolean; }

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
    .select("id, user_id, status, cost_credits, provider, smspva_id, created_at")
    .eq("id", body.order_id)
    .eq("user_id", userId)
    .single();
  if (oErr || !order) return json({ error: "order_not_found" }, { status: 404 });
  if (order.status !== "waiting") {
    return json({ error: "not_cancelable", current_status: order.status }, { status: 409 });
  }

  // Minimum-hold gate. Checked BEFORE the last-chance provider poll below —
  // if we aren't going to release the number there is no reason to spend a
  // provider round-trip on it.
  //
  // 429 (not 409) is deliberate: shipped 1.4 has no case for this error code
  // and falls back on HTTP status, where 429 reads "You're going a bit fast —
  // please wait a moment and try again." That is very nearly the right message
  // by accident, whereas 409's "Not available right now" would be misleading.
  // Newer clients read `retry_after_seconds` and render an exact countdown.
  if (body.enforce_min_hold) {
    const heldSeconds = (Date.now() - new Date(order.created_at as string).getTime()) / 1000;
    if (heldSeconds < MIN_HOLD_SECONDS) {
      return json({
        error: "cancel_too_early",
        retry_after_seconds: Math.max(1, Math.ceil(MIN_HOLD_SECONDS - heldSeconds)),
      }, { status: 429 });
    }
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
    // Lost the flip because the code landed between our poll above and here
    // (the minutely cron can claim it too). Hand the code over rather than
    // erroring: the user asked to cancel, but what they actually wanted was
    // the code, and they have already paid for this one.
    if (current?.status === "received") {
      return json({ order: current, arrived: true });
    }
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
