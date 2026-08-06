// Public endpoint Telnyx POSTs events to: inbound SMS, delivery receipts,
// number-order completion, and (later) call events.
//
// ✅ The capture phase did its job and is retired. The verifier was validated
// against REAL Telnyx bytes before any business logic was hung off it — which
// is how we learned Telnyx sends PRETTY-PRINTED JSON (1,703 bytes vs 1,203
// re-serialised), so parsing before verifying would have silently discarded
// 500 bytes of signed content and every signature would have failed.
//
// The same capture settled the payload SHAPE, and one detail in it is a trap:
// `payload.to` is an ARRAY of objects, not a string. Reading it as a phone
// number yields "[object Object]" and matches no line.
//
// THREAT MODEL: this URL is guessable and, like telegram-webhook, cannot sit
// behind a JWT — Telnyx's servers must reach it. One gate, and it is
// cryptographic: Ed25519 over `${telnyx-timestamp}|${rawBody}`, plus a 300s
// replay window. It FAILS CLOSED. Every other provider path in this codebase
// degrades gracefully on an unreadable response; this one must not, because an
// unverified webhook is someone else's message written into a user's thread.
//
// ⚠️ MUST be deployed --no-verify-jwt. Telnyx sends no Authorization header, and
// config.toml has no entry for this function, so the flag is the only control.
// Deployed without it, every event 401s and the line goes silently deaf — the
// same failure telegram-webhook documents.
//
// ⚠️ ALWAYS returns 200, including on rejection. A non-2xx makes Telnyx RETRY,
// so a forged or malformed request would become a retry storm; and a 401 would
// confirm to an attacker that the endpoint exists and their guess was wrong.
// Rejections are counted instead, and the watchdog reads that counter.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import { verifyTelnyxRequest } from "../_shared/telnyx.ts";
import { sendPush } from "../_shared/apns.ts";

const SEEN_KEY = "telnyx_webhook_seen_at";
const REJECT_KEY = "telnyx_webhook_rejects";

Deno.serve(async (req) => {
  const pre = handleCors(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ ok: true }, { status: 200 });

  // 🔴 Read the body ONCE, as text, and verify the RAW bytes. Parsing first and
  // re-serialising verifies a DIFFERENT document than the one Telnyx signed —
  // key order and whitespace both change — and every signature would fail.
  // Parse only after the signature passes.
  const raw = await req.text();
  const result = verifyTelnyxRequest(req, raw);

  const sb = admin();

  if (!result.ok) {
    // Counted, not thrown. A silent 200 that also silently forgets would leave
    // a rotated signing key or a mis-set webhook URL completely invisible —
    // exactly the Telegram allowed_updates failure, where every callback_query
    // was dropped upstream with "nothing logged, no error, no trace".
    const { data } = await sb.from("app_config").select("value")
      .eq("key", REJECT_KEY).maybeSingle();
    const prev = (data?.value as { count?: number } | null)?.count ?? 0;
    await sb.from("app_config").upsert({
      key: REJECT_KEY,
      value: { count: prev + 1, last_reason: result.reason, at: new Date().toISOString() },
    }, { onConflict: "key" });

    console.error("telnyx-webhook rejected:", result.reason);
    return json({ ok: true }, { status: 200 });
  }

  let event: Record<string, unknown> = {};
  try {
    event = JSON.parse(raw);
  } catch {
    console.error("telnyx-webhook: verified signature but unparseable body");
  }
  const data = (event.data ?? {}) as Record<string, unknown>;
  const eventType = String(data.event_type ?? "unknown");

  // Liveness signal for run_watchdog. Silence here while an active line exists
  // is the symptom of a rotated signing key or a webhook URL pointing nowhere —
  // a failure that is otherwise completely invisible, because nothing errors.
  await sb.from("app_config").upsert({
    key: SEEN_KEY, value: { at: new Date().toISOString(), event_type: eventType },
  }, { onConflict: "key" });

  const payload = (data.payload ?? {}) as Record<string, unknown>;

  try {
    switch (eventType) {
      case "message.received":
        await handleInbound(sb, payload);
        break;
      // Delivery receipts. `message.sent` means the carrier accepted it;
      // `message.finalized` carries the terminal outcome.
      case "message.sent":
      case "message.finalized":
        await handleReceipt(sb, payload, eventType);
        break;
      default:
        // Recorded and ignored, never guessed at. Telnyx adds event types, and
        // encoding a guess about a vendor's vocabulary is what broke eSIM
        // refunds.
        console.log("telnyx-webhook unhandled:", eventType);
    }
  } catch (e) {
    // Swallowed on purpose: a non-2xx makes Telnyx RETRY, and a retry storm on
    // a bug we have not fixed yet is worse than one lost event. The error is
    // logged and the watchdog reads the liveness stamp above.
    console.error("telnyx-webhook handler failed:", eventType, String(e));
  }

  return json({ ok: true }, { status: 200 });
});

/** `payload.to` is an ARRAY of `{phone_number, status, …}`. Reading it as a
 *  string yields "[object Object]" and matches no line at all. */
function firstTo(payload: Record<string, unknown>): Record<string, unknown> | null {
  const to = payload.to;
  if (Array.isArray(to) && to.length) return to[0] as Record<string, unknown>;
  return null;
}

async function handleInbound(sb: ReturnType<typeof admin>, payload: Record<string, unknown>) {
  const from = (payload.from ?? {}) as Record<string, unknown>;
  const to = firstTo(payload);
  const ourNumber = String(to?.phone_number ?? "");
  const peer = String(from.phone_number ?? "");
  if (!ourNumber || !peer) return;

  // Which line owns this number. A message for a number we released — or never
  // owned — is dropped rather than guessed at.
  const { data: line } = await sb.from("phone_lines")
    .select("id, user_id, status").eq("e164", ourNumber)
    .in("status", ["active", "grace", "past_due", "provisioning"])
    .maybeSingle();
  if (!line) {
    console.log("telnyx-webhook: inbound for unknown/inactive number", ourNumber);
    return;
  }

  const { data: res, error } = await sb.rpc("record_inbound_message", {
    p_line_id: line.id,
    p_provider_id: String(payload.id ?? ""),
    p_from: peer,
    p_to: ourNumber,
    p_body: String(payload.text ?? ""),
    p_segments: Number(payload.parts ?? 1),
    p_received_at: payload.received_at ? String(payload.received_at) : null,
  });
  if (error) throw new Error(`record_inbound_message: ${error.message}`);
  if (res?.ok !== true) return;

  // ⚠️ `was_new` is the retry guard. Telnyx retries, and the partial unique
  // index makes the INSERT a no-op the second time — but the push is not
  // idempotent, so sending it unconditionally would buzz the user once per
  // retry for a message they already have.
  if (res.was_new !== true) return;

  // A blocked peer is stored but never announced. The row exists for report and
  // appeal; the user is not disturbed by it.
  if (res.blocked === true) return;

  await pushInbound(sb, String(res.user_id), peer, String(payload.text ?? ""),
                    String(res.thread_id ?? ""));
}

/** Delivery receipt → settle the outbound row and, on a terminal failure, hand
 *  the allowance back. This line has no money to refund, so the allowance is
 *  the only thing that can be made whole. */
async function handleReceipt(
  sb: ReturnType<typeof admin>, payload: Record<string, unknown>, eventType: string,
) {
  const providerId = String(payload.id ?? "");
  if (!providerId) return;

  const to = firstTo(payload);
  const raw = String(to?.status ?? "");

  // Telnyx's vocabulary, mapped to ours. Anything unrecognised is left alone
  // rather than forced into a terminal state — `line_msg_status` is OUR enum
  // and a wrong guess here would tell a user their message failed when it did
  // not. Same rule as `_shared/emailStatus.ts`.
  let status: string | null = null;
  if (eventType === "message.sent") status = "sent";
  if (raw === "delivered") status = "delivered";
  if (raw === "sending_failed" || raw === "delivery_failed") status = "failed";
  if (!status) return;

  // ⚠️ The claim function keys on the MESSAGE UUID, not the provider id — it
  // does `select ... where id = p_message for update`, which is what makes it a
  // claim at all. A receipt only carries Telnyx's id, so resolve it here.
  // `send-line-message` writes that id back onto the row immediately after the
  // send, which is what makes this lookup possible.
  // ⚠️ RETRIED ONCE. `send-line-message` writes the provider id back onto the
  // row immediately after the send returns, but Telnyx can deliver
  // `message.sent` before that write lands — and we ALWAYS return 200, so
  // Telnyx never retries a receipt we dropped. A single miss used to leave the
  // message `queued` forever with its segments spent. The 15-minute stale
  // sweep is the floor; this is what stops it being reached in the ordinary
  // race.
  let row = await findMessage(sb, providerId);
  if (!row) {
    await new Promise((r) => setTimeout(r, 1500));
    row = await findMessage(sb, providerId);
  }
  if (!row) {
    // Genuinely ours to drop: a receipt for a message we never recorded. The
    // stale sweep hands the allowance back on the row's own timer.
    console.log("telnyx-webhook: receipt for unknown message", providerId);
    return;
  }

  // Telnyx bills fractions of a cent per segment, so `Math.round(0.004 * 100)`
  // is 0 — which is why the exact figure goes into its own numeric column and
  // the rounded one is kept only for display.
  const cost = payload.cost as { amount?: string } | undefined;
  const costUsd = cost?.amount != null ? parseFloat(String(cost.amount)) : null;

  const { error } = await sb.rpc("settle_outbound_message_claim", {
    p_message: row.id,
    p_provider_id: providerId,
    p_status: status,
    p_cost_cents: costUsd != null ? Math.round(costUsd * 100) : null,
    p_error: status === "failed" ? raw : null,
    // Telnyx's own segment count is authoritative; ours is a local estimate
    // that errs low on purpose.
    p_segments: payload.parts != null ? Number(payload.parts) : null,
    p_cost_usd: Number.isFinite(costUsd as number) ? costUsd : null,
  });
  if (error) throw new Error(`settle_outbound_message_claim: ${error.message}`);
}

async function findMessage(
  sb: ReturnType<typeof admin>, providerId: string,
): Promise<{ id: string } | null> {
  const { data } = await sb.from("line_messages")
    .select("id").eq("provider_message_id", providerId).maybeSingle();
  return data ? { id: String(data.id) } : null;
}

/** Alert push for an inbound text.
 *
 *  ⚠️ Carries `kind` and `threadId`, never `orderId`. `PushManager` routes on
 *  `orderId` and would deep-link a text message into the SMS refund screen —
 *  the same trap the late-code rescue push had to avoid. */
async function pushInbound(
  sb: ReturnType<typeof admin>, userId: string, peer: string,
  text: string, threadId: string,
) {
  const { data: devices } = await sb.from("push_devices")
    .select("token, environment").eq("user_id", userId);
  if (!devices?.length) return;

  for (const d of devices) {
    await sendPush(String(d.token), {
      alertTitle: peer,
      // Truncated: a lock-screen preview is not the place for a 1,600-character
      // message, and the full text is one tap away.
      alertBody: text.length > 140 ? text.slice(0, 139) + "…" : text,
      customData: { kind: "line_message", threadId },
    }, (d.environment as "sandbox" | "production" | null) ?? undefined);
  }
}
