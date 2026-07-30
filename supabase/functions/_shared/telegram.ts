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

/** sendMessage, but it hands back Telegram's `message_id` and can attach an
 *  inline keyboard.
 *
 *  `sendMessage` above deliberately drops the body on success — it is a
 *  fire-and-forget alert path and nothing needs the id. Support chat does: the
 *  owner answers by REPLYING to the relayed message, and
 *  `message.reply_to_message.message_id` is the only thing tying that reply back
 *  to a thread. Without the id there is no route home.
 *
 *  Returns null on any failure rather than throwing — a support relay that
 *  cannot reach Telegram must still leave the user's message stored. */
export async function sendMessageWithId(
  html: string,
  opts: { replyMarkup?: unknown; chatId?: string } = {},
): Promise<number | null> {
  try {
    const resp = await fetch(`${BASE}/bot${token()}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        chat_id: opts.chatId ?? ownerChatId(),
        text: html.length > MAX_LEN ? `${html.slice(0, MAX_LEN)}\n…` : html,
        parse_mode: "HTML",
        disable_web_page_preview: true,
        ...(opts.replyMarkup ? { reply_markup: opts.replyMarkup } : {}),
      }),
      signal: AbortSignal.timeout(5000),
    });
    if (!resp.ok) {
      console.error(`sendMessageWithId: HTTP ${resp.status} ${await resp.text()}`);
      return null;
    }
    const body = await resp.json() as { result?: { message_id?: number } };
    return body.result?.message_id ?? null;
  } catch (e) {
    console.error(`sendMessageWithId: ${String(e)}`);
    return null;
  }
}

/** Acknowledge an inline-button tap. Telegram shows a spinner on the button
 *  until this is called, so skipping it makes the bot look hung. */
export async function answerCallback(id: string, text?: string): Promise<void> {
  try {
    await fetch(`${BASE}/bot${token()}/answerCallbackQuery`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ callback_query_id: id, text: text ?? "" }),
      signal: AbortSignal.timeout(5000),
    });
  } catch { /* cosmetic only */ }
}

/** Fire-and-forget variant for use inside a USER'S request path (purchases).
 *  Swallows everything — a missing token, a network failure, a malformed
 *  message must never affect someone's purchase. The per-minute sweep in
 *  telegram-notify re-sends anything that fails here. */
/// Never throws. Returns whether the message actually reached Telegram, so a
/// caller that stamps dedupe/suppression state can avoid recording an alert
/// that was never delivered. Callers that don't care may ignore the result —
/// the swallowing behaviour is unchanged.
export async function notifySafe(html: string): Promise<boolean> {
  try {
    const r = await sendMessage(html);
    if (!r.ok) {
      console.error("telegram send failed", r.status, r.body);
      return false;
    }
    return true;
  } catch (e) {
    console.error("telegram notify threw (swallowed):", e);
    return false;
  }
}
