// Send a text from a rented line.
//
// The allowance is consumed and the row written BEFORE Telnyx is called
// (`begin_outbound_message`), so a provider failure can never leave a sent
// message unrecorded — the same ordering as `begin_order`, for the same reason.
//
// ⚠️ This line has NO money to refund. Billing is a hard stop with no overage,
// so when a send fails terminally the ALLOWANCE is what gets handed back, and
// `settle_outbound_message_claim` is the only thing that does it. Failing to
// return it silently shrinks what the user paid for, and nothing would ever
// surface that.

import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import { sendMessage, faultOf } from "../_shared/telnyx.ts";

/** GSM-7 fits 160 chars in one segment, 153 when concatenated; any non-GSM
 *  character forces UCS-2 at 70/67. Estimated locally ONLY to charge the
 *  allowance up front — Telnyx's own `parts` is authoritative and the receipt
 *  settles against it. Over-estimating would quietly overcharge the allowance,
 *  so this deliberately errs low and lets the DLR correct upward. */
function estimateSegments(text: string): number {
  // deno-lint-ignore no-control-regex
  const gsm = /^[\x00-\x7F€£¥èéùìòÇØøÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ¤ÄÖÑÜ§¿äöñüà]*$/.test(text);
  const single = gsm ? 160 : 70;
  const multi = gsm ? 153 : 67;
  if (text.length <= single) return 1;
  return Math.ceil(text.length / multi);
}

/** Blocked outright, client-side AND here. E911 is disabled on these numbers
 *  and a text to an emergency short code must never look like it worked. */
const EMERGENCY = new Set(["911", "112", "999", "000", "110", "119"]);

const MAX_BODY = 1600;

Deno.serve(async (req) => {
  const pre = handleCors(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, { status: 405 });

  const userId = await callerUserId(req);
  if (!userId) return json({ error: "unauthorized" }, { status: 401 });

  let body: { to?: string; text?: string } = {};
  try { body = await req.json(); } catch { /* guarded below */ }

  const to = (body.to ?? "").trim();
  const text = body.text ?? "";
  if (!to || !text) return json({ error: "bad_request" }, { status: 400 });
  if (text.length > MAX_BODY) return json({ error: "bad_request" }, { status: 400 });

  const digits = to.replace(/\D/g, "");
  if (EMERGENCY.has(digits)) {
    return json({ error: "emergency_blocked" }, { status: 400 });
  }

  const sb = admin();

  // The caller's live line. Not passed in from the client: a line id is a
  // client-supplied resource selector, and the only one this user may send from
  // is their own.
  const { data: line, error: lineErr } = await sb.from("phone_lines")
    .select("id, e164, status").eq("user_id", userId)
    .in("status", ["active", "grace", "past_due", "suspended"])
    .maybeSingle();
  if (lineErr) return json({ error: "lookup_failed" }, { status: 500 });
  if (!line) return json({ error: "line_unavailable" }, { status: 409 });

  const segments = estimateSegments(text);

  // Consumes the allowance, refuses a suspended/past-due line, and writes the
  // row — all under the per-user advisory lock, in one transaction.
  const { data: begun, error: beginErr } = await sb.rpc("begin_outbound_message", {
    p_user: userId,
    p_line: line.id,
    p_to: to,
    p_body: text,
    p_segments: segments,
  });
  if (beginErr) return json({ error: "message_send_failed" }, { status: 500 });
  if (begun?.ok !== true) {
    const reason = String(begun?.reason ?? "message_send_failed");
    // `allowance_exhausted` and `line_suspended` are REFUSALS the user can act
    // on, not errors — the composer already states both up front, so reaching
    // here means the client's view was stale.
    return json({ error: reason }, { status: 409 });
  }

  const messageId = String(begun.message_id);

  const sent = await sendMessage({
    from: String(begun.from),
    to,
    text,
    profileId: Deno.env.get("TELNYX_MESSAGING_PROFILE_ID") ?? undefined,
  });

  if (faultOf(sent)) {
    // Terminal failure → settle as failed, which HANDS THE ALLOWANCE BACK.
    const { error } = await sb.rpc("settle_outbound_message_claim", {
      p_message: messageId,
      p_provider_id: null,
      p_status: "failed",
      p_cost_cents: null,
      p_error: sent.type,
    });
    if (error) {
      // The allowance is now stuck spent on a message that never sent. Pages,
      // because nothing else will ever notice.
      console.error(JSON.stringify({
        alert: "line_allowance_stuck", message: messageId, detail: error.message,
      }));
    }
    return json({ error: "message_send_failed" }, { status: 502 });
  }

  // Record Telnyx's id and its AUTHORITATIVE segment count. Two reasons this
  // matters: the delivery receipt can only be matched back to this row by that
  // id, and `parts` is the real segment count our local estimate approximated.
  const { error: settleErr } = await sb.rpc("settle_outbound_message_claim", {
    p_message: messageId,
    p_provider_id: sent.id,
    p_status: "sent",
    p_cost_cents: null,
    p_error: null,
  });
  if (settleErr) {
    // The message IS sent. Losing the id only costs us the receipt matching,
    // so this must not fail the request — telling the user it failed after it
    // went out would be the worse lie.
    console.error(JSON.stringify({
      alert: "line_settle_failed", message: messageId, detail: settleErr.message,
    }));
  }

  return json({
    ok: true,
    message_id: messageId,
    thread_id: begun.thread_id,
    remaining: begun.remaining ?? null,
  });
});
