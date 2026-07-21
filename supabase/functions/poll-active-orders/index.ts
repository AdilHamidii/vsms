// Called by pg_cron every minute. Auto-expires overdue orders (refund + notify),
// then polls the provider for incoming SMS on the rest, persisting OTPs and
// dispatching push notifications.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import { poll, type Provider } from "../_shared/providers.ts";
import { getBalanceUsd } from "../_shared/smspool.ts";
import { getBalance as getSmspvaBalance, isOk } from "../_shared/smspva.ts";
import { sendPush } from "../_shared/apns.ts";

// 5x the wholesale ceiling for a single order ($4), so the alert fires while
// there is still room to act. $2 was below the cost of one expensive number:
// by the time it tripped, the account could already be unable to fill.
const LOW_BALANCE_USD = 20;

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
        else console.error("APNs status", r.status, r.body);
      } catch (e) {
        console.error("APNs send failed:", e);
      }
    }
    return sent;
  }

  let expired = 0, polled = 0, arrived = 0, pushSent = 0;

  // ── Auto-expire overdue orders. Each expiry is an atomic claim (flip
  //    waiting -> expired only if still waiting) so two overlapping cron runs
  //    can't both refund/notify the same order — the loser matches 0 rows and
  //    skips. Refund + "no code" push happen only for the winner. Per-order
  //    try/catch keeps one bad row from aborting the batch.
  const { data: expiredCandidates } = await sb
    .from("orders")
    .select("id, user_id, cost_credits, service:service_id ( name )")
    .eq("status", "waiting")
    .lt("expires_at", new Date().toISOString());

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

      const svc = row.service as { name: string } | null;
      pushSent += await notify(
        row.user_id,
        "No code arrived",
        `Your ${svc?.name ?? "verification"} number expired — ${row.cost_credits} credits refunded.`,
        { event: "expired" },
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
    .not("smspva_id", "is", null);

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
      if (!claimed || claimed.length === 0) continue; // already handled

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
        { event: "expired" },
      );
    }
  }

  // Low-balance guardrail. This used to watch VIRTUALSMS — a provider that was
  // retired and isn't in providerOrder at all — while SMSPool, the only
  // provider that actually fulfils orders, went unmonitored. A dry SMSPool
  // balance means 100% order failure (documented 422 BALANCE_ERROR) with no
  // alert anywhere, so point it at the provider we actually spend on.
  /** Record one provider's balance. Each call is independently guarded so an
   *  outage at one provider can never suppress the other's reading — which is
   *  precisely how SMSPVA would stay invisible on the day it matters. */
  async function recordBalance(key: string, read: () => Promise<number | null>) {
    try {
      const bal = await read();
      if (bal == null || !Number.isFinite(bal)) return;
      const low = bal < LOW_BALANCE_USD;
      await sb.from("app_config").upsert({
        key,
        value: { balance_usd: bal, low, checked_at: new Date().toISOString() },
        updated_at: new Date().toISOString(),
      }, { onConflict: "key" });
      if (low) console.error(`${key} balance LOW ($${bal}) — top up or orders fail`);
    } catch (e) {
      console.error(`${key} balance check failed:`, e);
    }
  }

  await Promise.all([
    // SMSPVA fulfils every SMS order as of 2026-07-20. Until now nothing read
    // this at all: the account could empty and every order would fail with no
    // alert anywhere.
    recordBalance("smspva_health", async () => {
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
    // SMSPool no longer serves SMS — it funds eSIMs only, so a low reading here
    // means the eSIM product is at risk, not SMS.
    recordBalance("smspool_health", getBalanceUsd),
  ]);

  return json({ expired, polled, arrived, pushSent });
});
