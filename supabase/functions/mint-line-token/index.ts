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
import {
  createCredentialConnection, createTelephonyCredential, mintCredentialToken,
  attachVoiceConnection, createOutboundVoiceProfile, attachOutboundProfile,
  faultOf,
} from "../_shared/telnyx.ts";
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

  let connectionId = line.provider_connection_id as string | null;
  let credentialId = line.provider_credential_id as string | null;
  let attachedOk = line.provider_voice_attached === true;

  // Lazily create the connection. Doing it here rather than at provisioning
  // keeps the purchase path shorter — Apple has already taken the money by
  // then, so every extra provider call in it is another way to fail after
  // being paid.
  // Read once, and report it: this single env var decides whether inbound
  // calling can work AT ALL, and its absence is otherwise completely silent.
  const pushCredentialId = Deno.env.get("TELNYX_IOS_PUSH_CREDENTIAL_ID") || undefined;
  const hasPushCredential = !!pushCredentialId;
  if (!hasPushCredential) {
    // NEVER silent. Without this the only symptom is a phone that never rings.
    console.error(JSON.stringify({
      alert: "telnyx_push_credential_missing",
      detail: "TELNYX_IOS_PUSH_CREDENTIAL_ID is not set — inbound calls cannot ring",
    }));
  }

  if (!connectionId) {
    const conn = await createCredentialConnection({
      name: `vsms-${line.id}`,
      pushCredentialId,
    });
    if (faultOf(conn)) return voiceFault(sb, conn, "create_connection");
    connectionId = conn.id;
    // Persisted IMMEDIATELY, before the attach. If the write is skipped or
    // fails we create a brand-new connection on every mint and leak one at
    // Telnyx each time.
    await persist(sb, String(line.id), { connection: connectionId });
  }

  // 🔴 WITHOUT AN OUTBOUND VOICE PROFILE, TELNYX REJECTS EVERY OUTBOUND CALL.
  // `provider_voice_profile_id` shipped in the first line migration and nothing
  // has ever written it — both provisioning paths pass null — so this was a
  // second, independent reason calling never worked, hiding behind the invalid
  // SIP username. A column with no writer is the third instance of that shape
  // in this feature.
  //
  // Created lazily here, next to the connection, for the same reason: Apple has
  // already taken the money by provisioning time, so every extra provider call
  // on that path is another way to fail after being paid.
  let voiceProfileId = line.provider_voice_profile_id as string | null;
  if (!voiceProfileId) {
    const prof = await createOutboundVoiceProfile({ name: `vsms-${line.id}` });
    if (faultOf(prof)) return voiceFault(sb, prof, "create_voice_profile");
    voiceProfileId = prof.id;
    // Persist BEFORE the attach, so a failed attach cannot orphan a profile we
    // then recreate on every mint — the same ordering as the connection above.
    await persist(sb, String(line.id), { voiceProfile: voiceProfileId });

    const attached = await attachOutboundProfile(connectionId, voiceProfileId);
    if (faultOf(attached)) {
      // FATAL, unlike the inbound attach. Inbound failing leaves a half-working
      // line worth keeping; this one means the user can place no calls at all,
      // so returning a token would hand them a dialer that cannot dial.
      return voiceFault(sb, attached, "attach_voice_profile");
    }
  }

  // 🔴 THE ATTACH IS RETRIED UNTIL IT SUCCEEDS, and that is the fix.
  //
  // Pointing the number's VOICE at its connection is what makes INBOUND ring —
  // it is not settable on the main number resource (10027), it lives on the
  // /voice sub-resource. It used to run only inside the `if (!connectionId)`
  // branch, and the connection id was stored whether or not it worked. So one
  // transient failure meant inbound calls never rang for that line, forever,
  // while outbound worked perfectly and nothing ever looked wrong.
  if (!attachedOk && line.provider_number_id) {
    const attached = await attachVoiceConnection(
      String(line.provider_number_id), connectionId);
    if (faultOf(attached)) {
      // Not fatal: outbound still works, and a half-working line beats none.
      // Recorded as `false` so the NEXT mint tries again.
      console.error(JSON.stringify({
        alert: "line_voice_attach_failed", line: line.id, detail: attached.detail,
      }));
      await persist(sb, String(line.id), { attached: false });
    } else {
      attachedOk = true;
      await persist(sb, String(line.id), { attached: true });
    }
  }

  if (!credentialId) {
    const cred = await createTelephonyCredential({
      connectionId, name: `vsms-${line.id}`,
    });
    if (faultOf(cred)) return voiceFault(sb, cred, "create_credential");
    credentialId = cred.id;
    await persist(sb, String(line.id), { credential: credentialId });
  }

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
    inbound_ready: attachedOk && hasPushCredential,
  });
});

/** Persist a voice binding. Errors were DISCARDED here, and each one is a real
 *  leak: a lost connection id means a brand-new connection at Telnyx on every
 *  single mint, and a lost credential id means a new credential each time —
 *  both accumulate forever with nothing pointing at them. */
async function persist(
  sb: ReturnType<typeof admin>,
  lineId: string,
  what: { connection?: string; credential?: string; attached?: boolean;
          voiceProfile?: string },
) {
  const { error } = await sb.rpc("record_line_voice_binding", {
    p_line: lineId,
    p_connection: what.connection ?? null,
    p_credential: what.credential ?? null,
    p_attached: what.attached ?? null,
    p_voice_profile: what.voiceProfile ?? null,
  });
  if (error) {
    console.error(JSON.stringify({
      alert: "line_voice_binding_unrecorded", line: lineId,
      fields: Object.keys(what), detail: error.message,
    }));
  }
}

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
