// Daily-credit nudge — cron-driven (relay-daily-credit, once a day).
//
// "Your free credit is ready" for anyone who hasn't claimed today's credit.
// Unlike the winback cohorts this is NOT one-shot: it is the recurring reason
// to open the app, so there is no *_sent_at dedupe — the natural dedupe is
// `last_daily_credit_on = today`, which claim_daily_credit() sets. A user who
// already opened the app today is simply not a candidate.
//
// The credit itself is granted by claim_daily_credit() when the app opens, NOT
// here: granting from a push would pay users who never came back, which is the
// opposite of the point.
//
// Guarded by the cron secret (deploy --no-verify-jwt: the pg_cron relay sends
// only x-cron-secret, no Authorization header — winback silently 401'd for
// weeks that way). Mirrors winback's APNs dispatch and dead-token hygiene.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import { sendPush } from "../_shared/apns.ts";

function validateCronSecret(req: Request): boolean {
  const header = req.headers.get("x-cron-secret");
  const expected = Deno.env.get("CRON_SECRET");
  return !!header && !!expected && header === expected;
}

/** Streak-aware copy. A user with a run going has something to lose, which is
 *  a far stronger pull than "free stuff" — but we only say it when it's true. */
function copyFor(streak: number): { title: string; body: string } {
  if (streak >= 2) {
    return {
      title: `Day ${streak + 1} — your credit is ready`,
      body: `Open vSMS to claim it and keep your ${streak}-day streak going.`,
    };
  }
  return {
    title: "Your free credit is ready",
    body: "Open vSMS to pick up today's credit.",
  };
}

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;
  if (!validateCronSecret(req)) {
    return json({ error: "unauthorized" }, { status: 401 });
  }

  const sb = admin();

  const { data: candidates, error } = await sb.rpc("daily_credit_candidates", { p_limit: 500 });
  if (error) {
    return json({ error: "candidates_failed", detail: error.message }, { status: 500 });
  }

  let sent = 0, failed = 0, pruned = 0;

  for (const c of (candidates ?? []) as
       { user_id: string; token: string; environment: string; streak: number }[]) {
    const { title, body } = copyFor(c.streak ?? 0);
    try {
      const r = await sendPush(
        c.token,
        { alertTitle: title, alertBody: body, customData: { event: "daily_credit" } },
        c.environment === "sandbox" || c.environment === "production"
          ? c.environment
          : undefined,
      );
      if (r.ok) {
        sent++;
      } else {
        failed++;
        // Dead-token hygiene, same rule as winback: 410 / BadDeviceToken never
        // heal, and a dead token left in place slows every future fan-out.
        if (r.status === 410 || (r.body ?? "").includes("BadDeviceToken")) {
          await sb.from("push_devices").delete().eq("token", c.token);
          pruned++;
        }
      }
    } catch (e) {
      failed++;
      console.error("daily-credit: push threw", c.user_id, e);
    }
  }

  // Freshness signal for run_watchdog — a scheduled job with no heartbeat is
  // a job that can die silently (the documented rule for new crons).
  await sb.from("app_config").upsert({
    key: "daily_credit_heartbeat",
    value: { ran_at: new Date().toISOString(), candidates: (candidates ?? []).length, sent },
  });

  return json({ candidates: (candidates ?? []).length, sent, failed, pruned });
});
