import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
// `release` is deliberately gone: cancel no longer kills the number — the
// late-code sweep in poll-active-orders owns its lifecycle now.
import { markSuccess, poll, type OrderProvider } from "../_shared/providers.ts";

// Minimum hold before a paid order may be destroyed (owner decision
// 2026-07-27). Measured: median code arrival 58s, p90 134s, while the median
// CANCEL lands at 57s — users were killing orders one second before the
// typical code. 180s (owner decision) sits above p90 arrival (134s), so
// virtually every code that was ever going to land has landed by then, while
// still leaving 5 minutes of the 8-minute window.
//
// Applies to reroll as well as the ✕: a reroll releases the number exactly
// like a cancel, so an early reroll throws away an in-flight code just the
// same.
const MIN_HOLD_SECONDS = 180;

// Grace during which an order that has NOT yet been given a number cannot be
// cancelled at all — see the unconditional guard below. Sized to create-order's
// worst-case provider phase (30s buy timeout + operator price lookup + up to
// two duplicate-number redraws), NOT to user behaviour: no legitimate client
// can see such an order, because create-order only returns once the number
// exists.
const PRE_RESERVATION_GRACE_MS = 90_000;

// The hold is now enforced for EVERY client (2026-08-01). `enforce_min_hold` is
// still accepted so existing callers keep working, but it no longer gates
// anything.
//
// It was opt-in because pre-1.6 `rerollNumber` does
// `if let server = try? await orders.cancel(...)` and creates the replacement
// REGARDLESS of whether the cancel succeeded — so enforcing for everyone would
// leave the original `waiting` AND charge for a second order.
//
// Two measurements retired that objection:
//
//  1. `begin_order` deduped on (user, service, country, tier) already, so a
//     same-country reroll was ALWAYS protected. Only a different-country reroll
//     slipped through: 7 in 30 days across 3 users. `20260801100000` drops
//     country from that predicate, closing it.
//  2. Pre-1.6 `cancelWaiting` sets `flow = nil` in its catch — so a refused
//     cancel still LEAVES the waiting screen while the order keeps running.
//     That is precisely the non-destructive ✕ that 1.6 introduced, so old
//     clients get the behaviour for free, and a delivered code still reaches
//     them by push.
//
// Why this could not wait for adoption: over 30 days 87 of 147 numbered orders
// (59%) were cancelled by the user and delivered 1.1%, against ~73% for orders
// left alone. The hold is the single largest lever on delivery, and gating it
// on client version left it switched off for essentially the whole install
// base — 20 of 22 cancels in one 48h sample were under 180s, one at 4 seconds.
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
    .select("id, user_id, status, cost_credits, provider, smspva_id, created_at, expires_at")
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
  {
    const heldSeconds = (Date.now() - new Date(order.created_at as string).getTime()) / 1000;
    if (heldSeconds < MIN_HOLD_SECONDS) {
      return json({
        error: "cancel_too_early",
        retry_after_seconds: Math.max(1, Math.ceil(MIN_HOLD_SECONDS - heldSeconds)),
      }, { status: 429 });
    }
  }

  // A cancel BEFORE the number exists is refused unconditionally — the
  // enforce_min_hold flag does not gate this one.
  //
  // begin_order commits the 'waiting' row and the charge before the provider
  // loop runs, and RLS makes that row readable over PostgREST immediately. So a
  // script can create an order, poll /rest/v1/orders until the id appears
  // (sub-second), and cancel while smspva_id is still null. Three things then
  // compose against us: the refund lands in full, `late_watch_until` is set to
  // null because there is no number yet (so the rescue sweep never revisits the
  // row), and create-order — finishing its reservation moments later — loses
  // the status claim and calls release() milliseconds after the buy, inside
  // HeroSMS's ~2-minute EARLY_CANCEL_DENIED window. heroRelease logs that as
  // "retryable, wholesale forfeited for now" and nothing retries it. Net: the
  // caller pays nothing and we forfeit $0.10-$7.50 per cycle against a live
  // provider balance of ~$10.
  //
  // Gating this on enforce_min_hold would leave it wide open, since the flag is
  // client-supplied. Doing it unconditionally is safe for shipped 1.4/1.5:
  // those builds only ever cancel an order they are already displaying a number
  // for (both the ✕ and reroll act on a live number, and resumeInFlightOrder
  // restores only orders that have one), so a legitimate client cannot reach
  // this branch. The 90s window covers create-order's worst case — a 30s buy
  // timeout plus an operator-rotation price lookup plus up to two duplicate
  // redraws — and a genuinely stranded row is still closed and refunded by the
  // minutely expiry sweep.
  if (!order.smspva_id) {
    const ageMs = Date.now() - new Date(order.created_at as string).getTime();
    if (ageMs < PRE_RESERVATION_GRACE_MS) {
      return json({
        error: "cancel_too_early",
        retry_after_seconds: Math.max(1, Math.ceil((PRE_RESERVATION_GRACE_MS - ageMs) / 1000)),
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
      const last = await poll((order.provider ?? "smspva") as OrderProvider, order.smspva_id);
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
          await markSuccess((order.provider ?? "smspva") as OrderProvider, order.smspva_id);
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
  // late_watch_until keeps the number alive after the cancel — see below.
  const { data: claimed, error: uErr } = await sb
    .from("orders")
    .update({
      status: "canceled",
      closed_at: new Date().toISOString(),
      late_watch_until: order.smspva_id ? order.expires_at : null,
    })
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

  // We won the flip — refund immediately. Check the result: supabase-js returns
  // errors rather than throwing, and wallet_credit RAISES on a non-positive
  // amount or a missing wallet row. Discarding it meant the claim committed,
  // the money never moved, and the user was told they'd been refunded.
  const { error: refundErr } = await sb.rpc("wallet_credit", {
    p_user: userId, p_amount: order.cost_credits, p_reason: "refund", p_order: order.id,
  });
  if (refundErr) {
    // Roll the claim BACK to waiting. The flip to 'canceled' has already
    // committed, and every recovery path (the expiry sweep, this function)
    // requires status='waiting' — so returning here left the order terminal and
    // PERMANENTLY unrefundable, with the loss visible only in this log line.
    // Restoring it lets the expiry sweep close and refund it a minute later.
    console.error(`cancel-order: REFUND FAILED for ${order.id} user=${userId} ` +
                  `credits=${order.cost_credits}: ${refundErr.message} — reverting to waiting`);
    await sb.from("orders")
      .update({ status: "waiting", closed_at: null, late_watch_until: null })
      .eq("id", order.id)
      .eq("status", "canceled");
    return json({ error: "refund_failed" }, { status: 500 });
  }

  // Deliberately NOT releasing the number.
  //
  // release() reclaims the wholesale cost but kills the number, so a code
  // arriving seconds later is lost — and cancels (median 57s) land one second
  // before the median code (58s). We now keep watching until the original
  // reservation deadline; poll-active-orders hands over any late code for free
  // and releases the number once the window closes. Owner decision 2026-07-27:
  // the giveaway is worth it, because 92% of users who ever receive a code go
  // on to purchase, against at most $3.50 of forfeited wholesale.
  return json({ order: claimed[0] });
});
