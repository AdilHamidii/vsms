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
import { resolveCallerLine } from "../_shared/lines.ts";
import { toE164, assumesNanp } from "../_shared/phone.ts";
import { canSendTo } from "../_shared/nanp.ts";

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

  // `line_id` was MISSING from this type while line 81 read it — the client has
  // always sent it (`LineAPI.swift`), so multi-number sending worked in
  // production purely because deploy does not type-check. `deno check` rejects
  // it, which is the only reason it was ever visible.
  let body: { to?: string; text?: string; line_id?: string } = {};
  try { body = await req.json(); } catch { /* guarded below */ }

  const to = (body.to ?? "").trim();
  const text = body.text ?? "";
  if (!to || !text) return json({ error: "bad_request" }, { status: 400 });
  if (text.length > MAX_BODY) return json({ error: "bad_request" }, { status: 400 });

  const digits = to.replace(/\D/g, "");
  if (EMERGENCY.has(digits)) {
    return json({ error: "emergency_blocked" }, { status: 400 });
  }

  // 🔴 THIS ENDPOINT HAD NO NUMBER VALIDATION AT ALL — only the emergency check
  // above. Replies happened to work because the peer arrives from an inbound
  // webhook already in E.164; a user typing a NEW recipient sent whatever they
  // typed straight to the provider, spent a segment of their allowance on it,
  // and got back a failure whose reason we then discarded. Same defect as the
  // dialer, one product surface over.
  const recipient = toE164(to);
  if (!recipient) return json({ error: "bad_number" }, { status: 400 });

  const sb = admin();

  // WHICH line to send from. A user may now hold several, so the client names
  // one — but the id is a resource selector and is re-scoped to this user
  // inside `resolveCallerLine`, so naming someone else's number resolves to
  // nothing rather than sending from it.
  //
  // ⚠️ This was `.maybeSingle()` on the user's lines, which ERRORS on more than
  // one row: the moment a second number existed, sending a text returned
  // `lookup_failed` for every message.
  const line = await resolveCallerLine(
    sb, userId, body.line_id, undefined, "id, e164, status, country_code");
  if (!line) return json({ error: "line_unavailable" }, { status: 409 });

  // `toE164` defaults a bare 10-digit string to +1, which is right while the
  // catalogue is US/CA only. Assert it rather than letting the assumption rot
  // into a silent misdial the day a non-NANP number is sold.
  const cc = (line as { country_code?: string }).country_code;
  if (!assumesNanp(cc) && !to.startsWith("+")) {
    console.error(JSON.stringify({
      alert: "line_message_ambiguous_number", line: line.id, country: cc,
      detail: "non-NANP line addressed a number with no country code",
    }));
    return json({ error: "bad_number" }, { status: 400 });
  }

  // 🔴 REFUSE A SEND WE KNOW THE CARRIER WILL REJECT.
  //
  // Every cross-border attempt has come back `40010: The sending number is not
  // 10DLC-registered but is required to be by the carrier` — 6 of 7 lifetime
  // outbound messages. Attempting it anyway reserves a segment, calls the
  // provider, fails, and refunds: a round trip whose only product is a red
  // "Not sent" under the user's message. Refusing up front costs them nothing
  // and can say WHY, which the provider's failure could not.
  //
  // This is the same shape as `create-order`'s pre-charge provider-balance
  // guard: when we already know the answer, do not spend the user's allowance
  // to hear it from someone else.
  const reach = canSendTo(cc, recipient);
  if (!reach.ok) {
    return json({
      error: reach.reason === "international"
        ? "international_sms" : "cross_border_sms",
      from_country: reach.from,
      to_country: reach.to,
    }, { status: 409 });
  }

  const segments = estimateSegments(text);

  // Consumes the allowance, refuses a suspended/past-due line, and writes the
  // row — all under the per-user advisory lock, in one transaction.
  const { data: begun, error: beginErr } = await sb.rpc("begin_outbound_message", {
    p_user: userId,
    p_line: line.id,
    p_to: recipient,
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
    to: recipient,
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
      p_segments: null,
      p_cost_usd: null,
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
  //
  // ⚠️ `sent.parts` used to be FETCHED AND THROWN AWAY. `estimateSegments` errs
  // LOW by design — it has to, because over-estimating silently overcharges an
  // allowance with no money behind it — so discarding the real count meant a
  // three-segment message permanently cost one segment. The claim function now
  // adjusts by the difference.
  const settle = async () => sb.rpc("settle_outbound_message_claim", {
    p_message: messageId,
    p_provider_id: sent.id,
    p_status: "sent",
    p_cost_cents: null,
    p_error: null,
    p_segments: sent.parts,
    p_cost_usd: null,
  });

  let { error: settleErr } = await settle();
  if (settleErr) {
    // ONE retry, because this write is what makes the delivery receipt
    // matchable at all. Without the provider id on the row, the DLR arrives,
    // matches nothing, and the message sits `queued` until the 15-minute stale
    // sweep marks it failed — for a text that was actually delivered.
    ({ error: settleErr } = await settle());
  }
  if (settleErr) {
    // The message IS sent. Telling the user it failed after it went out would
    // be the worse lie, so this never fails the request — but it pages,
    // because the row now cannot be settled by any receipt.
    console.error(JSON.stringify({
      alert: "line_settle_failed", message: messageId, provider_id: sent.id,
      detail: settleErr.message,
    }));
  }

  return json({
    ok: true,
    message_id: messageId,
    thread_id: begun.thread_id,
    remaining: begun.remaining ?? null,
  });
});
