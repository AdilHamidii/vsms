// A short-lived WebRTC credential for the caller's own line.
//
// ⚠️ THE TELNYX API KEY MUST NEVER REACH A DEVICE. It can buy numbers, send
// messages and read the account balance. This endpoint exists so the client
// holds a token scoped to ONE line that expires on its own, and nothing else.
//
// The credential connection is per LINE, created lazily on first use. That is
// what makes inbound ring only the right person: a DID attached to its own
// connection can only ring that connection's registrations, so user A can never
// be rung for user B's number. With one shared connection, that separation
// would be application logic rather than provider configuration — and the
// failure mode of getting it wrong is a stranger's call ringing your phone.
//
// ⚠️ The Telnyx voice adapter functions this calls are written from the docs
// and NOT probed live, unlike everything else in `_shared/telnyx.ts`. Treat a
// first real call as the probe, and read `telnyx_voice_faults` after it.

import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import { mintCredentialToken, faultOf } from "../_shared/telnyx.ts";
import { provisionLineVoice, type LineVoiceRow } from "../_shared/lineVoice.ts";
import { resolveCallerLine } from "../_shared/lines.ts";

Deno.serve(async (req) => {
  const pre = handleCors(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, { status: 405 });

  const userId = await callerUserId(req);
  if (!userId) return json({ error: "unauthorized" }, { status: 401 });

  const sb = admin();

  // Optional `line_id`. An older client sends nothing and gets its single line,
  // which is why the helper falls back to a deterministic oldest-first pick
  // rather than requiring the field.
  const body = await req.json().catch(() => ({} as Record<string, unknown>));

  // ⚠️ `.maybeSingle()` here ERRORED once a user held two numbers, so minting a
  // voice credential — and therefore calling at all — returned `lookup_failed`.
  // The client names which line it wants a token for; the id is re-scoped to
  // this user inside the helper, so someone else's id resolves to nothing.
  const line = await resolveCallerLine(
    sb, userId, body.line_id as string | undefined, undefined,
    "id, e164, status, provider_number_id, provider_connection_id, " +
    "provider_credential_id, provider_voice_attached, provider_voice_profile_id",
  ) as (Record<string, unknown> & { id: string; e164: string | null }) | null;
  if (!line) return json({ error: "line_unavailable" }, { status: 409 });

  // ⚠️ Calling is gated harder than messaging. `past_due` keeps INBOUND SMS
  // working because the user cannot control who texts them — but handing out a
  // live calling credential to a lapsed subscriber is giving away the service,
  // and revoking it is what makes suspension real.
  if (line.status !== "active" && line.status !== "grace") {
    return json({ error: "line_suspended" }, { status: 409 });
  }

  // ── Provisioning ────────────────────────────────────────────────────────
  // Shared with BOTH rental paths (`verify-line-subscription`,
  // `rent-line-credits`), which now provision voice up front so a number can
  // ring before its owner ever opens the dialer. This call is the REPAIR half:
  // idempotent, so a fully provisioned line does nothing here, and a line whose
  // rental-time provisioning hit a transient Telnyx fault is completed on the
  // next open rather than being broken forever.
  //
  // One definition, two callers. Keeping a second copy of this sequence here is
  // exactly how the two halves drift — and the half that drifts silently is the
  // one that decides whether the phone rings.
  const voice = await provisionLineVoice(sb, line as LineVoiceRow,
    { persistIds: true });

  // A missing connection or credential means the device cannot register at all,
  // so there is no token to mint. Report the first fault rather than a generic
  // one: `voiceFault` is what makes the first real call double as the probe
  // these adapters never got.
  if (!voice.connectionId || !voice.credentialId) {
    const first = voice.faults[0];
    return voiceFault(
      sb,
      first?.fault ?? { type: "TRANSPORT_ERROR", status: 0,
                        detail: "voice provisioning incomplete" },
      first?.step ?? "provision_voice",
    );
  }
  const credentialId = voice.credentialId;
  const attachedOk = voice.attached;

  const token = await mintCredentialToken(credentialId);
  if (faultOf(token)) return voiceFault(sb, token, "mint_token");

  return json({
    token: token.token,
    e164: line.e164,
    // The client shows the meter and refuses to dial at zero, but the SERVER
    // is the authority — `begin-line-call` reserves the allowance before the
    // call connects.
    line_id: line.id,
    // Honest rather than hidden: outbound works either way, inbound does not
    // ring until this is true. The client can say so instead of the user
    // discovering it when someone tries to call them.
    //
    // 🔴 THE ATTACH IS NOT SUFFICIENT, and reporting it alone was a lie.
    // Pointing the number's voice at our connection is only half of inbound —
    // Telnyx also needs an iOS VoIP push credential on that connection to wake
    // the device, and `createCredentialConnection` OMITS the field entirely
    // when the env var is unset rather than failing. So with no
    // TELNYX_IOS_PUSH_CREDENTIAL_ID configured (which was the live state until
    // this was found) every connection was created push-less, no inbound call
    // could ever produce a PushKit notification, and this endpoint cheerfully
    // reported inbound_ready: true. The client then advertises a capability
    // that cannot work, and nothing anywhere logs a reason.
    //
    // `pushCredentialHeld` is READ BACK from the connection by
    // `provisionLineVoice` (which also repairs a push-less connection), never
    // inferred from the env var — a connection created while the secret was
    // unset would otherwise report ready forever. `=== true` on purpose: an
    // unverifiable read is null and must not advertise the capability.
    inbound_ready: attachedOk && voice.pushCredentialHeld === true,
  });
});

/** Records the fault shape so the FIRST real call doubles as the probe these
 *  adapters never got. */
async function voiceFault(
  sb: ReturnType<typeof admin>,
  fault: { type: string; detail?: string; status?: number; code?: string },
  stage: string,
) {
  console.error(JSON.stringify({ alert: "line_voice_fault", stage, ...fault }));
  await sb.from("app_config").upsert({
    key: "telnyx_voice_faults",
    // ⚠️ STATUS AND CODE ARE THE DIAGNOSTIC, and this key used to drop both.
    // The `user_name` defect sat here for two days showing only
    // `type: OUT_OF_STOCK` — which was itself the wrong classification — while
    // the HTTP status that would have named it a validation failure was
    // discarded on write. Keep them: this key exists because these adapters
    // were written from docs, so the first real call IS the probe.
    value: { stage, type: fault.type, detail: fault.detail ?? null,
             status: fault.status ?? null, code: fault.code ?? null,
             at: new Date().toISOString() },
  }, { onConflict: "key" });
  return json({ error: "provider_unreachable" }, { status: 502 });
}
