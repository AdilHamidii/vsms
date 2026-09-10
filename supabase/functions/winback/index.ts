// Nudges — cron-driven (relay-winback, daily 15:00 UTC). Four cohorts:
//
//  1. Never-ordered: signed up, never placed an order — "use your free
//     credit". Eligibility + dedupe: winback_candidates() /
//     profiles.winback_sent_at.
//  2. Stranded credits: last order failed, wallet still loaded, walked away —
//     "your credits are still here". Eligibility + dedupe:
//     stranded_credit_candidates() / profiles.stranded_nudge_sent_at. Gated
//     on the PRIMARY provider's float and on watchdog checks that mean orders
//     fail — NOT on balance warnings (see the gate for the month that cost).
//  3. Reorder: a code came through 3–14 days ago and credits remain.
//  4. Line expiry: a rented number whose subscriber turned auto-renew off,
//     3 days and 1 day before it is deleted. Not a winback — a paying
//     customer using the product. line_expiry_nudge_candidates() /
//     line_subscriptions.expiry_nudged_{3d,1d}_for.
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
      await sb.rpc("bump_winback_sent", { p_user: c.user_id });
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
        //
        // That same error came back by a different route on 2026-08-04, which
        // is why neither branch may describe a balance as FREE. The signup
        // grant is now permanently 0, and this cohort is gated on
        // `balance > 0` — so a never_ordered candidate from here on is someone
        // who BOUGHT those credits. "Your first one's on us" is false for
        // them, and grows more false as the granted balances drain.
        //
        // Both branches now assert only things that hold however the credits
        // were obtained: that the balance exists, and that a number which
        // delivers nothing is refunded.
        const triedFailed = c.kind === "tried_failed";
        const r = await sendPush(d.token, triedFailed ? {
          alertTitle: "Your credits are still here",
          alertBody: "Every number that fails is refunded. Pick a country we've measured delivering.",
          customData: { winback: true },
        } : {
          alertTitle: "Your credits are still here",
          alertBody: "Grab a verification number in seconds. No code, no charge — you're refunded.",
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
      // Counter, not just a timestamp: winback_candidates now allows up to 3
      // sends 14 days apart, so the recurrence has to be counted.
      await sb.rpc("bump_winback_sent", { p_user: c.user_id });
      marked++;
    }
  }

  // ── Cohort 2: stranded credits (delivery-gated, see header) ──────────────
  // SECOND gate, on the USER-EXPERIENCED rate. stranded_credit_candidates is
  // gated on recent_sms_delivery_rate(), which counts only CONCLUSIVE orders —
  // excluding 13 of the last 15 cancels, so it read 50% on a window where real
  // users got 19%. That left the gate open and armed "delivery just got a big
  // upgrade" for the very users we had already burned.
  // The old gate was `recent_user_delivery_rate('48h') >= 25`. It existed to
  // justify the words "delivery just got a big upgrade" — but it counts every
  // impatient cancel as a delivery failure, and 68% of orders are cancelled at a
  // median of 57s, so it sits structurally in the 13-25% band no matter how well
  // the provider performs. Live reading when audited: 13, against the sibling
  // gate's 60 on the same window. It could essentially never open, and has sent
  // nothing since it shipped.
  //
  // The fix is to stop making the unprovable claim (see copy below) rather than
  // to keep a metric that can't open. What remains is a LIVENESS check: only
  // invite someone back if we can actually serve them.
  // Gate on the provider that serves the cohort's NEXT order. This read
  // smspva_health until the 2026-07-30 HeroSMS cutover, then herosms_health
  // until 2026-09-10 — a month after 5sim became primary (it owns ~86% of
  // active routes: `select provider, count(*) from routes where
  // status='active' group by 1`). Same drift both times: the key names
  // whichever provider was primary when the line was written. Re-check it
  // after any provider switch (checklist step 6).
  const { data: health } = await sb
    .from("app_config").select("value").eq("key", "5sim_health").maybeSingle();
  const balUsd = Number((health?.value as { balance_usd?: number } | null)?.balance_usd ?? 0);
  const { data: wd } = await sb
    .from("app_config").select("value").eq("key", "watchdog").maybeSingle();
  const wdVal = wd?.value as { failing?: { check?: string }[]; checked_at?: string } | null;
  // Only checks that mean "an order would fail" hold the cohort back. The
  // `*-float` checks are balance/runway WARNINGS — the balance is gated
  // directly above, and `telnyx-float` is a different product entirely — yet
  // `failing === 0` let any of them silence this: a 5sim runway warning kept
  // the cohort dark from 2026-08-09 to 2026-09-10 while 30 buyers sat idle on
  // 488 paid credits. A warning is not an outage.
  const failing = (wdVal?.failing ?? [])
    .filter((f) => !/-float$/.test(String(f?.check ?? ""))).length;
  // A dead watchdog reports `failing: []` forever, so an un-aged verdict would
  // wave the cohort through during an outage — the very thing this gate exists
  // to prevent. telegram-notify and /balance both age it; so must this.
  const wdFresh = !!wdVal?.checked_at &&
    Date.now() - new Date(wdVal.checked_at).getTime() <= 30 * 60 * 1000;
  const claimSafe = balUsd >= 7.5 && failing === 0 && wdFresh;
  if (!claimSafe) {
    console.warn(`winback: suppressing stranded cohort — provider balance $${balUsd}, watchdog failing=${failing}`);
  }
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
          // No "delivery just got a big upgrade" — that was an unprovable claim
          // aimed at users we had already burned, and it forced the un-openable
          // gate above. What's left is true unconditionally.
          alertBody: `${c.balance} credit${c.balance === 1 ? "" : "s"} in your wallet. Every number that fails is refunded automatically.`,
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

  // ── Cohort 3: REORDER — users who actually succeeded ────────────────────
  //
  // These were excluded from every nudge in the product by construction:
  // winback_candidates skips anyone with a delivered order, and
  // stranded_credit_candidates requires the last order to have FAILED. Yet this
  // is the only cohort with proven fit — 12 of 13 users who ever received a code
  // went on to purchase, and users with 2+ codes average 14.8 lifetime orders
  // against 2.1 for those with none.
  //
  // No delivery gate here on purpose: we are not making a claim about how well
  // the product works, we are telling someone their own credits are sitting
  // unspent. That is true regardless.
  let reorderSent = 0, reorderMarked = 0;
  const { data: reorder, error: rErr } = await sb.rpc("reorder_candidates", { p_limit: 100 });
  if (rErr) console.error("reorder_candidates failed:", rErr.message);

  for (const c of (reorder ?? []) as { user_id: string; balance: number; last_service: string | null }[]) {
    const { data: devices } = await sb
      .from("push_devices").select("token, environment").eq("user_id", c.user_id);
    if (!devices || devices.length === 0) {
      await sb.rpc("bump_reorder_nudge", { p_user: c.user_id });
      reorderMarked++;
      continue;
    }
    let anyOk = false;
    for (const d of devices) {
      try {
        const svc = c.last_service ?? "verification";
        const r = await sendPush(d.token, {
          alertTitle: "Need another number?",
          alertBody: `${c.balance} credit${c.balance === 1 ? "" : "s"} ready — your last ${svc} code came through.`,
          customData: { winback: "reorder" },
        }, d.environment as "sandbox" | "production");
        if (r.ok) { anyOk = true; reorderSent++; }
        else {
          failed++; console.error("APNs status", r.status, r.body);
          await pruneIfDead(d.token, r.status, r.body);
        }
      } catch (e) {
        failed++; console.error("APNs send failed:", e);
      }
    }
    if (anyOk) { await sb.rpc("bump_reorder_nudge", { p_user: c.user_id }); reorderMarked++; }
  }

  // ── Cohort 4: LINE EXPIRY — auto-renew off, number about to be deleted ───
  //
  // Not a winback. These are paying customers using the product: on
  // 2026-09-10, 6 of the 8 active monthly lines had auto-renew OFF while
  // averaging 27 calls in 8 days. There is NO HOLD on lapse —
  // reclaim_lapsed_lines suspends and release-lines deletes the number at
  // Telnyx within ~30 min — and until this cohort nothing told them. Two
  // stages per billing period, deduped on the expires_at they were sent for,
  // so a renewal re-arms both: "3d" (4 days → 36 h out) and "1d" (≤ 36 h).
  // On the daily cadence the 3d push lands 3–4 days out, the 1d push 12–36 h
  // out. No gate: the claim is about their own subscription, true regardless.
  //
  // `kind: "line_expiry"` — PushManager checks `kind` first and an
  // unrecognised one opens the app with no navigation (it launches on the
  // Number tab anyway). It must carry no `orderId`.
  let lineExpirySent = 0, lineExpiryMarked = 0;
  const { data: expiring, error: lErr } = await sb.rpc("line_expiry_nudge_candidates", { p_limit: 100 });
  if (lErr) console.error("line_expiry_nudge_candidates failed:", lErr.message);

  for (const c of (expiring ?? []) as {
    user_id: string; original_transaction_id: string; e164: string;
    expires_at: string; stage: "3d" | "1d";
  }[]) {
    const { data: devices } = await sb
      .from("push_devices").select("token, environment").eq("user_id", c.user_id);
    const when = c.stage === "1d" ? "tomorrow" : "in 3 days";
    let anyOk = false;
    for (const d of devices ?? []) {
      try {
        const r = await sendPush(d.token, {
          alertTitle: `Your number expires ${when}`,
          alertBody: `${c.e164} will be released and can't be recovered — auto-renew ` +
            `is off. Turn it back on under Subscriptions in your Apple Account ` +
            `settings to keep it.`,
          customData: { kind: "line_expiry" },
        }, d.environment as "sandbox" | "production");
        if (r.ok) { anyOk = true; lineExpirySent++; }
        else {
          failed++; console.error("APNs status", r.status, r.body);
          await pruneIfDead(d.token, r.status, r.body);
        }
      } catch (e) {
        failed++; console.error("APNs send failed:", e);
      }
    }
    // Mark only on an accepted send so a transient APNs failure retries on the
    // next run. The candidate fn requires a device, and pruneIfDead removes a
    // dead one, so a user with no live token drops out rather than looping.
    if (anyOk) {
      const { error: mErr } = await sb.rpc("mark_line_expiry_nudged", {
        p_original_transaction_id: c.original_transaction_id,
        p_stage: c.stage, p_expires_at: c.expires_at,
      });
      if (mErr) console.error("mark_line_expiry_nudged failed:", mErr.message);
      else lineExpiryMarked++;
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
    reorderCandidates: reorder?.length ?? 0, reorderSent, reorderMarked,
    lineExpiryCandidates: expiring?.length ?? 0, lineExpirySent, lineExpiryMarked,
    strandedGate: { balUsd, failing, wdFresh, claimSafe },
    failed,
  });
});
