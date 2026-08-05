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
  attachVoiceConnection, faultOf,
} from "../_shared/telnyx.ts";

Deno.serve(async (req) => {
  const pre = handleCors(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, { status: 405 });

  const userId = await callerUserId(req);
  if (!userId) return json({ error: "unauthorized" }, { status: 401 });

  const sb = admin();

  // The caller's own line, read server-side. A line id is a client-supplied
  // resource selector and is never accepted from the request.
  const { data: line, error } = await sb.from("phone_lines")
    .select("id, e164, status, provider_number_id, provider_connection_id, provider_credential_id")
    .eq("user_id", userId)
    .in("status", ["active", "grace", "past_due", "suspended"])
    .maybeSingle();
  if (error) return json({ error: "lookup_failed" }, { status: 500 });
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

  // Lazily create the connection. Doing it here rather than at provisioning
  // keeps the purchase path shorter — Apple has already taken the money by
  // then, so every extra provider call in it is another way to fail after
  // being paid.
  if (!connectionId) {
    const conn = await createCredentialConnection({
      name: `vsms-${line.id}`,
      pushCredentialId: Deno.env.get("TELNYX_IOS_PUSH_CREDENTIAL_ID") || undefined,
    });
    if (faultOf(conn)) return voiceFault(sb, conn, "create_connection");
    connectionId = conn.id;

    // Point the number's VOICE at it. Not settable on the main number resource
    // (10027) — it lives on the /voice sub-resource.
    if (line.provider_number_id) {
      const attached = await attachVoiceConnection(
        String(line.provider_number_id), connectionId);
      if (faultOf(attached)) {
        // Outbound will still work; inbound will not ring. Pages rather than
        // failing, because a half-working line is worth more than none.
        console.error(JSON.stringify({
          alert: "line_voice_attach_failed", line: line.id, detail: attached.detail,
        }));
      }
    }
    await sb.from("phone_lines")
      .update({ provider_connection_id: connectionId })
      .eq("id", line.id);
  }

  if (!credentialId) {
    const cred = await createTelephonyCredential({
      connectionId, name: `vsms-${line.id}`,
    });
    if (faultOf(cred)) return voiceFault(sb, cred, "create_credential");
    credentialId = cred.id;
    await sb.from("phone_lines")
      .update({ provider_credential_id: credentialId })
      .eq("id", line.id);
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
  });
});

/** Records the fault shape so the FIRST real call doubles as the probe these
 *  adapters never got. */
async function voiceFault(
  sb: ReturnType<typeof admin>,
  fault: { type: string; detail?: string },
  stage: string,
) {
  console.error(JSON.stringify({ alert: "line_voice_fault", stage, ...fault }));
  await sb.from("app_config").upsert({
    key: "telnyx_voice_faults",
    value: { stage, type: fault.type, detail: fault.detail ?? null,
             at: new Date().toISOString() },
  }, { onConflict: "key" });
  return json({ error: "provider_unreachable" }, { status: 502 });
}
