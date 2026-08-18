// Keep every live line's Telnyx voice configuration correct, without needing
// the owner to open the app.
//
// Two jobs, and they are the two halves of "can this number be used":
//
//   1. REPAIR  — provision voice for a live line that has none, so the number
//                can ring. Free at Telnyx (connections, profiles and
//                credentials cost nothing; only DIDs cost money), which is what
//                makes doing it on a sweep reasonable.
//   2. SYNC    — patch every existing outbound profile's
//                `whitelisted_destinations` to match `voice_rates.enabled`.
//
// ── Why repair belongs on a cron and not only in the app ──────────────────
// Voice provisioning used to happen ONLY in `mint-line-token`, on the client
// opening the Number tab. Rental now provisions up front, but that fixes new
// lines only: the five sold before 2026-08-17 have no connection, no credential
// and no profile, so their numbers cannot receive a call at all — and one of
// those customers had already written in to say calling did not work. Waiting
// for each of them to reopen the app is not a fix, it is a hope.
//
// ── Why SYNC exists ───────────────────────────────────────────────────────
// `whitelisted_destinations` is fixed at profile creation, so widening the
// catalog reaches new lines only. Without this sweep the drift is silent and
// one-directional: a country is priced, billed, and then rejected by the
// carrier. `settle_call_claim` refunds the block (billed_seconds <= 0 bills
// nothing) so no money is lost, but the user gets a failed call and we get no
// signal. It also matters in the OFF direction — leaving a destination dialable
// after we stop pricing it is an unpriced call we still pay for.
//
// Cron-gated: deploy with `--no-verify-jwt`.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import { updateOutboundVoiceProfile, attachOutboundProfile, faultOf } from "../_shared/telnyx.ts";
import { provisionLineVoice, type LineVoiceRow } from "../_shared/lineVoice.ts";

/** Bounded for the ~150s edge kill. One PATCH per profile; hourly, so a backlog
 *  drains on its own rather than needing one heroic invocation. */
const MAX_PATCH = 40;

/** Repair is up to five provider calls per line, so it is bounded far tighter
 *  than the patch sweep. A backlog of unprovisioned lines is small by nature —
 *  it can only be lines sold before the rental path provisioned them. */
const MAX_REPAIR = 5;

function cronOk(req: Request): boolean {
  const secret = Deno.env.get("CRON_SECRET");
  return !!secret && req.headers.get("x-cron-secret") === secret;
}

Deno.serve(async (req) => {
  const pre = handleCors(req);
  if (pre) return pre;
  if (!cronOk(req)) return json({ error: "forbidden" }, { status: 403 });

  const sb = admin();
  const at = new Date().toISOString();

  // ── 1. Repair lines with no voice provisioning ──────────────────────────
  // Only `active`/`grace`: a suspended line must NOT be handed a working
  // calling setup, which is the same rule `mint-line-token` enforces before
  // issuing a token. Provisioning a lapsed subscriber is giving the service
  // away.
  // Cast: supabase-js derives row types by parsing the select STRING, and a
  // concatenated one defeats that inference — the rows come back typed as an
  // error shape. The query is correct; only the inference is not.
  const { data: broken } = await sb
    .from("phone_lines")
    .select("id, e164, provider_number_id, provider_connection_id, provider_credential_id, provider_voice_profile_id, provider_voice_attached")
    .in("status", ["active", "grace"])
    // ⚠️ NOT `provider_connection_id is null` ALONE — that was the first version
    // and it could not see the state this sweep exists to fix.
    // `provisionLineVoice` creates the connection FIRST and persists it
    // immediately, so a line whose profile, credential or voice-attach step
    // faulted keeps a non-null connection. The narrow predicate skipped exactly
    // those rows: Telnyx rejects every outbound call from a connection with no
    // profile, and `provider_voice_attached = false` means the number never
    // rings — both permanent, while the sweep reported success.
    .or("provider_connection_id.is.null,provider_voice_profile_id.is.null," +
        "provider_credential_id.is.null,provider_voice_attached.is.null," +
        "provider_voice_attached.is.false")
    .limit(MAX_REPAIR) as unknown as { data: (LineVoiceRow & { e164: string | null })[] | null };

  let repaired = 0;
  const repairFaults: unknown[] = [];
  for (const line of broken ?? []) {
    // `persistIds: true` — there is no activation claim about to write these,
    // unlike the rental path, so this sweep is the only thing recording them.
    const r = await provisionLineVoice(sb, line, { persistIds: true });
    if (r.faults.length) {
      repairFaults.push({
        line: line.id, e164: line.e164, steps: r.faults.map((f) => f.step),
      });
    }
    // Counted as repaired only when the number can actually RING. A connection
    // without the voice attach is the exact half-working state this sweep
    // exists to end, and calling it success would hide it.
    if (r.attached) repaired++;
  }

  // ── 2. Sync destinations on every known profile ─────────────────────────
  const { data: dest, error: destErr } = await sb.rpc("voice_dial_destinations");
  if (destErr || !Array.isArray(dest) || dest.length === 0) {
    // FAIL LOUD rather than proceeding with a default: patching every profile
    // to an empty list would ground every line in the product.
    await sb.from("app_config").upsert({
      key: "line_voice_sync",
      value: { at, ok: false, repaired,
               error: destErr?.message ?? "empty destination list" },
    });
    return json({ error: "destinations_unavailable", repaired }, { status: 500 });
  }
  const destinations = dest as string[];

  const { data: lines, error: lineErr } = await sb
    .from("phone_lines")
    .select("id, e164, status, provider_voice_profile_id, provider_connection_id")
    .not("provider_voice_profile_id", "is", null)
    .limit(MAX_PATCH);
  if (lineErr) {
    await sb.from("app_config").upsert({
      key: "line_voice_sync",
      value: { at, ok: false, repaired, error: lineErr.message },
    });
    return json({ error: "lines_unavailable", repaired }, { status: 500 });
  }

  let patched = 0;
  let attachedVerified = 0;
  const patchFaults: unknown[] = [];
  const attachFaults: unknown[] = [];
  for (const line of lines ?? []) {
    const profileId = String(line.provider_voice_profile_id);
    const r = await updateOutboundVoiceProfile(profileId, destinations);
    if (faultOf(r)) {
      // Per line rather than thrown: one bad profile must not stop the sweep,
      // and a fault nobody can read is a fault nobody fixes.
      patchFaults.push({ line: line.id, e164: line.e164, fault: r });
      continue;
    }
    patched++;

    // ── 2b. Is the profile actually ON the connection? ────────────────────
    //
    // 🔴 The repair pass above selects by OUR columns, and every sold line
    // said "provisioned" while Telnyx held no profile at all — because
    // `attachOutboundProfile` sent the field at the wrong nesting level and
    // got a 200 for it (see that function). So the repair pass could never
    // reach those lines, and no call ever connected. This runs on every
    // line with a profile, every hour: `attachOutboundProfile` now PATCHes
    // the documented shape and READS BACK, returning true only when Telnyx
    // genuinely holds the profile. Idempotent; two requests per line.
    if (line.provider_connection_id) {
      const a = await attachOutboundProfile(String(line.provider_connection_id), profileId);
      if (faultOf(a)) {
        attachFaults.push({ line: line.id, e164: line.e164, fault: a });
      } else {
        attachedVerified++;
      }
    }
  }

  // Still unprovisioned AFTER the repair pass — the number that says whether
  // this sweep is winning. Non-zero for more than a couple of runs means repair
  // is failing rather than catching up, which the faults will name.
  // The SAME predicate as the repair pass. It used to be the narrow one, so the
  // metric could not see the half-provisioned state either — it reported
  // `unprovisioned: 0, ok: true` over lines that could neither call nor ring.
  // A health counter blind to the failure it measures is worse than none.
  const { count: unprovisioned } = await sb
    .from("phone_lines")
    .select("id", { count: "exact", head: true })
    .in("status", ["active", "grace"])
    .or("provider_connection_id.is.null,provider_voice_profile_id.is.null," +
        "provider_credential_id.is.null,provider_voice_attached.is.null," +
        "provider_voice_attached.is.false");

  const ok = repairFaults.length === 0 && patchFaults.length === 0 && attachFaults.length === 0;
  await sb.from("app_config").upsert({
    key: "line_voice_sync",
    value: {
      at, ok, repaired, patched, attached_verified: attachedVerified,
      destinations: destinations.length,
      unprovisioned: unprovisioned ?? 0,
      repair_faults: repairFaults.length ? repairFaults.slice(0, 5) : undefined,
      patch_faults: patchFaults.length ? patchFaults.slice(0, 5) : undefined,
      attach_faults: attachFaults.length ? attachFaults.slice(0, 5) : undefined,
    },
  });

  return json({
    ok, repaired, patched, attached_verified: attachedVerified, destinations,
    unprovisioned: unprovisioned ?? 0,
    repair_faults: repairFaults, patch_faults: patchFaults, attach_faults: attachFaults,
  });
});
