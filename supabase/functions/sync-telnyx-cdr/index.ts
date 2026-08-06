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

  // How many calls are actually waiting on a CDR. Read FIRST, because it
  // decides whether a fetch failure is an incident or a non-event: with
  // nothing to settle, an unreachable CDR endpoint costs exactly nothing, and
  // paging about it every ten minutes is how the one alert channel we have
  // gets ignored.
  const { data: pending, error: pendErr } = await sb.from("line_calls")
    .select("id, provider_call_session_id, provider_call_leg_id, peer_e164")
    .eq("allowance_settled", false)
    .gte("created_at", new Date(until.getTime() - 24 * 60 * 60_000).toISOString())
    .limit(MAX_SETTLE);
  if (pendErr) {
    console.error(JSON.stringify({ alert: "telnyx_cdr_pending_failed", detail: pendErr.message }));
    return json({ ok: false, error: "lookup_failed" }, { status: 500 });
  }
  const waiting = (pending ?? []).length;

  // The last shape that worked. Without it every run re-walks the ladder from
  // the top and pays for the wrong guesses again.
  const { data: shapeRow } = await sb.from("app_config")
    .select("value").eq("key", "telnyx_cdr_shape").maybeSingle();
  const preferShape = typeof (shapeRow?.value as { index?: number } | null)?.index === "number"
    ? (shapeRow!.value as { index: number }).index
    : undefined;

  const fetched = await fetchCallDetailRecords({
    sinceISO: since.toISOString(),
    untilISO: until.toISOString(),
    preferShape,
  });

  if (faultOf(fetched)) {
    // Fails LOUD but not fatally: an unsettled call keeps its reservation,
    // which over-counts the user's allowance rather than under-counting it.
    // That is the safe direction — we would rather give someone their minutes
    // back late than let a call be free.
    await sb.from("app_config").upsert({
      key: "telnyx_cdr_faults",
      value: {
        type: fetched.type, status: fetched.status,
        detail: fetched.detail ?? null, at: until.toISOString(),
        waiting,
      },
    }, { onConflict: "key" });
    console.error(JSON.stringify({ alert: "telnyx_cdr_fetch_failed", waiting, ...fetched }));

    // Also write the heartbeat, so a persistent fetch fault does not ALSO look
    // like the job having stopped. Two different problems deserve two
    // different alarms.
    await sb.from("app_config").upsert({
      key: "telnyx_cdr_heartbeat",
      value: { at: until.toISOString(), fault: fetched.type, waiting, settled: 0 },
    }, { onConflict: "key" });

    // ⚠️ 200 WHEN NOTHING IS WAITING. `run_watchdog` pages on ANY non-2xx cron
    // relay inside 25 minutes, so returning 502 on an idle account would fire
    // the pager every ten minutes about a job with no work — and alert fatigue
    // on the only monitoring channel is how a real outage later gets missed.
    // The fault is still recorded, and still reported in the body.
    return json(
      { ok: false, error: "cdr_unreachable", waiting },
      { status: waiting > 0 ? 502 : 200 },
    );
  }

  const { records, pages, truncated, shape, types } = fetched;

  // Remember the window shape that parsed, so the steady state does not re-walk
  // the ladder and pay for the wrong guesses again. The record TYPES are
  // recorded but never cached as a filter: every valid one is queried on every
  // run, because no call has ever been placed here and locking onto whichever
  // type happened to answer first would settle nothing forever while reporting
  // success. See CDR_RECORD_TYPES.
  if (preferShape !== shape) {
    await sb.from("app_config").upsert({
      key: "telnyx_cdr_shape",
      value: { index: shape, types, at: until.toISOString() },
    }, { onConflict: "key" });
    console.log(JSON.stringify({ telnyx_cdr_shape_found: shape, types }));
  }

  // ⚠️ NEVER SILENT. A truncated page walk looks exactly like "there were only
  // this many records", and the calls it drops are the OLDEST ones — the ones
  // closest to being written off by the six-hour stale sweep at the client's
  // word instead of Telnyx's. Reported here and in the heartbeat so a busy
  // hour is visible rather than inferred.
  if (truncated) {
    console.error(JSON.stringify({
      alert: "telnyx_cdr_truncated", pages, records: records.length,
    }));
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

  // `pending` was read at the top of the request — before the fetch, because
  // whether there is anything waiting decides whether a fetch failure is an
  // incident. `allowance_settled` is the claim flag, so a record arriving
  // twice — which it will, since the lookback overlaps every run — settles
  // once. `settle_call_claim` also re-checks it under a row lock, so this
  // filter is an optimisation rather than the correctness boundary.
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
      // The EXACT figure. `costCents` rounds a fraction-of-a-cent leg to zero,
      // which would make every margin reading over this table circular.
      p_cost_usd: rec.costUsd,
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
      settled, unmatched, failed, pages, truncated,
    },
  }, { onConflict: "key" });

  return json({
    ok: true,
    records: records.length,
    pending: (pending ?? []).length,
    settled, unmatched, failed, pages, truncated,
  });
});
