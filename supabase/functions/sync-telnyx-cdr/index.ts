// Settles calls against Telnyx's detail records — the billing truth.
//
// ── Why a poller and not the webhook ──────────────────────────────────────
//
// `call.hangup` tells us a call ended; it does not tell us what it COST. The
// CDR arrives minutes later and carries the billed duration and the price, and
// that is what `settle_call_claim` needs. A webhook-only design would settle
// every call against the client's own reported duration — a number produced by
// software we do not control, on a device that can be killed mid-call.
//
// ⚠️ **THIS AND ITS ADAPTER ARE UNPROVEN.** No call has ever been placed on
// this account, so the record shape below is read off the documentation. The
// first real run is the probe: it writes the raw shape of the first record it
// sees into `app_config.telnyx_cdr_probe` and every fault into
// `telnyx_cdr_faults`, so one production run answers what a second reading of
// the docs cannot. **Read those two keys before trusting any figure here.**
//
// Cron-gated: deploy with `--no-verify-jwt`.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import { fetchCallDetailRecords, faultOf } from "../_shared/telnyx.ts";

/// How far back to sweep. Comfortably wider than the lag between a hangup and
/// its CDR, and bounded so a stuck cursor cannot turn into an unbounded query.
const LOOKBACK_MINUTES = 180;

/// The edge runtime dies at ~150s. Settling is one RPC per call, so this is a
/// generous ceiling — but an unbounded one is how a quiet function becomes an
/// IDLE_TIMEOUT the day traffic arrives.
const MAX_SETTLE = 200;

function cronOk(req: Request): boolean {
  const secret = Deno.env.get("CRON_SECRET");
  return !!secret && req.headers.get("x-cron-secret") === secret;
}

Deno.serve(async (req) => {
  const pre = handleCors(req);
  if (pre) return pre;
  if (!cronOk(req)) return json({ error: "forbidden" }, { status: 403 });

  const sb = admin();
  const until = new Date();
  const since = new Date(until.getTime() - LOOKBACK_MINUTES * 60_000);

  const records = await fetchCallDetailRecords({
    sinceISO: since.toISOString(),
    untilISO: until.toISOString(),
  });

  if (faultOf(records)) {
    // Fails LOUD but not fatally: an unsettled call keeps its reservation,
    // which over-counts the user's allowance rather than under-counting it.
    // That is the safe direction — we would rather give someone their minutes
    // back late than let a call be free.
    await sb.from("app_config").upsert({
      key: "telnyx_cdr_faults",
      value: {
        type: records.type, status: records.status,
        detail: records.detail ?? null, at: until.toISOString(),
      },
    }, { onConflict: "key" });
    console.error(JSON.stringify({ alert: "telnyx_cdr_fetch_failed", ...records }));
    return json({ ok: false, error: "cdr_unreachable" }, { status: 502 });
  }

  // The probe. Written on the FIRST run that sees any record, and never
  // overwritten with an empty one — a quiet hour must not erase the only
  // sample of the shape we have.
  if (records.length > 0) {
    await sb.from("app_config").upsert({
      key: "telnyx_cdr_probe",
      value: {
        at: until.toISOString(),
        count: records.length,
        sample: records[0].raw,
        parsed: {
          sessionId: records[0].sessionId,
          legId: records[0].legId,
          billedSeconds: records[0].billedSeconds,
          costCents: records[0].costCents,
        },
      },
    }, { onConflict: "key" });
  }

  // Only unsettled calls. `allowance_settled` is the claim flag, so a record
  // arriving twice — which it will, since the lookback overlaps every run —
  // settles once. `settle_call_claim` also re-checks it under a row lock, so
  // this filter is an optimisation rather than the correctness boundary.
  const { data: pending, error: pendErr } = await sb.from("line_calls")
    .select("id, provider_call_session_id, provider_call_leg_id, peer_e164")
    .eq("allowance_settled", false)
    .gte("created_at", new Date(until.getTime() - 24 * 60 * 60_000).toISOString())
    .limit(MAX_SETTLE);
  if (pendErr) {
    console.error(JSON.stringify({ alert: "telnyx_cdr_pending_failed", detail: pendErr.message }));
    return json({ ok: false, error: "lookup_failed" }, { status: 500 });
  }

  const bySession = new Map<string, typeof records[number]>();
  const byLeg = new Map<string, typeof records[number]>();
  for (const r of records) {
    if (r.sessionId) bySession.set(r.sessionId, r);
    if (r.legId) byLeg.set(r.legId, r);
  }

  let settled = 0, unmatched = 0, failed = 0;
  for (const call of pending ?? []) {
    const rec = (call.provider_call_session_id && bySession.get(call.provider_call_session_id))
      || (call.provider_call_leg_id && byLeg.get(call.provider_call_leg_id));
    if (!rec) { unmatched++; continue; }

    // A record with no billed figure is NOT settled. Passing 0 would hand the
    // user their whole reservation back for a call that may well have
    // connected — and once `allowance_settled` is true nothing revisits it.
    // Leaving it pending costs one more sweep; getting it wrong is permanent.
    if (rec.billedSeconds == null) { unmatched++; continue; }

    const { error } = await sb.rpc("settle_call_claim", {
      p_call: call.id,
      p_billed_seconds: rec.billedSeconds,
      p_cost_cents: rec.costCents,
      p_status: rec.billedSeconds > 0 ? "completed" : "missed",
      p_hangup_cause: rec.hangupCause,
    });
    if (error) {
      failed++;
      console.error(JSON.stringify({
        alert: "line_call_settle_failed", call: call.id, detail: error.message,
      }));
    } else {
      settled++;
    }
  }

  // The heartbeat the watchdog keys on. Written on every run including a quiet
  // one, because "no calls happened" and "this job stopped running" have to be
  // distinguishable.
  await sb.from("app_config").upsert({
    key: "telnyx_cdr_heartbeat",
    value: {
      at: until.toISOString(),
      records: records.length,
      pending: (pending ?? []).length,
      settled, unmatched, failed,
    },
  }, { onConflict: "key" });

  return json({
    ok: true,
    records: records.length,
    pending: (pending ?? []).length,
    settled, unmatched, failed,
  });
});
