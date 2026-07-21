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
const SWEEP_WINDOW_MIN = 30;      // re-check recent history, not all of time
const DIGEST_EVERY_MS = 6 * 60 * 60 * 1000;

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
      await claimAndSend("signup", p.user_id,
        `👤 <b>New signup</b>\n${name}\n<i>3 free credits granted</i>`);
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
