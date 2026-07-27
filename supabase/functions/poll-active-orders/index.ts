// Called by pg_cron every minute. Auto-expires overdue orders (refund + notify),
// then polls the provider for incoming SMS on the rest, persisting OTPs and
// dispatching push notifications.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import { markDead, markSuccess, poll, type Provider } from "../_shared/providers.ts";
import { getBalanceUsd } from "../_shared/smspool.ts";
import { getBalance as getSmspvaBalance, isOk } from "../_shared/smspva.ts";
import { sendPush } from "../_shared/apns.ts";
import { notifySafe } from "../_shared/telegram.ts";

// The most a single order can cost us, in dollars — MUST track
// MAX_WHOLESALE_CENTS in sync-prices (750 as of 2026-07-27).
//
// This ladder used to be a hard-coded [20, 10, 5, 1] justified as "5x the
// wholesale ceiling for a single order ($4)". When the ceiling moved to $7.50
// the ladder did not, so at the live SMSPVA balance of $3.55 the monitor read
// tier 3 ("low") while ~1,500 routes — every WhatsApp route among them — could
// not be funded AT ALL. A user ordering one was guaranteed a BALANCE_ERROR,
// charged and refunded. Deriving the tiers keeps that honest through the next
// ceiling change.
const MAX_ORDER_COST_USD = 7.5;

// 5x the priciest single order, so the first page still leaves room to act.
const LOW_BALANCE_USD = MAX_ORDER_COST_USD * 5;

// Escalation ladder. The original single edge-trigger fired once at $20 and
// then NEVER AGAIN — both providers sat "low" for days while sliding toward
// $0 (= 100% order failure) with no further page. Each threshold crossing now
// pages once; recovery above a tier re-arms it automatically.
//
// The last rung is the ceiling itself: below it we cannot fill the most
// expensive route in the catalog, which is a real outage for that inventory
// even though the balance is not zero.
const BALANCE_TIERS = [
  LOW_BALANCE_USD,               // 37.50
  MAX_ORDER_COST_USD * 3,        // 22.50
  MAX_ORDER_COST_USD * 1.5,      // 11.25
  MAX_ORDER_COST_USD,            //  7.50
];

function validateCronSecret(req: Request): boolean {
  const header = req.headers.get("x-cron-secret");
  const expected = Deno.env.get("CRON_SECRET");
  if (!header || !expected) return false;
  return header === expected;
}

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;

  if (!validateCronSecret(req)) {
    return json({ error: "unauthorized" }, { status: 401 });
  }

  const sb = admin();

  // Best-effort push fan-out to all of a user's devices. Never throws.
  async function notify(
    userId: string,
    title: string,
    body: string,
    data: Record<string, unknown>,
  ): Promise<number> {
    const { data: devices } = await sb
      .from("push_devices")
      .select("token, environment, bundle_id")
      .eq("user_id", userId);
    let sent = 0;
    for (const d of devices ?? []) {
      try {
        const r = await sendPush(
          d.token,
          { alertTitle: title, alertBody: body, customData: data },
          d.environment as "sandbox" | "production",
        );
        if (r.ok) sent++;
        else {
          console.error("APNs status", r.status, r.body);
          // 410 Unregistered / 400 BadDeviceToken = the token is permanently
          // dead (app deleted, token rotated). Prune it: dead tokens never
          // heal, they only slow every future fan-out and — via winback's
          // mark-on-success rule — permanently clog its candidate window.
          if (r.status === 410 || (r.body ?? "").includes("BadDeviceToken")) {
            await sb.from("push_devices").delete().eq("token", d.token);
          }
        }
      } catch (e) {
        console.error("APNs send failed:", e);
      }
    }
    return sent;
  }

  let expired = 0, polled = 0, arrived = 0, pushSent = 0;

  /** Record one provider's balance. Each call is independently guarded so an
   *  outage at one provider can never suppress the other's reading — which is
   *  precisely how SMSPVA would stay invisible on the day it matters.
   *  Alerts once per BALANCE_TIERS threshold crossing (worsening only);
   *  climbing back above a tier re-arms it. The 6-hourly digest carries the
   *  standing status; this is the instant page. */
  async function recordBalance(
    key: string, label: string, read: () => Promise<number | null>,
  ) {
    try {
      const bal = await read();
      if (bal == null || !Number.isFinite(bal)) return;
      const low = bal < LOW_BALANCE_USD;
      // 0 = healthy, 1 = below $20 … 4 = below $1 (effectively empty).
      const tier = BALANCE_TIERS.filter((t) => bal < t).length;

      const { data: prev } = await sb
        .from("app_config").select("value").eq("key", key).maybeSingle();
      const prevVal = prev?.value as { low?: boolean; alert_tier?: number } | null;
      // Older readings predate alert_tier; treat a legacy low=true as tier 1
      // so redeploying doesn't re-page for the crossing that already paged.
      const prevTier = prevVal?.alert_tier ?? (prevVal?.low ? 1 : 0);

      // Send FIRST, then stamp the tier — and only stamp the escalation if the
      // send actually landed.
      //
      // This used to upsert `alert_tier` before calling notifySafe, which
      // swallows failures. One timed-out Telegram send therefore recorded the
      // crossing as already-alerted: the next run saw tier == prevTier and
      // stayed silent. On the bottom rung that is permanent, because there is
      // no lower tier left to cross — the "balance EMPTY" page would never fire
      // again. telegram-notify's claimAndSend already gets this right; these
      // three sites did not.
      let alerted = true;
      if (tier > prevTier) {
        console.error(`${key} balance $${bal} crossed below $${BALANCE_TIERS[tier - 1]}`);
        alerted = await notifySafe(
          tier >= BALANCE_TIERS.length
            ? `🚨 <b>${label} balance EMPTY: $${bal.toFixed(2)}</b>\n` +
              `Orders on this provider are failing NOW — top up immediately.`
            : `⚠️ <b>${label} balance low: $${bal.toFixed(2)}</b>\n` +
              `Crossed below $${BALANCE_TIERS[tier - 1]} — top up before orders start failing.`,
        );
        if (!alerted) {
          console.error(`${key} balance page FAILED to send — not recording tier ${tier}, will retry next run`);
        }
      }

      await sb.from("app_config").upsert({
        key,
        value: {
          balance_usd: bal,
          low,
          // Hold the previous tier when the page didn't get out, so the
          // crossing is re-attempted rather than silently consumed.
          alert_tier: alerted ? tier : prevTier,
          checked_at: new Date().toISOString(),
        },
        updated_at: new Date().toISOString(),
      }, { onConflict: "key" });
    } catch (e) {
      console.error(`${key} balance check failed:`, e);
    }
  }

  // ── Balance monitoring runs FIRST, before any order loop. It doubles as the
  //    watchdog's minutely heartbeat (run_watchdog checks smspva_health
  //    freshness), so it must not sit behind work whose duration scales with
  //    order volume — at the 150s worker kill it would silently stop, and a
  //    frozen reading is indistinguishable from a healthy provider.
  await Promise.all([
    recordBalance("smspva_health", "SMSPVA (SMS)", async () => {
      // SMSPVA wraps every response in {statusCode, data} — the balance is at
      // r.data.balance, NOT r.balance. Reading the wrong level yields NaN and
      // writes nothing at all, which looks identical to "provider is fine".
      const r = await getSmspvaBalance();
      if (!isOk(r)) {
        console.error("smspva balance error:", JSON.stringify(r));
        return null;
      }
      const n = Number(r.data?.balance);
      return Number.isFinite(n) ? n : null;
    }),
    recordBalance("smspool_health", "SMSPool (eSIM)", getBalanceUsd),
  ]);

  // ── Auto-expire overdue orders. Each expiry is an atomic claim (flip
  //    waiting -> expired only if still waiting) so two overlapping cron runs
  //    can't both refund/notify the same order — the loser matches 0 rows and
  //    skips. Refund + "no code" push happen only for the winner. Per-order
  //    try/catch keeps one bad row from aborting the batch.
  const { data: expiredCandidates, error: expCandErr } = await sb
    .from("orders")
    .select("id, user_id, cost_credits, provider, smspva_id, service:service_id ( name )")
    .eq("status", "waiting")
    .lt("expires_at", new Date().toISOString())
    .order("expires_at", { ascending: true })
    .limit(200);   // cap the per-run batch; the minutely cadence drains any backlog
  // If this select fails, zero orders expire and zero refunds are issued — and
  // the run still returns 200 {expired: 0}, which is indistinguishable from a
  // quiet minute. Surface it.
  if (expCandErr) {
    console.error("poll: expiry candidate select FAILED — no orders will be expired this run", expCandErr);
  }

  for (const row of expiredCandidates ?? []) {
    try {
      const { data: claimed, error: cErr } = await sb
        .from("orders")
        .update({ status: "expired", closed_at: new Date().toISOString() })
        .eq("id", row.id)
        .eq("status", "waiting")
        .select("id");
      if (cErr) { console.error("expire claim failed for order", row.id, cErr); continue; }
      if (!claimed || claimed.length === 0) continue; // another run handled it

      // supabase-js RETURNS errors, it does not throw, and wallet_credit raises
      // on a non-positive amount or a missing wallet row. Discarding this meant
      // the claim committed, the money never moved, `expired++` still counted
      // it, and we pushed "N credits refunded" to a user who wasn't.
      const { error: refundErr } = await sb.rpc("wallet_credit", {
        p_user: row.user_id, p_amount: row.cost_credits, p_reason: "refund", p_order: row.id,
      });
      if (refundErr) {
        console.error(`poll: REFUND FAILED order=${row.id} user=${row.user_id} ` +
                      `credits=${row.cost_credits}: ${refundErr.message}`);
        continue;   // no count, and above all no "you were refunded" push
      }
      expired++;

      // Ban + close at the provider. Before this, an expired order was never
      // told to SMSPVA at all: their side kept the request id live for ~10
      // minutes and re-issued the same dead number to the next order (their
      // docs explicitly say to ban when no SMS arrived). Best-effort — the
      // refund above already happened and must never depend on this.
      if (row.smspva_id) {
        await markDead((row.provider ?? "smspva") as Provider, row.smspva_id);
      }

      const svc = row.service as { name: string } | null;
      pushSent += await notify(
        row.user_id,
        "No code arrived",
        `Your ${svc?.name ?? "verification"} number expired — ${row.cost_credits} credits refunded.`,
        // orderId matters: "No code arrived" is the most-delivered push in
        // the product, and without a reference the tap landed on Home —
        // bypassing RecoveryScreen, the refund receipt and the steer.
        { event: "expired", orderId: row.id },
      );
    } catch (e) {
      console.error("expire failed for order", row.id, e);
    }
  }

  // ── Poll the still-waiting orders for their SMS.
  const { data: pending, error: pErr } = await sb
    .from("orders")
    .select(`
      id, user_id, provider, smspva_id, cost_credits,
      service:service_id ( id, name )
    `)
    .eq("status", "waiting")
    .not("smspva_id", "is", null)
    // Oldest first + hard cap: each row costs a provider round-trip, and the
    // worker dies at ~150s wall clock. 50 sequential polls is already near
    // that budget; anything beyond waits a minute for the next run.
    .order("created_at", { ascending: true })
    .limit(50);

  if (pErr) return json({ error: "list_failed", detail: pErr.message }, { status: 500 });

  for (const o of pending ?? []) {
    polled++;
    let result;
    try {
      result = await poll((o.provider ?? "smspva") as Provider, o.smspva_id!);
    } catch (e) {
      console.error("poll failed for order", o.id, e);
      continue;
    }

    if (result.state === "received" && result.code) {
      // Atomic claim: only flip waiting -> received once, so overlapping runs
      // don't double-notify a delivered code.
      const { data: claimed, error: uErr } = await sb
        .from("orders")
        .update({
          status: "received",
          otp: result.code,
          raw_message: result.fullText ?? null,
          arrived_at: new Date().toISOString(),
          closed_at: new Date().toISOString(),
        })
        .eq("id", o.id)
        .eq("status", "waiting")
        .select("id");

      if (uErr) { console.error("update failed for order", o.id, uErr); continue; }
      if (!claimed || claimed.length === 0) {
        // Same loss class check-order already logs: the code exists at the
        // provider but something (cancel/expiry) closed the order first.
        // This cron path sees far more traffic than manual "Check now" taps,
        // so without this line the true rate of discarded codes is invisible.
        console.warn(
          `poll: code arrived for ${o.id} AFTER it was closed — refund stands, code discarded`,
        );
        continue;
      }

      // Tell SMSPVA the activation succeeded — best-effort karma hygiene.
      await markSuccess((o.provider ?? "smspva") as Provider, o.smspva_id);

      arrived++;
      // Optional-chained: a null embed here used to throw out of the whole
      // handler, aborting every remaining order in the batch.
      const service = o.service as { name: string } | null;
      pushSent += await notify(
        o.user_id,
        `${service?.name ?? "Verification"} code arrived`,
        `Your code is ${result.code}`,
        { orderId: o.id, otp: result.code },
      );
    } else if (result.state === "expired" || result.state === "canceled") {
      // Provider-side close. Previously computed and ignored, so the order sat
      // "waiting" — and kept being polled — until our own timer caught up.
      const { data: claimed } = await sb
        .from("orders")
        .update({ status: "expired", closed_at: new Date().toISOString() })
        .eq("id", o.id)
        .eq("status", "waiting")
        .select("id");
      if (!claimed || claimed.length === 0) continue;
      // Check the refund result — see the note on the expiry sweep above.
      const { error: rErr } = await sb.rpc("wallet_credit", {
        p_user: o.user_id, p_amount: o.cost_credits, p_reason: "refund", p_order: o.id,
      });
      if (rErr) {
        console.error(`poll: REFUND FAILED (provider-close) order=${o.id} ` +
                      `user=${o.user_id} credits=${o.cost_credits}: ${rErr.message}`);
        continue;   // don't count it, and don't tell the user they were refunded
      }
      expired++;
      const svc = o.service as { name: string } | null;
      pushSent += await notify(
        o.user_id,
        "No code arrived",
        `Your ${svc?.name ?? "verification"} number closed — ${o.cost_credits} credits refunded.`,
        { event: "expired", orderId: o.id },
      );
    }
  }

  // ── Late-code rescue.
  //
  // Cancels land at a median of 57s; codes arrive at a median of 58s, 45% of
  // them after 60s. cancel-order no longer releases the number — it stamps
  // late_watch_until — so a code that shows up after the user gave up is still
  // ours to hand over. The refund already stands and the status stays
  // 'canceled': we give the code away. Owner decision 2026-07-27.
  //
  // The push carries NO orderId on purpose. Shipped PushManager routes on
  // orderId, and deep-linking into a canceled order would land the user on the
  // recovery/refund screen instead of their code. Without it the tap just opens
  // the app, and the code is in the notification body where they can read it.
  let rescued = 0, lateReleased = 0;
  const nowIso = new Date().toISOString();
  const { data: lateWatch, error: lateErr } = await sb
    .from("orders")
    .select("id, user_id, cost_credits, provider, smspva_id, late_watch_until, service:service_id ( name )")
    .not("late_watch_until", "is", null)
    .is("otp", null)
    .limit(50);
  if (lateErr) console.error("poll: late-watch select failed", lateErr);

  for (const o of lateWatch ?? []) {
    try {
      if (!o.smspva_id) {
        await sb.from("orders").update({ late_watch_until: null }).eq("id", o.id);
        continue;
      }
      // Window closed with no code — reclaim what we can and stop watching.
      if ((o.late_watch_until as string) <= nowIso) {
        await markDead((o.provider ?? "smspva") as Provider, o.smspva_id);
        await sb.from("orders").update({ late_watch_until: null }).eq("id", o.id);
        lateReleased++;
        continue;
      }

      const res = await poll((o.provider ?? "smspva") as Provider, o.smspva_id);
      if (res.state !== "received" || !res.code) continue;

      // Write the code onto the canceled row. `otp is not null` is what the
      // delivery-evidence functions now count as a code, so a rescue correctly
      // credits the route with having delivered.
      const { data: got } = await sb
        .from("orders")
        .update({
          otp: res.code,
          raw_message: res.fullText ?? null,
          arrived_at: new Date().toISOString(),
          late_watch_until: null,
        })
        .eq("id", o.id)
        .is("otp", null)
        .select("id");
      if (!got || got.length === 0) continue;   // another run got there first

      await markSuccess((o.provider ?? "smspva") as Provider, o.smspva_id);
      rescued++;
      const svc = o.service as { name: string } | null;
      pushSent += await notify(
        o.user_id,
        `Your ${svc?.name ?? "verification"} code arrived after all`,
        `${res.code} — your ${o.cost_credits} credits were already refunded, so this one's on us.`,
        { event: "late_code", otp: res.code },
      );
    } catch (e) {
      console.error("late-watch failed for order", o.id, e);
    }
  }

  return json({ expired, polled, arrived, pushSent, rescued, lateReleased });
});
