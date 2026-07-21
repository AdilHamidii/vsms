// Winback nudges — cron-driven (relay-winback, daily). Two one-shot cohorts:
//
//  1. Never-ordered: signed up, never placed an order — "use your free
//     credit". Eligibility + dedupe: winback_candidates() /
//     profiles.winback_sent_at.
//  2. Stranded credits: last order failed, wallet still loaded, walked away —
//     "your credits are still here, delivery improved". Eligibility + dedupe:
//     stranded_credit_candidates() / profiles.stranded_nudge_sent_at. That
//     candidates fn returns NOTHING until the active provider's measured
//     48h delivery rate clears 40% — we do not tell burned users delivery
//     improved until the data says it did.
//
// Guarded by the cron secret (deployed --no-verify-jwt: the pg_cron relay
// sends only x-cron-secret, no Authorization header — with verify_jwt on,
// every daily run 401'd silently and zero nudges were ever sent).
// Mirrors poll-active-orders' APNs dispatch.

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

  // ── Cohort 2: stranded credits (delivery-gated, see header) ──────────────
  const { data: stranded, error: sErr } = await sb.rpc("stranded_credit_candidates", { p_limit: 100 });
  if (sErr) console.error("stranded_credit_candidates failed:", sErr.message);

  let strandedSent = 0, strandedMarked = 0;

  for (const c of (stranded ?? []) as { user_id: string; balance: number }[]) {
    const { data: devices } = await sb
      .from("push_devices")
      .select("token, environment")
      .eq("user_id", c.user_id);

    let anyOk = false;
    for (const d of devices ?? []) {
      try {
        const r = await sendPush(d.token, {
          alertTitle: "Your credits are still here",
          alertBody: `${c.balance} credit${c.balance === 1 ? "" : "s"} in your wallet — and SMS delivery just got a big upgrade. Try another number in seconds.`,
          customData: { winback: "stranded" },
        }, d.environment as "sandbox" | "production");
        if (r.ok) { anyOk = true; strandedSent++; }
        else { failed++; console.error("APNs status", r.status, r.body); }
      } catch (e) {
        failed++; console.error("APNs send failed:", e);
      }
    }

    if (anyOk) {
      await sb.from("profiles")
        .update({ stranded_nudge_sent_at: new Date().toISOString() })
        .eq("user_id", c.user_id);
      strandedMarked++;
    }
  }

  return json({
    candidates: candidates?.length ?? 0, sent, marked,
    strandedCandidates: stranded?.length ?? 0, strandedSent, strandedMarked,
    failed,
  });
});
