// The pre-flight gate for an outbound call.
//
// ── Why the server is not on the ring path ────────────────────────────────
//
// The client dials over WebRTC with a credential from `mint-line-token`; this
// function does NOT place the call. It decides whether the call may happen and
// reserves the allowance, then gets out of the way. Putting an edge function
// between the tap and the ring would add its latency and its failure modes to
// the one interaction where a stall is unmistakable.
//
// ⚠️ **The reservation is an ESTIMATE and the CDR is the truth.** We reserve a
// flat block up front so a user at 3 seconds of allowance cannot start a
// 20-minute call, then `sync-telnyx-cdr` settles the difference — which is why
// `settle_line_allowance` is the one path allowed to overshoot. A call that
// runs past its reservation is not stopped mid-sentence; it is billed
// correctly afterwards.

import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";

/// Emergency numbers are refused HERE as well as on the client.
///
/// E911 is disabled on these numbers at the provider, so an emergency call
/// would fail — silently, at the worst possible moment. Refusing it with an
/// explicit message that names the user's own phone is the only safe
/// behaviour, and it cannot live only in the client: a stale build would
/// bypass it. Same set as `send-line-message`.
const EMERGENCY = new Set(["911", "112", "999", "000", "110", "119", "988"]);

/// Reserved per call. Deliberately well under the 100-minute monthly allowance
/// so a single call cannot consume it, and well over a typical verification
/// call so most calls settle DOWNWARD rather than overshooting.
const RESERVE_SECONDS = 120;

Deno.serve(async (req) => {
  const pre = handleCors(req);
  if (pre) return pre;
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, { status: 405 });
  }

  const userId = await callerUserId(req);
  if (!userId) return json({ error: "unauthorized" }, { status: 401 });

  const body = await req.json().catch(() => ({}));
  const to = String(body.to ?? "").trim();
  if (!to) return json({ error: "bad_request" }, { status: 400 });

  const digits = to.replace(/\D/g, "");
  if (EMERGENCY.has(digits)) {
    return json({ error: "emergency_blocked" }, { status: 400 });
  }
  // A bare E.164 sanity check. The provider will reject anything malformed
  // anyway, but doing it here means we never reserve allowance for a call that
  // cannot be placed.
  if (!/^\+?[1-9]\d{7,14}$/.test(to.replace(/[\s()-]/g, ""))) {
    return json({ error: "bad_number" }, { status: 400 });
  }

  const sb = admin();

  // The caller's own line, read server-side. A line id is a resource selector
  // and is never accepted from the request — the same rule as
  // `mint-line-token`.
  const { data: line, error: lineErr } = await sb.from("phone_lines")
    .select("id, e164, status")
    .eq("user_id", userId)
    .in("status", ["active", "grace", "past_due", "suspended"])
    .maybeSingle();
  if (lineErr) return json({ error: "lookup_failed" }, { status: 500 });
  if (!line) return json({ error: "line_unavailable" }, { status: 409 });

  // Calling is gated harder than inbound SMS, and identically to
  // `mint-line-token`: `past_due` keeps INBOUND working because the user cannot
  // control who contacts them, but placing a call is spending our money.
  if (line.status !== "active" && line.status !== "grace") {
    return json({ error: "line_suspended", status: line.status }, { status: 409 });
  }

  // Claim the allowance BEFORE recording the call, so a refusal leaves no row.
  const { data: claim, error: claimErr } = await sb.rpc("consume_line_allowance", {
    p_line: line.id, p_kind: "voice", p_units: RESERVE_SECONDS,
  });
  if (claimErr) {
    console.error(JSON.stringify({ alert: "line_call_claim_failed", detail: claimErr.message }));
    return json({ error: "call_failed" }, { status: 500 });
  }
  if (!claim?.ok) {
    const reason = String(claim?.reason ?? "call_failed");
    return json({
      error: reason,
      remaining: claim?.remaining ?? null,
    }, { status: reason === "allowance_exhausted" ? 409 : 400 });
  }

  // No provider session id yet — the client gets one from the SDK when the
  // call actually connects, and `sync-telnyx-cdr` matches on it. A null id
  // never conflicts on the partial unique index, which is correct: a call we
  // have no provider id for is genuinely a new row.
  const { data: rec, error: recErr } = await sb.rpc("record_line_call", {
    p_line: line.id,
    p_direction: "outbound",
    p_peer: to,
    p_session_id: null,
    p_status: "ringing",
    p_reserved_seconds: RESERVE_SECONDS,
  });
  if (recErr || !rec?.ok) {
    // Hand the reservation back. Without this a failed record leaves the user
    // two minutes poorer with nothing to show for it, and nothing later
    // reconciles it because there is no row for the CDR to settle.
    //
    // ⚠️ The error was DISCARDED here. supabase-js RETURNS errors rather than
    // throwing, so a failed compensation looked exactly like a successful one —
    // and this is the ONLY thing that returns those two minutes. It is the same
    // class of silent money bug as the four discarded `wallet_credit` sites.
    const { error: refundErr } = await sb.rpc("settle_line_allowance", {
      p_line: line.id, p_kind: "voice", p_actual: 0, p_reserved: RESERVE_SECONDS,
    });
    if (refundErr) {
      console.error(JSON.stringify({
        alert: "line_allowance_stuck", line: line.id, seconds: RESERVE_SECONDS,
        detail: refundErr.message,
      }));
    }
    console.error(JSON.stringify({
      alert: "line_call_record_failed",
      detail: recErr?.message ?? rec?.reason ?? "unknown",
    }));
    return json({ error: "call_failed" }, { status: 500 });
  }

  return json({
    ok: true,
    call_id: rec.call_id,
    from: line.e164,
    to,
    reserved_seconds: RESERVE_SECONDS,
    remaining_seconds: claim.remaining ?? null,
  });
});
