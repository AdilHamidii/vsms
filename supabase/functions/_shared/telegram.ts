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

/**
 * Split an over-long message into ordered parts instead of truncating it.
 *
 * Until 2026-08-21 anything over MAX_LEN was `slice(0, MAX_LEN) + "…"`, i.e.
 * the TAIL was dropped with no log and no way to tell a truncated message from
 * one that happened to fit. The tail is routinely the part that matters: the
 * end of a list of orphan numbers still billing at Telnyx, the last group of a
 * grouped watchdog page, the action line of an alert.
 *
 * Splits at the last "\n" inside the budget; a single line longer than the
 * budget is hard-cut, because there is no newline to split on and dropping it
 * entirely would be worse.
 *
 * TWO THINGS THE HARD CUT MUST NOT DO, both of which make Telegram answer
 * `400 can't parse entities` and lose the WHOLE message (sendMessage returns
 * !ok on the first part, and telegram-notify then releases the claim and
 * rebuilds the same doomed message every minute, forever):
 *
 *   1. cut inside a tag — `…yyy<b` — so the cut is backed up to before the
 *      last unclosed "<";
 *   2. cut BETWEEN an opening tag and its close, orphaning either half. Any
 *      tag still open at the end of a part is closed there and reopened at the
 *      start of the next, so every part is independently well-formed.
 *
 * Pure and exported so it is testable without a bot token.
 */

/** The inline tags this codebase emits. Anything else is left alone — an
 *  unknown tag is not something to guess the nesting rules of. `<a>` is
 *  deliberately ABSENT: reopening it would have to invent an href, and
 *  Telegram rejects a bare <a> outright. Nothing here emits one today. */
const SPLIT_TAG_RE = /<(\/?)(b|strong|i|em|u|s|code|pre)\b[^>]*>/gi;

/** Close whatever is still open at the end of each part and reopen it at the
 *  start of the next. The stack carries ACROSS parts, which is the point. */
function balanceParts(parts: string[]): string[] {
  const open: string[] = [];
  return parts.map((part) => {
    const prefix = open.map((t) => `<${t}>`).join("");
    SPLIT_TAG_RE.lastIndex = 0;
    let m: RegExpExecArray | null;
    while ((m = SPLIT_TAG_RE.exec(part)) !== null) {
      const tag = m[2].toLowerCase();
      if (m[1] === "/") {
        const i = open.lastIndexOf(tag);
        if (i >= 0) open.splice(i, 1);
      } else {
        open.push(tag);
      }
    }
    const suffix = [...open].reverse().map((t) => `</${t}>`).join("");
    return prefix + part + suffix;
  });
}

export function splitForTelegram(html: string, maxLen = MAX_LEN): string[] {
  // Reserve room for the " (n/m)" suffix appended below (8 chars covers up to
  // "(99/99)") AND for the reopen/close tags balanceParts may add to a part.
  // Without the second reserve a repaired part can exceed Telegram's own cap.
  const budget = maxLen - 8 - 48;
  if (html.length <= maxLen) return [html];

  const parts: string[] = [];
  let rest = html;
  while (rest.length > maxLen) {
    let cut = rest.lastIndexOf("\n", budget);
    if (cut <= 0) {
      // One giant line: hard-cut, but never through a tag. If the last "<"
      // inside the budget has no ">" after it, that tag is still open at the
      // cut point — back up to before it.
      cut = budget;
      const lt = rest.lastIndexOf("<", cut - 1);
      const gt = rest.lastIndexOf(">", cut - 1);
      if (lt > gt && lt > 0) cut = lt;
    }
    parts.push(rest.slice(0, cut).trimEnd());
    rest = rest.slice(cut).replace(/^\n/, "");
  }
  if (rest.length > 0) parts.push(rest);

  const total = parts.length;
  return balanceParts(parts).map((p, i) => `${p}\n(${i + 1}/${total})`);
}

/** POST /sendMessage. Returns a status object; never throws on HTTP failure.
 *
 *  An over-length message is SPLIT and sent as sequential parts, in order. The
 *  result describes the whole send: ok only if every part landed, and the first
 *  failure's status/body is what comes back (a partially-delivered alert is a
 *  failed alert as far as any dedupe stamp is concerned). */
export async function sendMessage(html: string, chatId?: string): Promise<SendResult> {
  const parts = splitForTelegram(html);
  if (parts.length > 1) {
    console.warn(`telegram: message split into ${parts.length} parts (${html.length} chars)`);
  }
  let last: SendResult = { ok: true, status: 200 };
  for (const part of parts) {
    last = await sendOne(part, chatId);
    if (!last.ok) return last;
  }
  return last;
}

async function sendOne(text: string, chatId?: string): Promise<SendResult> {
  let resp: Response;
  try {
    resp = await fetch(`${BASE}/bot${token()}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        chat_id: chatId ?? ownerChatId(),
        text,
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
 *  cannot reach Telegram must still leave the user's message stored.
 *
 *  On a split, the id returned is the LAST part's — that is the message sitting
 *  at the bottom of the chat, which is the one a phone reader taps "reply" on.
 *  Replying to an earlier part falls through to command parsing (the owner gets
 *  the help text) rather than misrouting to another thread, so the failure mode
 *  is visible. The inline keyboard rides on the last part for the same reason. */
export async function sendMessageWithId(
  html: string,
  opts: { replyMarkup?: unknown; chatId?: string } = {},
): Promise<number | null> {
  const parts = splitForTelegram(html);
  if (parts.length > 1) {
    console.warn(`telegram: relayed message split into ${parts.length} parts (${html.length} chars)`);
  }
  let id: number | null = null;
  for (let i = 0; i < parts.length; i++) {
    const isLast = i === parts.length - 1;
    try {
      const resp = await fetch(`${BASE}/bot${token()}/sendMessage`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          chat_id: opts.chatId ?? ownerChatId(),
          text: parts[i],
          parse_mode: "HTML",
          disable_web_page_preview: true,
          ...(opts.replyMarkup && isLast ? { reply_markup: opts.replyMarkup } : {}),
        }),
        signal: AbortSignal.timeout(5000),
      });
      if (!resp.ok) {
        console.error(`sendMessageWithId: HTTP ${resp.status} ${await resp.text()}`);
        return null;
      }
      const body = await resp.json() as { result?: { message_id?: number } };
      id = body.result?.message_id ?? id;
    } catch (e) {
      console.error(`sendMessageWithId: ${String(e)}`);
      return null;
    }
  }
  return id;
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
