import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
// `release` is deliberately gone: cancel no longer kills the number — the
// late-code sweep in poll-active-orders owns its lifecycle now.
import { markSuccess, poll, type OrderProvider } from "../_shared/providers.ts";

// Minimum hold before a paid order may be destroyed.
//
// 180s -> 90s (owner decision 2026-08-03). The original 180 was set against
// SMSPVA's arrival curve when SMSPVA served everything. HeroSMS, which now
// serves most volume, has a far tighter one — measured over 90 days on orders
// that actually held a number:
//
//     arrival   p50   p90   max
//     herosms    28    86    86
//     smspva     58   145   337
//
// and, conditioning on "no code yet at T", the share that still delivered:
//
//     T        herosms          smspva
//     60s      2 of 26 (7.7%)   20 of 71 (28.2%)
//     90s      0 of 21 (0.0%)   14 of 54 (25.9%)
//     180s     0 of 17 (0.0%)    3 of 32 ( 9.4%)
//
// On HeroSMS no code has EVER arrived after 86s, so everything between 90s and
// 180s was provably dead time — the user sat watching a spent number while the
// hold refused to let them move on.
//
// ⚠️ THE COST IS ON SMSPVA, AND IT IS REAL: 26% of SMSPVA orders still alive at
// 90s went on to deliver. Users cancel as soon as they are allowed (the median
// cancel tracked the hold exactly: 40s before it existed, 221s after), so this
// will cut into that tail. The right shape is a PER-PROVIDER hold — ~90s for
// HeroSMS, ~180s for SMSPVA — resolved from the order's provider. Left flat for
// now because the owner asked for 90s; make it per-provider before concluding
// anything from a change in SMSPVA delivery.
//
// Applies to reroll as well as the ✕: a reroll releases the number exactly
// like a cancel, so an early reroll throws away an in-flight code just the
// same.
//
// NOTE this is now EQUAL to PRE_RESERVATION_GRACE_MS rather than 2x it, so the
// numberless-cancel guard below is no longer subsumed — it is coincident, and
// still the backstop if this ever drops under 90s. Do not remove it.
// ── THE HOLD IS NOW PER-PROVIDER (2026-08-18) ────────────────────────────────
//
// This is the shape the note above asked for, and it became implementable the
// moment SMSPVA was retired: the two providers that actually serve orders now
// have arrival curves so different that one flat number is wrong for both.
//
// Re-measured over every code the account has ever delivered, by provider:
//
//     provider   codes   p50    p90    max    arrived after 90s
//     5sim         32     50s   155s   324s   6 of 32
//     herosms       8     42s    79s    86s   0 of 8
//
// So 90s is already generous for HeroSMS — no code has EVER arrived after 86s,
// and everything past that is provably dead time the user spends watching a
// spent number. On 5sim the p90 is 155s, so a flat 90s cuts the tail off the
// provider serving 7,769 of 8,988 active routes.
//
// A flat 150s was considered and REJECTED: it buys ~2 extra 5sim codes (only 2
// of 32 land in the 90–150s window; 4 of the 6 late ones arrive after 150s
// anyway) at the cost of trapping every HeroSMS user for 60s with nothing
// coming. That trade is what made the old 180s hold a problem — users could
// not leave the screen to go and paste the number.
//
// ⚠️ RAISING A HOLD IS NOT FREE, AND THE COST IS NOT THE CODE. Since
// 2026-07-27 a cancel does NOT release the number: it refunds, stamps
// `late_watch_until`, and `poll-active-orders` still delivers a late code for
// free. So the hold does not protect the CODE from a cancel — it protects it
// from a REROLL, which does release. Do not justify a longer hold with
// "otherwise the code is lost"; that stopped being true.
//
// The fallback is the SHORT one on purpose: an unknown provider should not be
// able to trap a user, and 90s is already above every measured p50.
//
// 🔴 5sim IS 90 FOR NOW, NOT ITS p90 OF 155 — AND THIS IS THE CLIENT'S FAULT,
// NOT THE DATA'S. `WaitingScreen.minHoldSeconds` is a HARDCODED 90 in shipped
// 2.0, so raising the server past it unlocks a Cancel button the server then
// refuses: the tap returns 429, and the copy quotes a THIRD number ("three
// minutes") that matches neither constant. Measured 2026-08-18: 13 of the last
// 29 5sim cancels landed in exactly that 85–158s gap — nearly half of them
// would have hit a button that appears, is tapped, and fails.
//
// The file's own invariant says it: the client may only ever be RAISED ahead
// of the server, never lowered behind it. So the server waits for the client.
// Raise this to 155 in the SAME release that (a) makes WaitingScreen read a
// per-provider hold and (b) makes the 429 copy use `retry_after_seconds`
// instead of a literal. Cost of waiting: ~2 late 5sim codes a month (2 of 32
// ever landed in 90–155s), which is small; a broken button on 45% of cancels
// is not.
const MIN_HOLD_BY_PROVIDER: Record<string, number> = {
  "5sim": 90,       // p90 is 155 — raise WITH the client, see above
  herosms: 90,      // max arrival ever observed is 86s
  smspva: 90,       // retired from routing; kept so an in-flight row resolves
};
const MIN_HOLD_FALLBACK = 90;

function minHoldFor(provider: string | null | undefined): number {
  return MIN_HOLD_BY_PROVIDER[provider ?? ""] ?? MIN_HOLD_FALLBACK;
}

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
    const minHold = minHoldFor(order.provider as string | null);
    if (heldSeconds < minHold) {
      return json({
        error: "cancel_too_early",
        retry_after_seconds: Math.max(1, Math.ceil(minHold - heldSeconds)),
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
        const { data: got, error: rescueErr } = await sb
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
        // 🔴 DESTRUCTURE THE ERROR. supabase-js RETURNS errors, it does not
        // throw — so `const { data: got }` alone makes a failed write
        // indistinguishable from "lost the race", which is the one case this
        // branch is allowed to fall through on. The code is already AT the
        // provider at this point, so falling through would: discard it with no
        // log and no page, refund the user seconds before the thing they paid
        // for, skip `markSuccess` (earning the provider's harshest karma
        // penalty for an SMS that arrived and was never fetched), and score the
        // route as a delivery failure it did not earn.
        //
        // Fail LOUD instead of cancelling. A 500 leaves the row `waiting`, so
        // the code is still recoverable — `poll-active-orders` sweeps waiting
        // orders every minute and `check-order` will hand it over on the next
        // poll. The user taps cancel again at worst; they do not lose the code.
        // `check-order:76` writes this identical statement and has always
        // destructured it; this is the same shape, made to match.
        if (rescueErr) {
          console.error(JSON.stringify({
            alert: "cancel_order_rescue_write_failed",
            order: order.id,
            detail: rescueErr.message,
          }));
          return json({ error: "update_failed", detail: rescueErr.message }, { status: 500 });
        }
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
  // ONE TRANSACTION. The claim and the refund used to be two round-trips with a
  // TypeScript rollback between them, which is exactly the shape this repo's
  // money rule forbids: a worker killed in the gap leaves a TERMINAL row with
  // the charge never returned, and every recovery path selects status='waiting'
  // so nothing revisits it. A TS rollback cannot cover that — the process is
  // gone. Seven other close paths were migrated to claim functions; this was
  // the eighth and was missed. Inside cancel_order_claim a failing wallet_credit
  // RAISES and takes the status flip down with it, so the order stays
  // cancellable instead of stranding the money.
  const { data: didClaim, error: uErr } = await sb.rpc("cancel_order_claim", {
    p_order: order.id,
    p_late_watch_until: order.smspva_id ? order.expires_at : null,
  });
  if (uErr) return json({ error: "update_failed", detail: uErr.message }, { status: 500 });
  if (didClaim !== true) {
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

  // The refund already happened, in the same transaction as the flip above.
  // Re-read the row so the client gets the post-cancel state it renders.
  const { data: claimedRow } = await sb
    .from("orders").select("*").eq("id", order.id).maybeSingle();

  // Deliberately NOT releasing the number.
  //
  // release() reclaims the wholesale cost but kills the number, so a code
  // arriving seconds later is lost — and cancels (median 57s) land one second
  // before the median code (58s). We now keep watching until the original
  // reservation deadline; poll-active-orders hands over any late code for free
  // and releases the number once the window closes. Owner decision 2026-07-27:
  // the giveaway is worth it, because 92% of users who ever receive a code go
  // on to purchase, against at most $3.50 of forfeited wholesale.
  return json({ order: claimedRow ?? order });
});
