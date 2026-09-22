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
  sendMessage, ownerChatId, esc, answerCallback, editReplyMarkup,
} from "../_shared/telegram.ts";
// Instagram publishing. This is the ONLY caller of publishImage in the
// codebase, reachable only from the owner's Post tap below.
import { publishImage } from "../_shared/instagram.ts";
import { runCommand } from "../_shared/tgHandlers.ts";
// Support replies push to the user's device. Imported explicitly for the reason
// in the note above — a free identifier here bundles fine and throws at runtime.
import { sendPush } from "../_shared/apns.ts";

declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined;

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
      message?: { chat?: { id?: number | string }; message_id?: number };
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
  cb: { id?: string; data?: string; message?: { message_id?: number } },
): Promise<Response> {
  const ok = () => json({ ok: true });
  const data = cb.data ?? "";

  // Instagram draft decision (insta-draft). Gated like everything here on the
  // secret token AND the owner chat id, checked by the caller.
  const insta = /^insta:(post|skip):([0-9a-f-]{36})$/.exec(data);
  if (insta) return await handleInstaDecision(cb, insta[1] as "post" | "skip", insta[2]);

  // Reddit radar triage. Both buttons only RECORD what the owner did on
  // Reddit by hand — neither posts anything, and nothing downstream reads
  // `status` to decide to act. It exists so /leads can show a working list
  // instead of every thread ever surfaced.
  const lead = /^lead:(done|skip):(\d+)$/.exec(data);
  if (lead) {
    const [, verb, id] = lead;
    const sb = admin();
    // Claim-gated on `notified`, same shape as the support accept below: a
    // stale button from an old push cannot re-open a lead already dealt with.
    const { data: claimed, error } = await sb
      .from("reddit_leads")
      .update({
        status: verb === "done" ? "replied" : "skipped",
        acted_at: new Date().toISOString(),
      })
      .eq("id", id).eq("status", "notified")
      .select("id");
    if (error) console.error(`lead ${verb}: ${error.message}`);
    await answerCallback(
      cb.id ?? "",
      claimed?.length
        ? (verb === "done" ? "Marked replied." : "Skipped.")
        : "Already handled.",
    );
    return ok();
  }

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

/** [✅ Post] / [🚫 Skip] on an Instagram draft from insta-draft.
 *
 *  🔴 Atomic claim: the row moves pending → publishing|skipped with
 *  `.eq("status","pending")` and a row-count check, so a double-tap, a
 *  Telegram retry of the same update, or a stale button from an old draft can
 *  never publish twice. Only the claim winner reaches Instagram.
 *
 *  Telegram must get its 200 promptly — container processing can take tens of
 *  seconds — so the publish runs in EdgeRuntime.waitUntil and reports back with
 *  a follow-up message. */
async function handleInstaDecision(
  cb: { id?: string; message?: { message_id?: number } },
  verb: "post" | "skip",
  id: string,
): Promise<Response> {
  const ok = () => json({ ok: true });
  const sb = admin();

  const { data: claimed, error } = await sb
    .from("insta_posts")
    .update({
      status: verb === "post" ? "publishing" : "skipped",
      decided_at: new Date().toISOString(),
    })
    .eq("id", id).eq("status", "pending")
    .select("id, image_url, caption, headline, tg_message_id");
  if (error) {
    console.error(`insta ${verb} claim ${id}: ${error.message}`);
    await answerCallback(cb.id ?? "", "Couldn't record that — try again.");
    return ok();
  }
  const row = claimed?.[0];
  if (!row) {
    await answerCallback(cb.id ?? "", "Already handled.");
    return ok();
  }

  // Take the buttons off so a decided draft cannot even be tapped again.
  // Cosmetic — the claim above is what actually prevents a second action.
  const msgId = cb.message?.message_id ??
    (row.tg_message_id != null ? Number(row.tg_message_id) : null);
  if (msgId != null) await editReplyMarkup(msgId, null);

  if (verb === "skip") {
    await answerCallback(cb.id ?? "", "Skipped.");
    return ok();
  }

  await answerCallback(cb.id ?? "", "Publishing to Instagram…");
  const work = publishInsta(
    id, String(row.image_url ?? ""), String(row.caption ?? ""), String(row.headline ?? ""),
  );
  if (typeof EdgeRuntime !== "undefined") EdgeRuntime.waitUntil(work);
  else await work;
  return ok();
}

/** Runs off the response path. Every outcome is written to the row AND told to
 *  the owner. A row stuck at `publishing` means this worker died mid-call — the
 *  post MAY be live, so check Instagram by hand; nothing retries it. */
async function publishInsta(
  id: string, imageUrl: string, caption: string, headline: string,
): Promise<void> {
  const sb = admin();
  try {
    if (!imageUrl || !caption) throw new Error("draft_missing_image_or_caption");
    const out = await publishImage(sb, imageUrl, caption);

    if (out.mediaId) {
      const { error } = await sb.from("insta_posts").update({
        status: "published", ig_media_id: out.mediaId, ig_container_id: out.containerId,
        published_at: new Date().toISOString(), error: null,
      }).eq("id", id).eq("status", "publishing");
      if (error) console.error(`insta publish ${id}: published-row write failed: ${error.message}`);
      await sendMessage(
        `✅ <b>Posted to Instagram</b> — ${esc(headline)}\n<i>media ${esc(out.mediaId)}</i>` +
        (error
          ? `\n⚠️ <i>The post IS live, but its row did not update: ${esc(error.message)}</i>`
          : ""),
      );
      return;
    }

    const reason = (out.error ?? "unknown").slice(0, 1000);
    const { error } = await sb.from("insta_posts").update({
      status: "failed", ig_container_id: out.containerId, error: reason,
    }).eq("id", id).eq("status", "publishing");
    if (error) console.error(`insta publish ${id}: failed-row write failed: ${error.message}`);
    await sendMessage(
      `⚠️ <b>Instagram post failed</b> — ${esc(headline)}\n` +
      `<code>${esc(reason.slice(0, 600))}</code>\n` +
      (out.containerId
        ? `<i>Check Instagram before retrying — a failure at the final step can still leave the post live.</i>`
        : `<i>Nothing was published.</i>`),
    );
  } catch (e) {
    const msg = String(e).slice(0, 600);
    console.error(`insta publish ${id}: ${msg}`);
    const { error } = await sb.from("insta_posts")
      .update({ status: "failed", error: msg }).eq("id", id).eq("status", "publishing");
    if (error) console.error(`insta publish ${id}: failed-row write failed: ${error.message}`);
    await sendMessage(`⚠️ <b>Instagram post failed</b>\n<code>${esc(msg)}</code>`);
  }
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
