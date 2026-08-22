// Public endpoint that Telegram POSTs updates to, so the operator can query the
// business on demand (/now, /today, /balance).
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
//
// WHAT LIVES WHERE (2026-08-21): this file is now the TRANSPORT — auth, the
// support-chat routing that needs Telegram context, and sending. Every command
// body moved to `_shared/tgHandlers.ts` so telegram-setup can render one as a
// preview without starting a second Deno.serve, and the command METADATA moved
// to `_shared/tgCommands.ts` so the `/` autocomplete menu, /help and dispatch
// cannot disagree about which commands exist.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
// esc is used by the support paths below. Identifiers were referenced without
// being imported here for a while — esbuild bundles free identifiers without
// complaint, so /balance THREW ReferenceError on every call in production while
// every other command worked. Keep imports in lockstep with usage.
import {
  sendMessage, ownerChatId, esc, answerCallback,
} from "../_shared/telegram.ts";
import { runCommand } from "../_shared/tgHandlers.ts";
// Support replies push to the user's device. Imported explicitly for the reason
// in the note above — a free identifier here bundles fine and throws at runtime.
import { sendPush } from "../_shared/apns.ts";

// Re-exported so a reader who comes looking for the dispatcher in the function
// that used to own it finds the pointer rather than concluding it was deleted.
export { runCommand };

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;

  // Silent 200 on every rejection — see threat model above.
  const ok = () => json({ ok: true });

  const secret = Deno.env.get("TELEGRAM_WEBHOOK_SECRET");
  if (!secret || req.headers.get("x-telegram-bot-api-secret-token") !== secret) {
    return ok();
  }

  let update: {
    message?: {
      chat?: { id?: number | string };
      text?: string;
      reply_to_message?: { message_id?: number };
    };
    callback_query?: {
      id?: string;
      data?: string;
      message?: { chat?: { id?: number | string } };
    };
  };
  try { update = await req.json(); } catch { return ok(); }

  // ── Support chat ─────────────────────────────────────────────────────────
  // Two new update kinds, BOTH gated on the owner chat id exactly like
  // commands. A callback_query carries its chat under
  // `callback_query.message.chat.id`, NOT `message.chat.id` — reusing the old
  // path would have left the Accept button ungated.
  const cbChat = update.callback_query?.message?.chat?.id;
  if (update.callback_query && cbChat != null && String(cbChat) === ownerChatId()) {
    return await handleCallback(update.callback_query);
  }

  const chatId = update.message?.chat?.id;
  if (chatId == null || String(chatId) !== ownerChatId()) return ok();

  // A reply to a relayed support message is an ANSWER, not a command. Checked
  // before command parsing so an agent whose reply happens to start with "/"
  // still reaches the user instead of being swallowed as an unknown command.
  const replyTo = update.message?.reply_to_message?.message_id;
  if (replyTo != null && (update.message?.text ?? "").trim() !== "") {
    const handled = await handleAgentReply(replyTo, update.message!.text!.trim());
    if (handled) return ok();
    // Not a support reply — fall through and treat it as a normal command.
  }

  // Plain text, no leading "/", while a conversation is assigned → it is an
  // ANSWER to that conversation, not a mistyped command.
  //
  // Without this, accepting a chat and then simply typing a reply — the obvious
  // thing to do, and what "I get to be the support to that user" means — got
  // swallowed by the command parser and answered with the help text. The user
  // waiting on the other end saw nothing at all.
  //
  // Replies still take precedence above, and remain the way to target a
  // specific conversation when several are open; this only covers the case
  // where the owner is plainly talking to the one they just accepted.
  const raw = (update.message?.text ?? "").trim();
  if (raw !== "" && !raw.startsWith("/") && update.message?.reply_to_message == null) {
    const routed = await routeToAssignedThread(raw);
    if (routed) return ok();
  }

  // Everything else is a command (or a typo, or prose that went nowhere —
  // runCommand answers all three, and the fallback for the last one explains
  // WHY it went nowhere rather than dumping a command list).
  const reply = await runCommand(raw);

  await sendMessage(reply);
  return ok();
});

// ─────────────────────────────────────────────────────────────────────────────
// Support chat — the owner's half of the conversation.
//
// Callers have ALREADY checked the secret token and the owner chat id. Nothing
// below may be reached by anyone else.

/** [✅ Accept] on the first message of a thread. */
async function handleCallback(
  cb: { id?: string; data?: string },
): Promise<Response> {
  const ok = () => json({ ok: true });
  const data = cb.data ?? "";
  if (!data.startsWith("sup:accept:")) { await answerCallback(cb.id ?? ""); return ok(); }

  const threadId = data.slice("sup:accept:".length);
  const sb = admin();
  // Claim-gated: only an OPEN thread can be accepted, so a double-tap (or a
  // stale button from an old notification) cannot reopen a closed conversation.
  const { data: claimed, error } = await sb
    .from("support_threads")
    .update({ status: "assigned" })
    .eq("id", threadId).eq("status", "open")
    .select("id");
  if (error) console.error(`support accept: ${error.message}`);

  await answerCallback(
    cb.id ?? "",
    claimed?.length ? "You're on it — reply to the message to answer." : "Already handled.",
  );
  return ok();
}

/** The owner replied to a relayed message. Route it back to that user.
 *
 *  Returns false when the reply does not correspond to a support message, so
 *  the caller can fall through and treat it as an ordinary command. */
async function handleAgentReply(replyToId: number, text: string): Promise<boolean> {
  const sb = admin();

  // tg_message_id -> thread. Set when the message was relayed, which is why a
  // reply to ANY message in a thread works, not only the newest.
  const { data: src, error: findErr } = await sb
    .from("support_messages")
    .select("thread_id")
    .eq("tg_message_id", replyToId)
    .maybeSingle();
  if (findErr) {
    console.error(`support reply: lookup failed tg=${replyToId}: ${findErr.message}`);
    return false;
  }
  if (!src) return false;                      // replying to some other message

  const { data: thread, error: thErr } = await sb
    .from("support_threads").select("id, user_id, status").eq("id", src.thread_id).maybeSingle();
  if (thErr || !thread) {
    console.error(`support reply: thread missing for tg=${replyToId}`);
    return false;
  }

  const { data: posted, error: postErr } = await sb.rpc("post_support_message", {
    p_user: thread.user_id, p_body: text, p_sender: "agent",
  });
  if (postErr) {
    console.error(`support reply: post failed thread=${thread.id}: ${postErr.message}`);
    await sendMessage("⚠️ Couldn't deliver that reply — it was NOT sent to the user.");
    return true;
  }
  const res = posted as { ok?: boolean; reason?: string } | null;
  if (!res?.ok) {
    await sendMessage(`⚠️ Reply rejected (${esc(res?.reason ?? "unknown")}) — NOT sent.`);
    return true;
  }

  // Answering implies accepting: a thread the owner has replied to is theirs,
  // whether or not they pressed the button first.
  if (thread.status === "open") {
    await sb.from("support_threads").update({ status: "assigned" }).eq("id", thread.id);
  }

  // Wake the user. Without this the reply sits unread until they happen to
  // reopen the app, which for a support answer is most of its value gone.
  await pushSupportReply(sb, thread.user_id, text);
  return true;
}

/** Plain text from the owner while a conversation is assigned → send it there.
 *
 *  Returns false when there is nothing assigned, so the caller falls through to
 *  command parsing and an ordinary typo still gets the help text. */
async function routeToAssignedThread(text: string): Promise<boolean> {
  const sb = admin();

  // Most recently active assigned thread. With several open at once this is a
  // guess, which is why the confirmation below NAMES the recipient — the owner
  // must be able to see immediately that it went somewhere they did not mean,
  // and `reply` remains the way to target one explicitly.
  const { data: thread, error } = await sb
    .from("support_threads")
    .select("id, user_id")
    .eq("status", "assigned")
    .order("last_message_at", { ascending: false })
    .limit(1).maybeSingle();
  if (error) {
    console.error(`support route: lookup failed: ${error.message}`);
    return false;
  }
  if (!thread) return false;

  const { data: posted, error: postErr } = await sb.rpc("post_support_message", {
    p_user: thread.user_id, p_body: text, p_sender: "agent",
  });
  if (postErr) {
    console.error(`support route: post failed thread=${thread.id}: ${postErr.message}`);
    await sendMessage("⚠️ Couldn't deliver that — it was NOT sent to the user.");
    return true;
  }
  const res = posted as { ok?: boolean; reason?: string } | null;
  if (!res?.ok) {
    await sendMessage(`⚠️ Rejected (${esc(res?.reason ?? "unknown")}) — NOT sent.`);
    return true;
  }

  const { data: profile } = await sb
    .from("profiles").select("display_name").eq("user_id", thread.user_id).maybeSingle();
  const who = profile?.display_name?.trim() || `user ${String(thread.user_id).slice(0, 8)}`;

  await pushSupportReply(sb, thread.user_id, text);
  // Confirm, and say to WHOM. Silent delivery to an unnamed recipient is how
  // the owner ends up sending a private note into a customer conversation.
  await sendMessage(`✅ Sent to <b>${esc(who)}</b>.`);
  return true;
}

/** Best-effort APNs nudge. Never throws: a failed push must not make the owner
 *  think the message itself failed — it is stored and will render in-app. */
async function pushSupportReply(
  // deno-lint-ignore no-explicit-any
  sb: any, userId: string, text: string,
): Promise<void> {
  try {
    const { data: devices } = await sb
      .from("push_devices").select("token, environment").eq("user_id", userId);
    if (!devices?.length) return;
    for (const d of devices) {
      await sendPush(d.token, {
        alertTitle: "vSMS support",
        alertBody: text.length > 120 ? `${text.slice(0, 117)}…` : text,
        sound: "default",
        // No orderId: PushManager routes on that key, and a support reply is
        // not an order — carrying one would deep-link into the wrong screen.
        customData: { kind: "support" },
      }, d.environment === "sandbox" ? "sandbox" : undefined);
    }
  } catch (e) {
    console.error(`support push failed user=${userId}: ${String(e)}`);
  }
}
