// Called by pg_cron every minute (relay-telegram-notify). Two jobs:
//   1. Sweep new signups / credit purchases / eSIM purchases and alert on each.
//      Purchases and eSIMs are normally alerted INSTANTLY from their own edge
//      functions; this sweep is the safety net that catches anything whose
//      Telegram call failed, and is the only sender for signups (deliberately —
//      alerting on signup from a DB trigger would put a network call inside the
//      Supabase Auth transaction).
//   2. Emit the 6-hourly digest when due.
//
// Exactly-once is enforced by claiming a row in telegram_events before sending,
// so the instant path and this sweep can never double-send.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import { sendMessage, esc } from "../_shared/telegram.ts";
import { formatDigest } from "../_shared/opsFormat.ts";

const DEV_USER = "825688de-6117-4251-9f90-93b83b41b572";
// 24h, not 30 min: the claim rows make re-scans idempotent, so the only cost
// of a wide window is three small indexed scans per minute — while a narrow
// one PERMANENTLY dropped every signup alert whenever Telegram (or this
// function) was down longer than the window.
const SWEEP_WINDOW_MIN = 24 * 60;
const DIGEST_EVERY_MS = 6 * 60 * 60 * 1000;
const WATCHDOG_REALERT_MS = 6 * 60 * 60 * 1000;

function validateCronSecret(req: Request): boolean {
  const header = req.headers.get("x-cron-secret");
  const expected = Deno.env.get("CRON_SECRET");
  return !!header && !!expected && header === expected;
}

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;
  if (!validateCronSecret(req)) return json({ error: "unauthorized" }, { status: 401 });

  // Not configured yet (no BotFather token / chat id): no-op quietly rather
  // than throwing a 500 from the cron every single minute.
  if (!Deno.env.get("TELEGRAM_BOT_TOKEN") || !Deno.env.get("TELEGRAM_CHAT_ID")) {
    return json({ skipped: "telegram_not_configured" });
  }

  const sb = admin();
  const since = new Date(Date.now() - SWEEP_WINDOW_MIN * 60_000).toISOString();
  let sent = 0, failed = 0;

  // ── Watchdog alerting. run_watchdog() (plain-SQL pg_cron, every 10 min —
  //    survives even a dead edge/CRON_SECRET layer) writes its verdict to
  //    app_config.'watchdog'; this minutely run is the transport that turns
  //    that verdict into a page. Alerts when the failing set CHANGES or every
  //    6h while broken; sends a one-shot all-clear on recovery. If THIS
  //    function is dead the page can't go out — but then the digest below
  //    also stops, which is the documented human-observable backstop.
  try {
    const { data: wdRow } = await sb
      .from("app_config").select("value").eq("key", "watchdog").maybeSingle();
    if (wdRow?.value) {
      const w = wdRow.value as {
        failing?: { check?: string; detail?: string }[];
        last_alert_at?: string | null;
        alerted?: string[] | null;
        checked_at?: string | null;
      };
      const failing = [...(w.failing ?? [])];

      // THE WATCHDOG'S OWN DEATH WAS INVISIBLE. run_watchdog() stamps
      // checked_at every 10 minutes and nothing ever read it — so if the pg_cron
      // job were unscheduled, or the function raised, the last stored verdict
      // (today: `failing: []`) would persist forever and every channel would
      // report perfect health indefinitely. That is strictly worse than the
      // documented telegram-notify blind spot, which at least shows up as digest
      // silence. A stale verdict is now itself a failing check.
      const wdAgeMs = w.checked_at ? Date.now() - new Date(w.checked_at).getTime() : Infinity;
      if (wdAgeMs > 30 * 60 * 1000) {
        failing.push({
          check: "watchdog_stale",
          detail: w.checked_at
            ? `last ran ${Math.round(wdAgeMs / 60000)} min ago — the watchdog itself is not running`
            : "never recorded a run — the watchdog itself is not running",
        });
      }
      const names = failing.map((f) => f.check ?? "?").sort();
      const alerted = (w.alerted ?? []).slice().sort();
      const changed = JSON.stringify(names) !== JSON.stringify(alerted);
      const due = !w.last_alert_at ||
        Date.now() - new Date(w.last_alert_at).getTime() >= WATCHDOG_REALERT_MS;

      if (failing.length > 0 && (changed || due)) {
        const lines = failing.map((f) =>
          ` • <b>${esc(f.check)}</b> — ${esc(f.detail ?? "")}`);
        const r = await sendMessage(
          `🚨 <b>Watchdog: ${failing.length} backend job${failing.length === 1 ? "" : "s"} unhealthy</b>\n` +
          lines.join("\n") + `\n<i>runbook: docs/autopilot-runbook.md</i>`,
        );
        if (r.ok) {
          sent++;
          await sb.from("app_config").update({
            value: { ...w, last_alert_at: new Date().toISOString(), alerted: names },
          }).eq("key", "watchdog");
        } else { failed++; console.error("watchdog alert send failed", r.status, r.body); }
      } else if (failing.length === 0 && alerted.length > 0) {
        const r = await sendMessage(
          `✅ <b>Watchdog: all clear</b>\nrecovered: ${esc(alerted.join(", "))}`,
        );
        if (r.ok) {
          sent++;
          await sb.from("app_config").update({
            value: { ...w, last_alert_at: null, alerted: [] },
          }).eq("key", "watchdog");
        } else { failed++; console.error("watchdog all-clear send failed", r.status, r.body); }
      }
    }
  } catch (e) {
    console.error("watchdog alerting failed (sweep continues):", e);
  }

  /** Claim (kind, ref) and send. Returns true only if WE sent it. The claim is
   *  released again on send failure so the next run retries. */
  async function claimAndSend(kind: string, ref: string, html: string): Promise<boolean> {
    const { data: claimed, error } = await sb
      .from("telegram_events")
      .insert({ kind, ref })
      .select("ref")
      .maybeSingle();
    if (error || !claimed) return false;      // 23505 => another path sent it

    // The claim is already written, so ANY failure path below must release it
    // or that event can never be alerted again.
    let ok = false, detail = "";
    try {
      const r = await sendMessage(html);
      ok = r.ok;
      detail = ok ? "" : `${r.status} ${r.body ?? ""}`;
    } catch (e) {
      detail = String(e);
    }
    if (ok) { sent++; return true; }

    failed++;
    console.error(`telegram send failed kind=${kind} ref=${ref}`, detail);
    await sb.from("telegram_events").delete().eq("kind", kind).eq("ref", ref);
    return false;
  }

  // ── Signups. profiles.created_at is written by handle_new_user() in the same
  //    transaction as the auth.users row, so it is an exact signup timestamp.
  const { data: signups } = await sb
    .from("profiles")
    .select("user_id, display_name, created_at")
    .gte("created_at", since)
    .neq("user_id", DEV_USER);

  // One message each normally; a burst gets coalesced so a viral hour can't
  // hit Telegram's ~1 msg/sec-per-chat limit and lose alerts to rate limiting.
  const newSignups = signups ?? [];

  // The granted amount comes from the ledger, never a constant: the bonus has
  // already changed 5→1→3→1, and a hardcoded figure was lying within hours of
  // the last change.
  const bonusByUser = new Map<string, number>();
  if (newSignups.length > 0) {
    const { data: bonusRows } = await sb
      .from("wallet_transactions")
      .select("user_id, delta")
      .eq("reason", "signup_bonus")
      .in("user_id", newSignups.map((p) => p.user_id));
    for (const b of bonusRows ?? []) bonusByUser.set(b.user_id as string, b.delta as number);
  }
  if (newSignups.length > 3) {
    const refs: string[] = [];
    for (const p of newSignups) {
      const { data: claimed } = await sb
        .from("telegram_events").insert({ kind: "signup", ref: p.user_id })
        .select("ref").maybeSingle();
      if (claimed) refs.push(p.user_id);
    }
    if (refs.length > 0) {
      const r = await sendMessage(`👤 <b>${refs.length} new signups</b>`)
        .catch((e) => ({ ok: false, status: 0, body: String(e) }));
      if (r.ok) sent++;
      else {
        failed++;
        // Release every claim so the next run retries them.
        for (const ref of refs) {
          await sb.from("telegram_events").delete().eq("kind", "signup").eq("ref", ref);
        }
      }
    }
  } else {
    for (const p of newSignups) {
      const name = p.display_name ? esc(p.display_name) : "someone";
      const b = bonusByUser.get(p.user_id);
      const bonusLine = b != null
        ? `${b} free credit${b === 1 ? "" : "s"} granted`
        : "welcome credit granted";
      await claimAndSend("signup", p.user_id,
        `👤 <b>New signup</b>\n${name}\n<i>${bonusLine}</i>`);
    }
  }

  // ── Credit purchases (safety net; normally sent instantly by iap-verify).
  const { data: buys } = await sb
    .from("iap_receipts")
    .select("id, user_id, product_id, granted_credits, environment, created_at")
    .gte("created_at", since)
    .neq("user_id", DEV_USER);

  for (const b of buys ?? []) {
    const pack = String(b.product_id).split(".").pop();
    const sandbox = b.environment !== "Production" ? `\n<i>${esc(b.environment)}</i>` : "";
    await claimAndSend("purchase", String(b.id),
      `💳 <b>Credits purchased</b>\n${b.granted_credits} credits (pack ${esc(pack)})${sandbox}`);
  }

  // ── eSIM purchases (safety net; normally sent instantly by create-esim-order).
  const { data: esims } = await sb
    .from("esim_orders")
    .select("id, user_id, plan_id, cost_credits, status, created_at")
    .gte("created_at", since)
    .neq("user_id", DEV_USER);

  for (const e of esims ?? []) {
    await claimAndSend("esim", String(e.id),
      `🌍 <b>eSIM purchased</b>\n${e.cost_credits} credits · plan ${esc(e.plan_id)} · ${esc(e.status)}`);
  }

  // ── 6-hourly digest.
  let digest = false;
  const { data: cfg } = await sb
    .from("app_config").select("value").eq("key", "telegram_bot").maybeSingle();
  const lastAt = (cfg?.value as { last_digest_at?: string } | null)?.last_digest_at;
  const due = !lastAt || (Date.now() - new Date(lastAt).getTime()) >= DIGEST_EVERY_MS;

  if (due) {
    const { data: snap } = await sb.rpc("ops_snapshot", { p_window: "6 hours" });
    if (snap) {
      const r = await sendMessage(formatDigest(snap as Record<string, unknown>))
        .catch((e) => ({ ok: false, status: 0, body: String(e) }));
      if (r.ok) {
        digest = true;
        // Stamp only on success, so a failed digest retries next minute.
        await sb.from("app_config").upsert({
          key: "telegram_bot",
          value: { last_digest_at: new Date().toISOString() },
          updated_at: new Date().toISOString(),
        }, { onConflict: "key" });
      } else {
        failed++;
        console.error("digest send failed", r.status, r.body);
      }
    }
  }

  return json({ sent, failed, digest });
});
