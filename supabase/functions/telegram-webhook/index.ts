// Public endpoint that Telegram POSTs updates to, so the operator can query the
// business on demand (/stats, /today, /balance).
//
// THREAT MODEL: this URL is guessable and, unlike every other function here, it
// is not behind a JWT or the cron secret — Telegram's servers must be able to
// reach it. Two independent checks, both required:
//
//   1. X-Telegram-Bot-Api-Secret-Token must equal TELEGRAM_WEBHOOK_SECRET.
//      Telegram echoes back the secret_token given to setWebhook, so a caller
//      who doesn't know it cannot impersonate Telegram.
//   2. message.chat.id must equal TELEGRAM_CHAT_ID. Even if the secret leaked,
//      a stranger messaging the bot gets nothing.
//
// Every rejection returns a silent 200 with no reply. A 401 would confirm the
// endpoint exists and that a guessed secret was wrong; 200 tells an attacker
// nothing and also stops Telegram retrying.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import { sendMessage, ownerChatId } from "../_shared/telegram.ts";
import { formatDigest } from "../_shared/opsFormat.ts";

const HELP = [
  "🤖 <b>vSMS ops</b>",
  "",
  "/stats — last 6 hours",
  "/today — last 24 hours",
  "/week — last 7 days",
  "/balance — SMSPool balance",
].join("\n");

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;

  // Silent 200 on every rejection — see threat model above.
  const ok = () => json({ ok: true });

  const secret = Deno.env.get("TELEGRAM_WEBHOOK_SECRET");
  if (!secret || req.headers.get("x-telegram-bot-api-secret-token") !== secret) {
    return ok();
  }

  let update: {
    message?: { chat?: { id?: number | string }; text?: string };
  };
  try { update = await req.json(); } catch { return ok(); }

  const chatId = update.message?.chat?.id;
  if (chatId == null || String(chatId) !== ownerChatId()) return ok();

  const text = (update.message?.text ?? "").trim().toLowerCase();
  const cmd = text.split(/\s+/)[0].replace(/@.*$/, "");   // strip @botname suffix

  const sb = admin();
  let reply = HELP;

  if (cmd === "/stats" || cmd === "/today" || cmd === "/week") {
    const window = cmd === "/stats" ? "6 hours" : cmd === "/today" ? "24 hours" : "7 days";
    const { data: snap, error } = await sb.rpc("ops_snapshot", { p_window: window });
    reply = error || !snap
      ? "⚠️ Couldn't read stats right now."
      : formatDigest(snap as Record<string, unknown>);
  } else if (cmd === "/balance") {
    // BOTH providers. Reporting only SMSPool here survived the 2026-07-20
    // migration and became actively misleading: it alarmed about the provider
    // that now only funds eSIMs, while the balance gating every SMS order
    // (SMSPVA) was not shown at all.
    const { data: rows } = await sb
      .from("app_config").select("key, value")
      .in("key", ["smspva_health", "smspool_health"]);

    const read = (k: string) => {
      const v = (rows ?? []).find((r) => r.key === k)?.value as
        { balance_usd?: number; checked_at?: string } | null | undefined;
      return v ?? null;
    };
    const pva = read("smspva_health"), pool = read("smspool_health");
    const checked = pva?.checked_at ?? pool?.checked_at;

    reply = [
      balanceLine("SMSPVA", pva?.balance_usd),
      balanceLine("SMSPool", pool?.balance_usd),
      checked ? `\n<i>checked ${esc(checked)}</i>` : "",
    ].filter(Boolean).join("\n");
  }

  await sendMessage(reply);
  return ok();
});
