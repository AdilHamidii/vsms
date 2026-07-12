// Winback nudge — cron-driven (relay-winback, daily). Pushes users who signed
// up but never placed an order to come use their free credit. Guarded by the
// cron secret; eligibility + one-time dedupe live in winback_candidates() /
// profiles.winback_sent_at. Mirrors poll-active-orders' APNs dispatch.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import { sendPush } from "../_shared/apns.ts";

function validateCronSecret(req: Request): boolean {
  const header = req.headers.get("x-cron-secret");
  const expected = Deno.env.get("CRON_SECRET");
  return !!header && !!expected && header === expected;
}

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;
  if (!validateCronSecret(req)) {
    return json({ error: "unauthorized" }, { status: 401 });
  }

  const sb = admin();

  const { data: candidates, error } = await sb.rpc("winback_candidates", { p_limit: 200 });
  if (error) {
    return json({ error: "candidates_failed", detail: error.message }, { status: 500 });
  }

  let sent = 0, marked = 0, failed = 0;

  for (const c of (candidates ?? []) as { user_id: string }[]) {
    const { data: devices } = await sb
      .from("push_devices")
      .select("token, environment")
      .eq("user_id", c.user_id);

    let anyOk = false;
    for (const d of devices ?? []) {
      try {
        const r = await sendPush(d.token, {
          alertTitle: "Your free credit is waiting",
          alertBody: "Grab a verification number in seconds — your first one's on us.",
          customData: { winback: true },
        }, d.environment as "sandbox" | "production");
        if (r.ok) { anyOk = true; sent++; }
        else { failed++; console.error("APNs status", r.status, r.body); }
      } catch (e) {
        failed++; console.error("APNs send failed:", e);
      }
    }

    // Mark sent only when a device accepted it — if every device failed
    // (transient), leave winback_sent_at null so the next daily run retries.
    if (anyOk) {
      await sb.from("profiles")
        .update({ winback_sent_at: new Date().toISOString() })
        .eq("user_id", c.user_id);
      marked++;
    }
  }

  return json({ candidates: candidates?.length ?? 0, sent, marked, failed });
});
