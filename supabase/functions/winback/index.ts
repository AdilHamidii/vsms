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

  /** Dead-token hygiene: 410 Unregistered / BadDeviceToken never heal. Left
   *  in place they slow every fan-out AND — because we only mark a user
   *  nudged when a device ACCEPTS — pin un-nudgeable users inside the
   *  LIMIT-bounded candidate window forever, silently starving everyone
   *  behind them. Prune the token; a user left with zero devices is marked
   *  nudged below for the same reason. */
  const pruneIfDead = async (token: string, status: number, body?: string) => {
    if (status === 410 || (body ?? "").includes("BadDeviceToken")) {
      await sb.from("push_devices").delete().eq("token", token);
    }
  };

  for (const c of (candidates ?? []) as { user_id: string; kind?: string }[]) {
    const { data: devices } = await sb
      .from("push_devices")
      .select("token, environment")
      .eq("user_id", c.user_id);

    if (!devices || devices.length === 0) {
      // No device can ever receive this nudge — mark it handled so the user
      // stops occupying a slot in the candidate window.
      await sb.from("profiles")
        .update({ winback_sent_at: new Date().toISOString() })
        .eq("user_id", c.user_id);
      marked++;
      continue;
    }

    let anyOk = false;
    for (const d of devices) {
      try {
        // Honest copy per cohort. winback_candidates was broadened to
        // include "ordered but never received a code" while the copy stayed
        // "your first one's on us" — so 8 of the 34 users ever nudged were
        // told their first number was free AFTER paying for failures.
        const triedFailed = c.kind === "tried_failed";
        const r = await sendPush(d.token, triedFailed ? {
          alertTitle: "Your credits are still here",
          alertBody: "Every number that fails is refunded. Pick a country we've measured delivering.",
          customData: { winback: true },
        } : {
          alertTitle: "Your free credit is waiting",
          alertBody: "Grab a verification number in seconds — your first one's on us.",
          customData: { winback: true },
        }, d.environment as "sandbox" | "production");
        if (r.ok) { anyOk = true; sent++; }
        else {
          failed++; console.error("APNs status", r.status, r.body);
          await pruneIfDead(d.token, r.status, r.body);
        }
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
  // SECOND gate, on the USER-EXPERIENCED rate. stranded_credit_candidates is
  // gated on recent_sms_delivery_rate(), which counts only CONCLUSIVE orders —
  // excluding 13 of the last 15 cancels, so it read 50% on a window where real
  // users got 19%. That left the gate open and armed "delivery just got a big
  // upgrade" for the very users we had already burned.
  const { data: userRate } = await sb.rpc("recent_user_delivery_rate", { p_window: "48 hours" });
  const experienced = Number(userRate ?? 0);
  const claimSafe = experienced >= 25;
  if (!claimSafe) console.warn(`winback: suppressing stranded cohort — user-experienced delivery ${experienced}% < 25%`);
  const { data: stranded, error: sErr } = claimSafe
    ? await sb.rpc("stranded_credit_candidates", { p_limit: 100 })
    : { data: [] as { user_id: string; balance: number }[], error: null };
  if (sErr) console.error("stranded_credit_candidates failed:", sErr.message);

  let strandedSent = 0, strandedMarked = 0;

  for (const c of (stranded ?? []) as { user_id: string; balance: number }[]) {
    const { data: devices } = await sb
      .from("push_devices")
      .select("token, environment")
      .eq("user_id", c.user_id);

    if (!devices || devices.length === 0) {
      await sb.from("profiles")
        .update({ stranded_nudge_sent_at: new Date().toISOString() })
        .eq("user_id", c.user_id);
      strandedMarked++;
      continue;
    }

    let anyOk = false;
    for (const d of devices) {
      try {
        const r = await sendPush(d.token, {
          alertTitle: "Your credits are still here",
          alertBody: `${c.balance} credit${c.balance === 1 ? "" : "s"} in your wallet — and SMS delivery just got a big upgrade. Try another number in seconds.`,
          customData: { winback: "stranded" },
        }, d.environment as "sandbox" | "production");
        if (r.ok) { anyOk = true; strandedSent++; }
        else {
          failed++; console.error("APNs status", r.status, r.body);
          await pruneIfDead(d.token, r.status, r.body);
        }
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

  // Heartbeat for the SQL watchdog (run_watchdog checks this key's
  // updated_at; the app_config touch trigger maintains it). Written on every
  // completed run — a silent 401 like the 9-day one now pages within a day.
  await sb.from("app_config").upsert({
    key: "winback_heartbeat",
    value: { at: new Date().toISOString() },
  }, { onConflict: "key" });

  return json({
    candidates: candidates?.length ?? 0, sent, marked,
    strandedCandidates: stranded?.length ?? 0, strandedSent, strandedMarked,
    failed,
  });
});
