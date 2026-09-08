// Everything a rented number needs before it can place OR receive a call.
//
// 🔴 WHY THIS FILE EXISTS: INBOUND CALLING HAD NEVER ONCE WORKED.
// Zero inbound calls in the product's entire history, and the cause was
// structural rather than a bug in the calling code:
//
//   messaging profile → attached at RENTAL   (verify-line-subscription,
//                                             rent-line-credits)
//   voice connection  → attached LAZILY      (mint-line-token, on first open)
//
// `attachVoiceConnection` is what makes a number ring, and it lived only in the
// lazy path. So a number was sold, handed to the user, and could not receive a
// call until its owner happened to open the Number tab AND every provider call
// in that path happened to succeed. Rent a number, give it to someone, have
// them ring it: silence, no error, indistinguishable from a dead number.
// Measured 2026-08-17: all 6 lines had a messaging profile, 5 of 6 had no voice
// connection at all.
//
// ── Best-effort, never fatal ──────────────────────────────────────────────
// Called from the RENTAL path, where Apple (or the wallet) has already taken
// the money. A voice failure there must not fail the purchase: the number is
// bought and its SMS half works, so a half-working line beats a refund plus an
// orphaned DID. Faults are returned and paged, and the lazy path in
// `mint-line-token` repairs whatever is still missing on the next open.
//
// That is belt AND braces on purpose. Provisioning early makes the number ring
// for a user who never opens the dialer; keeping the lazy repair means a
// transient Telnyx failure at rental is not permanent.
//
// ── Idempotent ────────────────────────────────────────────────────────────
// Every step is skipped when its id is already recorded, and each id is
// persisted the instant it exists — BEFORE the call that consumes it. Losing an
// id we already paid for leaks a Telnyx resource on every retry, which is the
// specific reason the connection is written before the attach.

import { admin } from "./supabaseAdmin.ts";
import {
  createCredentialConnection, createTelephonyCredential,
  createOutboundVoiceProfile, attachOutboundProfile, attachVoiceConnection,
  ensureInboundReachable, getNumberVoiceConnection,
  ensurePushCredential, faultOf, type TelnyxFault,
} from "./telnyx.ts";

export interface LineVoiceRow {
  id: string;
  /** Needed for the ANI override: without it the far end sees the SIP
   *  username instead of the rented number. */
  e164?: string | null;
  provider_number_id?: string | null;
  provider_connection_id?: string | null;
  provider_credential_id?: string | null;
  provider_voice_profile_id?: string | null;
  provider_voice_attached?: boolean | null;
}

export interface LineVoiceResult {
  connectionId: string | null;
  credentialId: string | null;
  voiceProfileId: string | null;
  /** The number's voice points at the connection — i.e. INBOUND can ring. */
  attached: boolean;
  /** READ BACK from the connection, never inferred from the env var: true =
   *  the connection genuinely holds the iOS VoIP push credential, false = it
   *  does not (or the env var is unset), null = could not be verified this
   *  run. `inbound_ready` must key on `=== true`. */
  pushCredentialHeld: boolean | null;
  /** Non-empty means something is missing; the caller decides how loud to be. */
  faults: { step: string; fault: TelnyxFault }[];
}

type SB = ReturnType<typeof admin>;

async function persist(
  sb: SB, lineId: string,
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

/**
 * Bring a line's voice provisioning up to date. Safe to call repeatedly and
 * safe to call on a line that is already fully provisioned (it does nothing).
 *
 * `persistIds` is false only for the rental path, where `activate_line_claim`
 * writes the same columns moments later as part of activation — writing them
 * twice is harmless but writing them BEFORE the row is active is not, since
 * `record_line_voice_binding` is scoped to live lines.
 */
export async function provisionLineVoice(
  sb: SB, line: LineVoiceRow, opts: { persistIds: boolean },
): Promise<LineVoiceResult> {
  const out: LineVoiceResult = {
    connectionId: line.provider_connection_id ?? null,
    credentialId: line.provider_credential_id ?? null,
    voiceProfileId: line.provider_voice_profile_id ?? null,
    attached: line.provider_voice_attached === true,
    pushCredentialHeld: null,
    faults: [],
  };

  // This one env var decides whether inbound calling can work AT ALL, and its
  // absence is otherwise completely silent — `createCredentialConnection`
  // omits the field rather than failing, so every connection would be built
  // without VoIP-push capability and no phone would ever ring.
  const pushCredentialId =
    Deno.env.get("TELNYX_IOS_PUSH_CREDENTIAL_ID") || undefined;
  if (!pushCredentialId) {
    console.error(JSON.stringify({
      alert: "telnyx_push_credential_missing", line: line.id,
      detail: "TELNYX_IOS_PUSH_CREDENTIAL_ID is not set — inbound cannot ring",
    }));
  }

  // ── 1. The connection ───────────────────────────────────────────────────
  if (!out.connectionId) {
    const conn = await createCredentialConnection({
      name: `vsms-${line.id}`, pushCredentialId,
    });
    if (faultOf(conn)) {
      out.faults.push({ step: "create_connection", fault: conn });
      return out; // Nothing downstream is reachable without it.
    }
    out.connectionId = conn.id;
    if (opts.persistIds) await persist(sb, line.id, { connection: conn.id });
  }

  // ── 1b. Does the connection actually HOLD the VoIP push credential? ──────
  // The same verify-and-repair shape as 2b, for the same reason: a connection
  // created while TELNYX_IOS_PUSH_CREDENTIAL_ID was unset was built push-less
  // (the field is silently omitted), our DB has no record of that, and a
  // push-less connection means no inbound call can ever wake the device.
  // `ensurePushCredential` reads the connection back — a POST/PATCH 200 is
  // not evidence on this API. Runs on freshly-created connections too, so the
  // create path is covered by the same proof instead of trusting its 200.
  if (!pushCredentialId) {
    out.pushCredentialHeld = false;
  } else {
    const held = await ensurePushCredential(out.connectionId, pushCredentialId);
    if (faultOf(held)) {
      out.faults.push({ step: "verify_push_credential", fault: held });
      out.pushCredentialHeld = null; // unverified, NOT false — and never true
    } else {
      out.pushCredentialHeld = true;
    }
  }

  // ── 2. The outbound profile ─────────────────────────────────────────────
  // Telnyx rejects EVERY outbound call from a connection with no profile.
  // Destinations come from `voice_dial_destinations()` so the permission gate
  // and `voice_rates.enabled` (the price gate) cannot disagree.
  if (!out.voiceProfileId) {
    const { data: dest } = await sb.rpc("voice_dial_destinations");
    const destinations = Array.isArray(dest) && dest.length
      ? dest as string[] : undefined;
    const prof = await createOutboundVoiceProfile({
      name: `vsms-${line.id}`, destinations,
    });
    if (faultOf(prof)) {
      out.faults.push({ step: "create_voice_profile", fault: prof });
    } else {
      out.voiceProfileId = prof.id;
      // Before the attach, so a failed attach cannot orphan a profile we then
      // recreate — and pay for — on every retry.
      if (opts.persistIds) await persist(sb, line.id, { voiceProfile: prof.id });
      const at = await attachOutboundProfile(out.connectionId, prof.id);
      if (faultOf(at)) out.faults.push({ step: "attach_voice_profile", fault: at });
    }
  } else {
    // ── 2b. The profile EXISTS — but is it actually on the connection? ────
    //
    // 🔴 Until 2026-08-18 `attachOutboundProfile` sent the field at the wrong
    // nesting level, Telnyx returned 200 and attached NOTHING, and this branch
    // did not exist — so every line whose profile id was already persisted
    // (all six sold) was skipped forever, with our DB saying "provisioned"
    // and Telnyx holding no profile. That is why no call ever connected.
    //
    // `attachOutboundProfile` now reads the connection back and only returns
    // true if the profile is genuinely held, so calling it here on every run
    // is a cheap verify-and-repair, idempotent, and it is what turns the
    // hourly sweep into something that can heal the lines already sold rather
    // than only ones created after the fix.
    const at = await attachOutboundProfile(out.connectionId, out.voiceProfileId);
    if (faultOf(at)) out.faults.push({ step: "verify_voice_profile", fault: at });
  }

  // ── 3. Point the NUMBER's voice where INBOUND is actually answered ──────
  //
  // 🔴 THIS IS THE CALL CONTROL APPLICATION, NOT THE CREDENTIAL CONNECTION,
  // and the difference is the whole of inbound calling.
  //
  // Telnyx will not route a DID to the on-demand telephony credential the SDK
  // logs in with — "inbound calls directly to on-demand generated credential
  // is not currently supported … purely for outbound calls" — so for five
  // weeks every number pointed at its credential connection, found no
  // routable contact, and Telnyx cleared each call in under a second with no
  // media leg. Outbound worked the entire time, because outbound needs only
  // authentication and only inbound needs a registration.
  //
  // The number therefore points at a Call Control application, whose webhook
  // (`telnyx-webhook`, `call.initiated`) transfers the leg to whichever SIP
  // identity the device is currently registered as. Proven live 2026-09-08,
  // app open AND app closed.
  //
  // ⚠️ The target is read from `app_config.telnyx_call_control_app`. If that
  // is missing we fall back to the credential connection — the old,
  // inbound-broken behaviour — rather than failing provisioning outright: a
  // line that cannot receive calls is bad, a line that cannot be SOLD is
  // worse. The fault is recorded so it is visible rather than silent.
  const { data: ccCfg } = await sb.from("app_config")
    .select("value").eq("key", "telnyx_call_control_app").maybeSingle();
  const callControlId =
    ((ccCfg?.value as Record<string, unknown> | null)?.id as string | undefined) ?? null;
  if (!callControlId) {
    out.faults.push({
      step: "call_control_app",
      fault: { telnyxFault: true, type: "TRANSPORT_ERROR", status: 0,
               detail: "app_config.telnyx_call_control_app is missing — inbound " +
                       "calls cannot be delivered to this line." },
    });
  }
  const inboundTarget = callControlId ?? out.connectionId;

  if (line.provider_number_id) {
    // Re-attach whenever the number is not already on the right target, NOT
    // merely when a flag says "attached". The flag predates Call Control, so
    // every line provisioned before it reads attached=true while pointing at
    // the connection that cannot ring — checking the live value is what makes
    // this self-healing for lines already sold.
    const current = await getNumberVoiceConnection(String(line.provider_number_id));
    const currentId = faultOf(current) ? null : current;
    if (currentId !== inboundTarget) {
      const at = await attachVoiceConnection(String(line.provider_number_id), inboundTarget);
      if (faultOf(at)) {
        out.faults.push({ step: "attach_voice_connection", fault: at });
        out.attached = false;
        if (opts.persistIds) await persist(sb, line.id, { attached: false });
      } else {
        out.attached = true;
        if (opts.persistIds) await persist(sb, line.id, { attached: true });
      }
    } else if (!out.attached) {
      out.attached = true;
      if (opts.persistIds) await persist(sb, line.id, { attached: true });
    }
  }

  // ── 3b. Let the transfer leg INTO the connection, and fix caller ID ──────
  // Cheap, idempotent, and read back. Without the SIP-URI setting the
  // transfer cannot enter the connection at all; without the ANI override the
  // far end sees a SIP username instead of the rented number.
  //
  // The number is looked up when the caller did not pass it, rather than
  // added to three call sites — `verify-line-subscription`, `rent-line-credits`
  // and `swap-line-number` all build their row by hand, and a fourth caller
  // would forget. Resolving it here means inbound cannot be half-provisioned
  // because somebody omitted a column.
  let e164 = line.e164 ?? null;
  if (!e164) {
    const { data: row } = await sb.from("phone_lines")
      .select("e164").eq("id", line.id).maybeSingle();
    e164 = (row?.e164 as string | null) ?? null;
  }
  if (e164) {
    const reach = await ensureInboundReachable(out.connectionId, String(e164));
    if (faultOf(reach)) out.faults.push({ step: "inbound_reachable", fault: reach });
  }

  // ── 4. The login the device uses ────────────────────────────────────────
  if (!out.credentialId) {
    const cred = await createTelephonyCredential({
      connectionId: out.connectionId, name: `vsms-${line.id}`,
    });
    if (faultOf(cred)) {
      out.faults.push({ step: "create_credential", fault: cred });
    } else {
      out.credentialId = cred.id;
      if (opts.persistIds) await persist(sb, line.id, { credential: cred.id });
    }
  }

  return out;
}
