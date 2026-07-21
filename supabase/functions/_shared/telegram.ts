// Telegram Bot API adapter — outbound operator alerts.
//   Base: https://api.telegram.org/bot<TOKEN>
//   Auth: the bot token is part of the URL path (not a header).
//
// Modelled on apns.ts: required env is read through a throwing accessor, and
// sendMessage NEVER throws on an HTTP failure — it returns a status object, so
// a Telegram outage can never propagate into a caller's request path.

const BASE = "https://api.telegram.org";

function token(): string {
  const t = Deno.env.get("TELEGRAM_BOT_TOKEN");
  if (!t) throw new Error("TELEGRAM_BOT_TOKEN env var not set");
  return t;
}

/** The operator's own chat. Also the allowlist for inbound commands. */
export function ownerChatId(): string {
  const c = Deno.env.get("TELEGRAM_CHAT_ID");
  if (!c) throw new Error("TELEGRAM_CHAT_ID env var not set");
  return c;
}

/** HTML parse_mode needs only these three escaped — versus MarkdownV2's 18
 *  reserved characters, which break on any service name containing a "." or
 *  "-" (leboncoin, twitter-x, apple-id …). */
export function esc(s: unknown): string {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

export interface SendResult { ok: boolean; status: number; body?: string }

/** Telegram hard-caps a message at 4096 characters and 400s the whole send if
 *  you exceed it — which, on a fire-and-forget path, loses the alert silently. */
const MAX_LEN = 4000;

/** POST /sendMessage. Returns a status object; never throws on HTTP failure. */
export async function sendMessage(html: string, chatId?: string): Promise<SendResult> {
  let resp: Response;
  try {
    resp = await fetch(`${BASE}/bot${token()}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        chat_id: chatId ?? ownerChatId(),
        text: html.length > MAX_LEN ? `${html.slice(0, MAX_LEN)}\n…` : html,
        parse_mode: "HTML",
        disable_web_page_preview: true,
      }),
      // Without this a hung connection to Telegram keeps the isolate alive for
      // the platform's full timeout — on the purchase path that is a real cost.
      signal: AbortSignal.timeout(5000),
    });
  } catch (e) {
    return { ok: false, status: 0, body: String(e) };
  }
  return { ok: resp.ok, status: resp.status, body: resp.ok ? undefined : await resp.text() };
}

/** Fire-and-forget variant for use inside a USER'S request path (purchases).
 *  Swallows everything — a missing token, a network failure, a malformed
 *  message must never affect someone's purchase. The per-minute sweep in
 *  telegram-notify re-sends anything that fails here. */
export async function notifySafe(html: string): Promise<void> {
  try {
    const r = await sendMessage(html);
    if (!r.ok) console.error("telegram send failed", r.status, r.body);
  } catch (e) {
    console.error("telegram notify threw (swallowed):", e);
  }
}
