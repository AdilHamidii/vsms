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
import { resolveCallerLine } from "../_shared/lines.ts";
import { toE164, assumesNanp } from "../_shared/phone.ts";

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

  // 🔴 INBOUND CALLS HAVE TO BE RECORDED TOO. `record_line_call` had exactly
  // ONE caller — this function, on the outbound path — so an inbound call
  // produced no row at all: nothing in call history, nothing consuming or even
  // observing the allowance, and nothing for `sync-telnyx-cdr` to match its
  // detail record against, so the real per-minute cost Telnyx bills us was
  // never attributed to anybody. For an inbound call `to` carries the PEER,
  // i.e. the number that rang us.
  const direction = String(body.direction ?? "outbound") === "inbound"
    ? "inbound"
    : "outbound";

  const digits = to.replace(/\D/g, "");
  // Only meaningful for a call we are placing. We are not dialling an inbound
  // peer, so there is nothing to refuse — and refusing would only discard the
  // record of a call that is happening anyway.
  if (direction === "outbound" && EMERGENCY.has(digits)) {
    return json({ error: "emergency_blocked" }, { status: 400 });
  }

  // 🔴 THE DIALLED NUMBER MUST BE E.164 AND THE CLIENT DID NOT MAKE IT SO.
  // `DialerScreen` sent the raw keypad string, so a US number arrived as
  // "4054003316" — no `+`, no country code. The old check here was
  // `/^\+?[1-9]\d{7,14}$/`, which ACCEPTS a bare national number, so nothing
  // caught it and we happily reserved allowance for a call the provider could
  // never place. Live on 2026-08-17 a subscriber dialled "4054003316", watched
  // it fail, redialled "14054003316" — still no `+` — and cancelled four
  // minutes later.
  //
  // Normalising server-side as well as on the client is deliberate: a shipped
  // build cannot be fixed, and this is the last point before we spend the
  // user's allowance. NANP is the right default because the sellable catalogue
  // is US/CA only (both +1); `country_code` is asserted against that below so
  // this cannot silently misdial if a non-NANP country is ever sold.
  const normalized = toE164(to);
  if (!normalized) return json({ error: "bad_number" }, { status: 400 });

  const sb = admin();

  // The caller's own line, read server-side. A line id is a resource selector
  // and is never accepted from the request — the same rule as
  // `mint-line-token`.
  // ⚠️ `.maybeSingle()` here ERRORED once a user held two numbers, so every
  // call attempt returned `lookup_failed`. The client names the line it is
  // calling FROM; the id is re-scoped to this user inside the helper.
  // `country_code` is named explicitly — the helper's default column list is
  // `id, e164, status`, and a column that is not selected reads as undefined
  // rather than erroring, which would quietly disable the NANP guard below.
  const line = await resolveCallerLine(
    sb, userId, body.line_id, undefined, "id, e164, status, country_code");
  if (!line) return json({ error: "line_unavailable" }, { status: 409 });

  // The NANP assumption above, made explicit. Every number we can sell without
  // regulatory paperwork is +1 (US/CA/PR/VI), so defaulting a bare 10-digit
  // string to +1 is correct today — but it is an ASSUMPTION, and the moment a
  // non-NANP line is sold it becomes a silent misdial to the wrong country.
  // Refuse loudly instead, rather than letting the default rot into a bug.
  const cc = (line as { country_code?: string }).country_code;
  if (direction === "outbound" && !assumesNanp(cc) && !to.trim().startsWith("+")) {
    console.error(JSON.stringify({
      alert: "line_call_ambiguous_number", line: line.id, country: cc,
      detail: "non-NANP line dialled a number with no country code",
    }));
    return json({ error: "bad_number" }, { status: 400 });
  }

  // Calling is gated harder than inbound SMS, and identically to
  // `mint-line-token`: `past_due` keeps INBOUND working because the user cannot
  // control who contacts them, but placing a call is spending our money.
  if (direction === "outbound" && line.status !== "active" && line.status !== "grace") {
    return json({ error: "line_suspended", status: line.status }, { status: 409 });
  }

  // ⚠️ INBOUND IS RECORDED BUT NEVER BILLED, and that asymmetry is deliberate.
  // The user cannot control who calls them, so charging their hard-stop
  // allowance for it is an uncapped cost they did not choose — which is exactly
  // why the design notes say never to bill inbound. Reserving zero keeps the
  // row (history, and a target for the CDR to settle against) without touching
  // the meter.
  const reserveSeconds = direction === "outbound" ? RESERVE_SECONDS : 0;

  // Declared out here so the response can report it; only the outbound branch
  // ever fills it, and inbound legitimately reports null (nothing was reserved).
  let remainingSeconds: number | null = null;

  // 🔴 INTERNATIONAL IS PAID IN CREDITS, NOT MINUTES. The subscription sells a
  // domestic (NANP) minute bucket, and a bucket denominated in MINUTES cannot
  // survive international rates: 100 minutes is 100 minutes whether it costs
  // $0.50 or $362. So the destination decides which meter runs, and the two are
  // mutually exclusive — charging both would bill twice for one call.
  //
  // `begin_intl_call_claim` charges and writes the row in ONE transaction under
  // the per-user advisory lock, so a refusal leaves nothing behind and a
  // double-tap cannot charge twice. It returns `domestic` when the destination
  // is on the allowance, which is the signal to fall through to the code below.
  if (direction === "outbound") {
    const { data: intl, error: intlErr } = await sb.rpc("begin_intl_call_claim", {
      p_user: userId, p_line: line.id, p_peer: normalized,
      p_reserve_seconds: RESERVE_SECONDS,
    });
    if (intlErr) {
      console.error(JSON.stringify({
        alert: "line_intl_claim_failed", detail: intlErr.message,
      }));
      return json({ error: "call_failed" }, { status: 500 });
    }

    if (intl?.ok) {
      // Charged and recorded. Nothing below applies — the minute allowance is
      // deliberately untouched for a call the user paid cash for.
      return json({
        ok: true,
        call_id: intl.call_id,
        from: line.e164,
        to: normalized,
        billing: "credits",
        credits_reserved: intl.credits_reserved,
        credits_per_min: intl.credits_per_min,
        destination: { iso2: intl.iso2, label: intl.label },
        balance: intl.balance,
        reserved_seconds: 0,
        remaining_seconds: null,
      });
    }

    const intlReason = String(intl?.reason ?? "");
    if (intlReason && intlReason !== "domestic") {
      // `insufficient_credits` carries the shortfall so the app can open the
      // credits sheet sized for THIS call rather than making the user guess.
      const status = intlReason === "insufficient_credits" ? 402
        : intlReason === "destination_unavailable" ? 409
        : intlReason === "line_suspended" ? 409
        : 400;
      return json({
        error: intlReason,
        needed: intl?.needed ?? null,
        balance: intl?.balance ?? null,
        shortfall: intl?.shortfall ?? null,
        credits_per_min: intl?.credits_per_min ?? null,
        destination: intl?.iso2 ? { iso2: intl.iso2, label: intl.label } : null,
      }, { status });
    }
    // Fall through: `domestic` means the minute allowance is the right meter.
  }

  if (direction === "outbound") {
    // Claim the allowance BEFORE recording the call, so a refusal leaves no row.
    const { data: claim, error: claimErr } = await sb.rpc("consume_line_allowance", {
      p_line: line.id, p_kind: "voice", p_units: reserveSeconds,
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
    remainingSeconds = (claim?.remaining as number | null) ?? null;
  }

  // No provider session id yet — the client gets one from the SDK when the
  // call actually connects, and `sync-telnyx-cdr` matches on it. A null id
  // never conflicts on the partial unique index, which is correct: a call we
  // have no provider id for is genuinely a new row.
  const { data: rec, error: recErr } = await sb.rpc("record_line_call", {
    p_line: line.id,
    p_direction: direction,
    // The NORMALIZED number, never the raw one. `line_calls.peer_e164` is
    // named for the format it is supposed to hold, and it was storing bare
    // national strings ("4054003316") — which also means `sync-telnyx-cdr`
    // could never match a detail record back to the call.
    p_peer: normalized,
    p_session_id: null,
    // An inbound call is already connecting when the client tells us about it;
    // only an outbound one is genuinely still ringing at this point.
    p_status: direction === "inbound" ? "answered" : "ringing",
    p_reserved_seconds: reserveSeconds,
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
    // Nothing was reserved for inbound, so there is nothing to hand back —
    // and settling a zero reservation would be a no-op write on the meter.
    const { error: refundErr } = reserveSeconds === 0
      ? { error: null }
      : await sb.rpc("settle_line_allowance", {
          p_line: line.id, p_kind: "voice", p_actual: 0, p_reserved: reserveSeconds,
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
    // Echo the NORMALIZED number so the client dials exactly what we
    // authorised and recorded, rather than its own unqualified string.
    to: normalized,
    reserved_seconds: reserveSeconds,
    remaining_seconds: remainingSeconds,
  });
});
