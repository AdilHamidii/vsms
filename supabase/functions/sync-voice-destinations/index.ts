// Keep every line's Telnyx outbound profile in step with `voice_rates.enabled`.
//
// ── Why this exists ───────────────────────────────────────────────────────
// Calling has TWO gates and they are enforced in different systems:
//
//   price      → `voice_rates.enabled`, checked by `begin_intl_call_claim`
//   permission → `whitelisted_destinations` on the line's outbound profile
//
// `whitelisted_destinations` is set at profile CREATION and never revisited, so
// widening the catalog reaches new lines only. The five lines sold before
// 2026-08-17 predate `createOutboundVoiceProfile` existing at all — they carry
// no profile, no connection and no credential, and `mint-line-token` builds all
// three lazily on first use. This sweep covers the other half: lines that
// already have a profile carrying an older, narrower list.
//
// Without it the drift is SILENT and one-directional — a country is priced,
// billed and then rejected by the carrier. `settle_call_claim` refunds the
// block (billed_seconds <= 0 bills nothing), so no money is lost, but the user
// gets a failed call and we get no signal.
//
// ── Why a sweep rather than a one-off backfill ────────────────────────────
// A backfill fixes today. This fixes every future change to the rate table
// too, including a country being turned OFF — which is the direction that
// actually matters, because leaving a destination dialable after we stop
// pricing it is an unpriced call we still pay for.
//
// Cron-gated: deploy with `--no-verify-jwt`.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import { updateOutboundVoiceProfile, faultOf } from "../_shared/telnyx.ts";

/** Bounded for the ~150s edge kill. One PATCH per profile; the sweep is hourly,
 *  so a backlog drains on its own rather than needing one heroic invocation. */
const MAX_PATCH = 40;

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

  // ── The list, from the one function that defines it ─────────────────────
  const { data: dest, error: destErr } = await sb
    .rpc("voice_dial_destinations");
  if (destErr || !Array.isArray(dest) || dest.length === 0) {
    // FAIL LOUD. Patching every profile to an empty list would ground every
    // line in the product, so a bad read must stop the sweep, not proceed with
    // a default.
    await sb.from("app_config").upsert({
      key: "voice_destinations_sync",
      value: { at, ok: false, error: destErr?.message ?? "empty destination list" },
    });
    return json({ error: "destinations_unavailable" }, { status: 500 });
  }
  const destinations = dest as string[];

  const { data: lines, error: lineErr } = await sb
    .from("phone_lines")
    .select("id, e164, status, provider_voice_profile_id")
    .not("provider_voice_profile_id", "is", null)
    .limit(MAX_PATCH);
  if (lineErr) {
    await sb.from("app_config").upsert({
      key: "voice_destinations_sync",
      value: { at, ok: false, error: lineErr.message },
    });
    return json({ error: "lines_unavailable" }, { status: 500 });
  }

  let patched = 0;
  const faults: unknown[] = [];
  for (const line of lines ?? []) {
    const profileId = String(line.provider_voice_profile_id);
    const r = await updateOutboundVoiceProfile(profileId, destinations);
    if (faultOf(r)) {
      // Recorded per line rather than thrown: one bad profile must not stop the
      // rest of the sweep, and a fault nobody can read is a fault nobody fixes.
      faults.push({ line: line.id, e164: line.e164, profile: profileId, fault: r });
      continue;
    }
    patched++;
  }

  // `unprovisioned` is reported separately and is NOT a fault: those lines have
  // no profile yet and `mint-line-token` creates one — already carrying the
  // current list — the first time the owner opens the dialer. Folding them in
  // would read as breakage when it is a lazy path working as designed.
  const { count: unprovisioned } = await sb
    .from("phone_lines")
    .select("id", { count: "exact", head: true })
    .is("provider_voice_profile_id", null)
    .in("status", ["active", "grace"]);

  await sb.from("app_config").upsert({
    key: "voice_destinations_sync",
    value: {
      at, ok: faults.length === 0, patched, destinations: destinations.length,
      unprovisioned: unprovisioned ?? 0,
      faults: faults.length ? faults.slice(0, 5) : undefined,
    },
  });

  return json({
    ok: faults.length === 0,
    patched,
    destinations,
    unprovisioned: unprovisioned ?? 0,
    faults,
  });
});
