// The client tells us which provider session its call became.
//
// 🔴 WITHOUT THIS, EVERY CALL COSTS 120 SECONDS OF ALLOWANCE AND NOTHING ELSE
// IS ENFORCED. `begin-line-call` reserves a flat block and `sync-telnyx-cdr`
// settles the difference — but the poller matches ONLY on
// `provider_call_session_id`, and nothing in the repo ever wrote that column.
// So no call could ever be settled: a 10-second call kept its full 120-second
// reservation (100 minutes of allowance = 50 dials a month), and a 40-minute
// call also cost 120 seconds, because the reservation was the only thing
// standing between a user and unlimited talk time.
//
// The session id exists only on the device — the WebRTC SDK produces it when
// the call connects, and the server is deliberately not on the ring path. So
// the client is the only thing that can report it, and this endpoint is how.
//
// ⚠️ The client is ADVISORY, never authoritative. `duration_seconds` is what
// the device claimed and is labelled as such on the column; `billed_seconds`
// from the CDR is the billing truth. The device can be wrong, killed
// mid-call, or lying. What the client uniquely knows is the session ID — that
// is the thing worth taking from it, because it is a key rather than a value.
//
// A call the client never reports is not lost either: `settle_stale_calls()`
// sweeps anything still unsettled after six hours.

import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";

/** Our `line_call_status` enum. An unrecognised value is DROPPED rather than
 *  guessed at — the same rule as `_shared/emailStatus.ts`, and the reason it
 *  exists is that encoding a guess about a vocabulary broke eSIM refunds. */
const STATUSES = new Set([
  "ringing", "answered", "completed", "missed", "busy", "failed", "canceled",
]);

/** A device-reported duration above this is not credible for a call on a
 *  100-minute monthly allowance, and accepting it would let a client burn a
 *  user's whole month in one write. The CDR corrects upward if it really was
 *  that long. */
const MAX_REPORTED_SECONDS = 7_200;

Deno.serve(async (req) => {
  const pre = handleCors(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, { status: 405 });

  const userId = await callerUserId(req);
  if (!userId) return json({ error: "unauthorized" }, { status: 401 });

  let body: {
    call_id?: string;
    session_id?: string;
    leg_id?: string;
    status?: string;
    answered_at?: string;
    duration_seconds?: number;
  } = {};
  try { body = await req.json(); } catch { /* guarded below */ }

  const callId = (body.call_id ?? "").trim();
  if (!callId) return json({ error: "bad_request" }, { status: 400 });

  const status = body.status && STATUSES.has(body.status) ? body.status : null;

  let duration: number | null = null;
  if (typeof body.duration_seconds === "number" && Number.isFinite(body.duration_seconds)) {
    duration = Math.max(0, Math.min(Math.round(body.duration_seconds), MAX_REPORTED_SECONDS));
  }

  const sb = admin();

  // Ownership is re-checked inside the RPC against the row's own user_id — a
  // call id is a client-supplied resource selector and is never trusted on its
  // own. The same rule as `mint-line-token` reading the line server-side.
  const { data, error } = await sb.rpc("attach_line_call_session", {
    p_user: userId,
    p_call: callId,
    p_session: body.session_id ?? null,
    p_leg: body.leg_id ?? null,
    p_status: status,
    p_answered_at: body.answered_at ?? null,
    p_duration_seconds: duration,
  });

  if (error) {
    console.error(JSON.stringify({
      alert: "line_call_report_failed", call: callId, detail: error.message,
    }));
    return json({ error: "report_failed" }, { status: 500 });
  }
  if (data?.ok !== true) {
    // `session_conflict` means the client tried to point one call row at a
    // second provider session. Refused rather than repointed: silently moving
    // it would settle the wrong call's minutes.
    return json({ error: String(data?.reason ?? "report_failed") }, { status: 409 });
  }

  return json({ ok: true });
});
