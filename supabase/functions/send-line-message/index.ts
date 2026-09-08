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
 *  and a text to an emergency short code must never look like it worked.
 *
 *  🔴 `988` WAS MISSING FROM THIS SET UNTIL 2026-08-18, while `begin-line-call`
 *  (whose comment claims "same set as send-line-message"), `DialerScreen` and
 *  `ComposeScreen` all carried it. So a CALL to the US crisis line was refused
 *  on every path and a TEXT to it was accepted here — the one direction where
 *  a message that silently goes nowhere does the most harm. Four copies of a
 *  safety list is three too many; if a fifth is ever needed, share it. */
const EMERGENCY = new Set(["911", "112", "999", "000", "110", "119", "988"]);

const MAX_BODY = 1600;

/** The +1 bloc. Mirrors `_shared/phone.ts`'s `NANP`; used here only to decide
 *  whether the `supports_sms` lookup below is worth a round trip. */
const NANP_LINE = new Set(["US", "CA", "PR", "VI"]);

/** 🔴 OUTBOUND SMS IS BACK ON, NANP → NANP ONLY (owner decision, 2026-09-08).
 *
 *  It was retired on 2026-08-18 on the strength of four `40010` failures, all
 *  cross-border from the one country we then sold. A US → CA send delivered on
 *  2026-09-08, so the blanket refusal is gone and `canSendTo` now allows any
 *  NANP pair — see `_shared/nanp.ts` for the policy and for the reasons it is
 *  still narrower than "sending works".
 *
 *  ⚠️ **Nothing here may be read as proof that sending works.** The one
 *  measured delivery was ON-NET (both numbers are on our own Telnyx account)
 *  and no number we own carries a 10DLC campaign, so a real carrier may still
 *  reject a message we accepted. That rejection arrives ASYNCHRONOUSLY as a
 *  delivery receipt on `telnyx-webhook`, which settles the row `failed` with
 *  the provider's reason in `line_messages.error_code` and hands the allowance
 *  back. A 200 from this endpoint means "queued at the carrier", never
 *  "delivered", and the client must render it that way. */

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
    sb, userId, body.line_id, undefined,
    "id, e164, status, country_code, number_type");
  if (!line) return json({ error: "line_unavailable" }, { status: 409 });

  // 🔴 A NUMBER THAT CANNOT DO SMS AT ALL. GB, DE, FR, NL, PL and AU local
  // numbers carry no `sms` feature (measured 2026-08-26, `.claude/rules/
  // providers.md`), so a send from one is a guaranteed failure the catalog can
  // name before the allowance is spent. The retirement comment that used to
  // stand here asked for exactly this check, in exactly this position, "where
  // the line's country_code is already in hand".
  //
  // Only for a NON-NANP line, deliberately: every NANP number we own supports
  // SMS, so paying a round trip on the only path anybody uses today would be a
  // cost with no reader. And it refuses ONLY on an explicit `false` — a
  // missing row or a failed read passes, because inventing a refusal out of
  // missing data is how a catalogue loses destinations it could serve (the
  // same fail-open rule `canSendTo` applies to an unknown sender).
  const cc = (line as { country_code?: string }).country_code;
  if (cc && !NANP_LINE.has(cc.toUpperCase())) {
    const { data: cat } = await sb.from("line_country_catalog")
      .select("supports_sms")
      .eq("country_code", cc.toUpperCase())
      .eq("number_type",
          String((line as { number_type?: string }).number_type ?? "local"))
      .maybeSingle();
    if (cat && (cat as { supports_sms?: boolean | null }).supports_sms === false) {
      return json({ error: "line_has_no_sms", from_country: cc }, { status: 409 });
    }
  }

  // `toE164` defaults a bare national string to +1 only for a +1 line. Assert
  // it here as well so the refusal is LOGGED with the country that caused it —
  // a bare `bad_number` from a non-NANP line is otherwise indistinguishable
  // from a typo.
  if (!assumesNanp(cc) && !to.startsWith("+")) {
    console.error(JSON.stringify({
      alert: "line_message_ambiguous_number", line: line.id, country: cc,
      detail: "non-NANP line addressed a number with no country code",
    }));
    return json({ error: "bad_number" }, { status: 400 });
  }

  // 🔴 THIS ENDPOINT HAD NO NUMBER VALIDATION AT ALL — only the emergency check
  // near the top. Replies happened to work because the peer arrives from an
  // inbound webhook already in E.164; a user typing a NEW recipient sent
  // whatever they typed straight to the provider, spent a segment of their
  // allowance on it, and got back a failure whose reason we then discarded.
  // Same defect as the dialer, one product surface over.
  //
  // ⚠️ Normalised BELOW the line lookup (2026-08-26), because the +1 default is
  // only correct for a NANP line and the catalogue is no longer US/CA only.
  const recipient = toE164(to, { lineCountry: cc ?? null });
  if (!recipient) return json({ error: "bad_number" }, { status: 400 });

  // 🔴 REFUSE A SEND THE NUMBER ITSELF CANNOT MAKE.
  //
  // Since 2026-09-08 this refuses only what the number's own capability
  // forbids: `features.sms.international_outbound` is FALSE on all 12 numbers
  // we own, so any non-NANP destination is a guaranteed failure. NANP → NANP
  // passes — see `_shared/nanp.ts` for the measurement that reopened it, and
  // for why one on-net delivery is not proof that sending works.
  //
  // Same shape as `create-order`'s pre-charge provider-balance guard: when we
  // already know the answer, do not spend a segment of a hard-stop allowance
  // to hear it from someone else. What we do NOT know — whether a carrier will
  // filter an unregistered sender — is left to the delivery receipt.
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
