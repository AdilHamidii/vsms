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

// 5x the wholesale ceiling for a single order ($4), so the alert fires while
// there is still room to act. $2 was below the cost of one expensive number:
// by the time it tripped, the account could already be unable to fill.
const LOW_BALANCE_USD = 20;

// Escalation ladder. The original single edge-trigger fired once at $20 and
// then NEVER AGAIN — both providers sat "low" for days while sliding toward
// $0 (= 100% order failure) with no further page. Each threshold crossing now
// pages once; recovery above a tier re-arms it automatically.
const BALANCE_TIERS = [LOW_BALANCE_USD, 10, 5, 1];

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

      await sb.from("app_config").upsert({
        key,
        value: { balance_usd: bal, low, alert_tier: tier, checked_at: new Date().toISOString() },
        updated_at: new Date().toISOString(),
      }, { onConflict: "key" });

      if (tier > prevTier) {
        console.error(`${key} balance $${bal} crossed below $${BALANCE_TIERS[tier - 1]}`);
        await notifySafe(
          tier >= BALANCE_TIERS.length
            ? `🚨 <b>${label} balance EMPTY: $${bal.toFixed(2)}</b>\n` +
              `Orders on this provider are failing NOW — top up immediately.`
            : `⚠️ <b>${label} balance low: $${bal.toFixed(2)}</b>\n` +
              `Crossed below $${BALANCE_TIERS[tier - 1]} — top up before orders start failing.`,
        );
      }
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
  const { data: expiredCandidates } = await sb
    .from("orders")
    .select("id, user_id, cost_credits, provider, smspva_id, service:service_id ( name )")
    .eq("status", "waiting")
    .lt("expires_at", new Date().toISOString())
    .order("expires_at", { ascending: true })
    .limit(200);   // cap the per-run batch; the minutely cadence drains any backlog

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

      await sb.rpc("wallet_credit", {
        p_user: row.user_id, p_amount: row.cost_credits, p_reason: "refund", p_order: row.id,
      });
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
      const service = o.service as { name: string };
      pushSent += await notify(
        o.user_id,
        `${service.name} code arrived`,
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
      await sb.rpc("wallet_credit", {
        p_user: o.user_id, p_amount: o.cost_credits, p_reason: "refund", p_order: o.id,
      });
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

  return json({ expired, polled, arrived, pushSent });
});
