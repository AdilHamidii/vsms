// A user writes to support. Store it, then relay it to the owner on Telegram.
//
// The relay carries an [Accept] button on the FIRST message of a thread, and
// the owner answers by replying to the relayed message — see
// `telegram-webhook`, which is the other half of this.

import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import { sendMessageWithId, esc } from "../_shared/telegram.ts";

interface Body { body: string; }

/** Enough for a real question, short enough that Telegram never truncates and
 *  the DB CHECK never rejects something the client thought it had sent. */
const MAX_LEN = 2000;

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, { status: 405 });

  const userId = await callerUserId(req);
  if (!userId) return json({ error: "unauthorized" }, { status: 401 });

  let body: Body;
  try { body = await req.json(); }
  catch { return json({ error: "invalid_body" }, { status: 400 }); }

  const text = (body.body ?? "").trim();
  if (!text) return json({ error: "empty_message" }, { status: 400 });
  if (text.length > MAX_LEN) return json({ error: "message_too_long" }, { status: 400 });

  const sb = admin();

  // Store FIRST, relay second. If Telegram is down the user's message must
  // still exist — the owner can find it in the thread later, and the user has
  // not been told "sent" about something that vanished.
  const { data: posted, error: postErr } = await sb.rpc("post_support_message", {
    p_user: userId, p_body: text, p_sender: "user",
  });
  if (postErr) {
    console.error(`support-send: post failed user=${userId}: ${postErr.message}`);
    return json({ error: "message_failed" }, { status: 500 });
  }
  const res = posted as
    { ok?: boolean; reason?: string; thread_id?: string; message_id?: string; new_thread?: boolean } | null;
  if (!res?.ok || !res.thread_id || !res.message_id) {
    return json({ error: res?.reason ?? "message_failed" }, { status: 400 });
  }

  // Context worth having in the notification: who, how much they have spent,
  // and whether they are mid-order. Answering "did your code arrive?" without
  // it means a round-trip before the owner can help at all.
  const { data: profile } = await sb
    .from("profiles").select("display_name").eq("user_id", userId).maybeSingle();
  const { data: wallet } = await sb
    .from("wallets").select("balance").eq("user_id", userId).maybeSingle();
  const { data: liveOrder } = await sb
    .from("orders")
    .select("service_id, country_id, smspva_number, created_at")
    .eq("user_id", userId).eq("status", "waiting")
    .order("created_at", { ascending: false }).limit(1).maybeSingle();

  const who = profile?.display_name?.trim() || `user ${userId.slice(0, 8)}`;
  const lines = [
    `💬 <b>Support</b> — ${esc(who)}`,
    `<code>${esc(userId)}</code>`,
    `Balance: <b>${wallet?.balance ?? 0}</b> cr`,
  ];
  if (liveOrder) {
    lines.push(
      `⏳ Waiting on <b>${esc(liveOrder.service_id)}</b>/${esc(liveOrder.country_id)}` +
      (liveOrder.smspva_number ? ` · <code>${esc(liveOrder.smspva_number)}</code>` : " · no number yet"),
    );
  }
  lines.push("", esc(text), "", "<i>Reply to this message to answer.</i>");

  const tgId = await sendMessageWithId(lines.join("\n"), {
    // Only the first message of a thread offers Accept — after that the owner
    // is already the agent and the button would be noise.
    replyMarkup: res.new_thread
      ? { inline_keyboard: [[{ text: "✅ Accept", callback_data: `sup:accept:${res.thread_id}` }]] }
      : undefined,
  });

  if (tgId != null) {
    // Record Telegram's id so a reply to THIS message resolves to THIS thread.
    // Matching on a thread's latest id instead would misroute the moment the
    // owner scrolls up and answers an older message, which is exactly what
    // happens with two conversations open.
    const { error: mapErr } = await sb
      .from("support_messages").update({ tg_message_id: tgId }).eq("id", res.message_id);
    if (mapErr) {
      console.error(
        `support-send: tg map failed msg=${res.message_id} tg=${tgId}: ${mapErr.message} ` +
        `— the owner's reply to this message cannot be routed`,
      );
    }
  } else {
    console.error(`support-send: RELAY FAILED thread=${res.thread_id} — message stored, owner not notified`);
  }

  return json({ thread_id: res.thread_id, relayed: tgId != null });
});
