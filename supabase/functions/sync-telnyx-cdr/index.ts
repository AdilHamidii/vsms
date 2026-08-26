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
// ⚠️ **IT MATCHED NOTHING FOR TWENTY DAYS AND REPORTED SUCCESS THE WHOLE TIME.**
// From 2026-08-06 to 2026-08-26 this function ran every ten minutes, wrote a
// healthy heartbeat, and settled ZERO records, so every call in the product's
// history was billed its flat reservation by the six-hour `settle_stale_calls`
// backstop — a fallback documented as rare, silently made universal.
//
// THREE independent defects, all of which had to be fixed for one settlement,
// each of which alone was sufficient to settle nothing, and none of which threw:
//   1. the window filter `filter[start_time][gte]` returns **200 with zero
//      rows** on this endpoint. The old ladder scored a 200 as "this shape
//      works" and cached it. Now `filter[date_range]=last_30_days`, probed.
//   2. `normaliseCallRecord` read `session_id` — the SDK's own uuid — where our
//      ids live in `telnyx_session_id`. 43 of 43 webrtc rows normalised onto an
//      id that can never match; 50 sip-trunking rows were dropped entirely.
//   3. the billed-duration field is `call_sec` / `billed_sec`; none of the four
//      documented names exists on a live record, so a matched record would
//      still have had `billedSeconds: null` and been skipped as unmatched.
//
// All three were found by `probe-telnyx-connection` mode "cdr" on 2026-08-26,
// after two earlier rounds of guessing from the documentation. `raw_rows` is
// now reported next to `records` precisely so defect 2 can never be silent
// again. `telnyx_cdr_probe` still records the raw shape of the first record
// seen and `telnyx_cdr_faults` every fault. **Read those keys before trusting
// any figure here.**
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

  // The pending window defaults to 24h — a cron sweep only ever needs to see
  // recent claims. `lookback_hours` widens it for RECOVERY: re-open mis-settled
  // rows (clear allowance_settled) and invoke with a window that reaches them,
  // so the correction runs through this exact settlement path instead of
  // hand-written UPDATEs. Cron-secret-gated like everything else here; clamped
  // so a typo cannot turn into an unbounded scan. First used 2026-08-26 to
  // re-settle the 11 calls the no-CDR era billed at a flat 120s.
  let pendingLookbackHours = 24;
  try {
    const body = await req.json().catch(() => ({}));
    const lb = Number((body as { lookback_hours?: unknown }).lookback_hours);
    if (Number.isFinite(lb)) pendingLookbackHours = Math.min(Math.max(lb, 1), 720);
  } catch { /* no body — the cron relay sends {} */ }

  // How many calls are actually waiting on a CDR. Read FIRST, because it
  // decides whether a fetch failure is an incident or a non-event: with
  // nothing to settle, an unreachable CDR endpoint costs exactly nothing, and
  // paging about it every ten minutes is how the one alert channel we have
  // gets ignored.
  const { data: pending, error: pendErr } = await sb.from("line_calls")
    .select("id, provider_call_session_id, provider_call_leg_id, peer_e164")
    .eq("allowance_settled", false)
    .gte("created_at", new Date(until.getTime() - pendingLookbackHours * 60 * 60_000).toISOString())
    .limit(MAX_SETTLE);
  if (pendErr) {
    console.error(JSON.stringify({ alert: "telnyx_cdr_pending_failed", detail: pendErr.message }));
    return json({ ok: false, error: "lookup_failed" }, { status: 500 });
  }
  const waiting = (pending ?? []).length;

  // 🔴 THE SHAPE CACHE IS GONE, AND ITS REMOVAL IS THE FIX. This used to read
  // `app_config.telnyx_cdr_shape` for "the last window filter that worked" and
  // try it first. It cached index 0 — `filter[start_time][gte]` — on
  // 2026-08-06 because that shape returns **HTTP 200 with zero rows**, which
  // the ladder scored as success. So the poller asked a dead filter for twenty
  // days, settled nothing, and wrote a healthy heartbeat every ten minutes.
  //
  // The window is now the single proven `filter[date_range]=last_30_days`
  // (see CDR_DATE_RANGE in _shared/telnyx.ts), so there is nothing to cache and
  // no ladder to re-walk. **The stale `telnyx_cdr_shape` key is now read by
  // nobody and can be deleted** — it is left alone here rather than deleted on
  // the fly, because a sweep silently rewriting config keys is its own trap.
  const fetched = await fetchCallDetailRecords({
    sinceISO: since.toISOString(),
    untilISO: until.toISOString(),
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

  const { records, pages, truncated, shape, types, rawRows } = fetched;

  // ⚠️ ROWS ARRIVED BUT NONE SURVIVED NORMALISATION. That is the second half of
  // the 2026-08-26 bug — `normaliseCallRecord` was reading `session_id` (the
  // SDK's own uuid) instead of `telnyx_session_id` (ours), so 43 webrtc rows
  // normalised onto ids that can never match and 50 sip-trunking rows were
  // dropped outright. Both looked identical to "Telnyx returned nothing".
  // Never let that be silent again: it is a fault, not a quiet hour.
  if (rawRows > 0 && records.length === 0) {
    console.error(JSON.stringify({
      alert: "telnyx_cdr_all_dropped", rawRows, types,
      detail: "detail records returned but none carried a readable id — check normaliseCallRecord's field names against a raw row",
    }));
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
      // What Telnyx actually returned, before normalisation and merging.
      // `raw_rows > 0` with `records: 0` is a live defect, not a quiet hour —
      // the distinction the old heartbeat could not express.
      raw_rows: rawRows,
      window: shape,
      types,
      pending: (pending ?? []).length,
      settled, unmatched, failed, pages, truncated,
    },
  }, { onConflict: "key" });

  return json({
    ok: true,
    records: records.length,
    raw_rows: rawRows,
    window: shape,
    types,
    pending: (pending ?? []).length,
    settled, unmatched, failed, pages, truncated,
  });
});
