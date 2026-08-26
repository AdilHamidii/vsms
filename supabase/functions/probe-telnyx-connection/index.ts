// probe-telnyx-connection — READ-ONLY diagnostic. Cron-secret gated.
//
// TWO modes. Both are GETs against Telnyx and write nothing anywhere.
//
//  1. GET  ?connection_id=<digits>          — the credential-connection probe
//  2. POST {"probe":"cdr", …}               — the detail-record probe
//
// The API key never leaves the platform: this runs edge-side. Mode 1 returns a
// projection. Mode 2 returns RAW response bodies (truncated) on purpose — the
// whole point is to see what Telnyx actually says, not what we assumed it says.
//
// ── Mode 1: why it exists ───────────────────────────────────────────────────
// Reads a credential connection back from Telnyx and returns ONLY the fields
// that decide whether the connection can place an outbound call. Exists
// because `attachOutboundProfile` PATCHed `outbound_voice_profile_id` at the
// TOP LEVEL while the docs put it under `outbound: {}` — and Telnyx returns
// 200-and-changes-nothing for a misplaced field (documented twice already in
// providers.md). Our DB says `provider_voice_attached = true`; this asks
// Telnyx what it actually holds. If `outbound.outbound_voice_profile_id` reads
// null on a line we marked attached, every outbound dial is rejected before a
// session exists — which is exactly the 0-of-7 symptom.
//
// ── Mode 2: why it exists ───────────────────────────────────────────────────
// `sync-telnyx-cdr` has matched ZERO detail records in the product's history.
// `app_config.telnyx_cdr_heartbeat` reads {pages: 4, records: 0, settled: 0} —
// the request shape parses, all four record types answer 200, and nothing ever
// comes back — while `line_calls` holds 12 rows carrying a
// `provider_call_session_id`. So every call is billed its flat reservation by
// the six-hour backstop, which the migration that wrote it justified on the
// premise that the backstop is RARE. It is universal.
//
// The detail-records query has already been wrong TWICE for exactly the reason
// this repo warns about — written from documentation rather than probed:
// `filter[date_range][start_time]` 400'd, then `record_type: "call"` 400'd. So
// the rule ("assume a third cause before assuming provider lag") says probe,
// and probe in a way that DISCRIMINATES rather than confirms.
//
// FIVE candidate causes, and one probe step separates each:
//
//   (a) WRONG WINDOW FILTER, silently ignored or silently empty.
//       🔴 The strongest lead. Telnyx's OpenAPI spec (spec3.json, operationId
//       SearchDetailRecords) has NO `start_time` filter at all — the documented
//       fields are `filter[created_at][gte]/[lt]` and a friendly
//       `filter[date_range]=last_N_days`. We cached shape index 0 =
//       `filter[start_time][gte]` on 2026-08-06 because it returned 200, and
//       the spec marks the filter object `additionalProperties: true` — so an
//       unknown key may be ACCEPTED AND IGNORED, or accepted and matched
//       against nothing. A 200 was read as "this shape parses". It is not
//       evidence, exactly as the outbound-profile PATCH's 200 was not.
//       → `matrix` runs every window shape, including the two spec-documented
//         ones we have never tried and a no-window control.
//
//   (b) WRONG RECORD TYPE. We query 4 of the 21 the spec enumerates. A WebRTC
//       call to the PSTN writes TWO records — one `webrtc`, one `sip-trunking`
//       — so the type is probably right, but "probably" is what cost the last
//       two rounds.
//       → `matrix` sweeps a wider type list; `invalid_type` asks Telnyx to
//         name the valid ones in its own 400.
//
//   (c) ID-FORMAT MISMATCH. `UUID.uuidString` is UPPERCASE and Telnyx's ids are
//       lowercase; `sync-telnyx-cdr` matches with an exact-string lookup. Our
//       stored ids are already lowercase, so this is unlikely — but it is one
//       request to rule out rather than reason about.
//       → `by_id` looks each id up in both cases across every plausible filter
//         key.
//
//   (d) RECORDS ARRIVE AND WE THROW THEM AWAY. `normaliseCallRecord` returns
//       null for a row carrying neither `call_session_id`/`session_id` nor
//       `call_leg_id`/`leg_id`, and the caller drops those silently — so
//       `records: 0` in the heartbeat CANNOT distinguish "Telnyx returned
//       nothing" from "Telnyx returned rows whose id fields we do not read".
//       The webrtc record is documented to carry `telnyx_session_id` /
//       `telnyx_leg_id` / `call_id`, none of which normalise reads.
//       → every matrix cell reports `raw_rows` AND `normalised` AND the KEY
//         NAMES of the first row. Those three numbers separate (a)/(b) from (d)
//         outright.
//
//   (e) THE ACCOUNT SIMPLY HAS NO CDRs (retention, entitlement, or a lag longer
//       than our 180-minute lookback).
//       → the no-window control plus a 30-day window: if every shape and every
//         type returns zero rows over 30 days, the data is not there and the
//         next step is Telnyx support, not another parameter guess.
//
// Also checked because it is free: `page[size]` is capped at **50** in the
// spec and `sync-telnyx-cdr` sends **250**. An over-max page size that returns
// 200-and-empty would produce exactly the symptom we have.
//
// NOTHING HERE IS CACHED AND NOTHING IS WRITTEN. Read the result, then change
// `_shared/telnyx.ts` on the strength of it.
import { corsHeaders } from "../_shared/cors.ts";

const TELNYX = "https://api.telnyx.com/v2";

/** Every record_type in Telnyx's OpenAPI spec that could plausibly carry a
 *  voice leg, most-likely first. `call` is NOT one — it 400s, which is how the
 *  second wrong guess was caught. */
const DEFAULT_TYPES = [
  "webrtc",
  "sip-trunking",
  "call-control",
  "conference",
  "conference-participant",
  "recording",
] as const;

/** Window shapes. The first two are what the SPEC documents and what we have
 *  never sent; the third is the shape we have been caching since 2026-08-06;
 *  the fourth is the one that 400'd on the first production run; the last is
 *  the no-window control that says whether ANY record exists at all. */
function windowShapes(sinceISO: string, untilISO: string, days: number) {
  return [
    { name: "created_at_gte_lt", params: { "filter[created_at][gte]": sinceISO, "filter[created_at][lt]": untilISO } },
    { name: "date_range_last_n_days", params: { "filter[date_range]": `last_${days}_days` } },
    { name: "start_time_gte_lte(cached)", params: { "filter[start_time][gte]": sinceISO, "filter[start_time][lte]": untilISO } },
    { name: "date_range_start_end(400'd once)", params: { "filter[date_range][start_time]": sinceISO, "filter[date_range][end_time]": untilISO } },
    { name: "no_window", params: {} as Record<string, string> },
  ];
}

/** Filter keys an id could be looked up under. `call_session_id`/`call_leg_id`
 *  are what the typed schemas use; `telnyx_session_id`/`telnyx_leg_id`/`uuid`
 *  are what the WebRTC and SIP-trunking record docs describe. */
const ID_FILTER_KEYS = [
  "filter[call_session_id]",
  "filter[call_leg_id]",
  "filter[telnyx_session_id]",
  "filter[uuid]",
  "filter[id]",
] as const;

/** Hard ceiling on outbound requests. The edge runtime dies at ~150s and a
 *  full sweep is a few dozen calls; a runaway matrix would look like a hang. */
const MAX_REQUESTS = 90;

interface Probe {
  url: string;
  http: number;
  /** Rows Telnyx returned, BEFORE our normalisation drops any. */
  raw_rows: number | null;
  /** Rows that carry an id `normaliseCallRecord` would read. The gap between
   *  this and `raw_rows` IS cause (d). */
  normalised: number | null;
  /** Key names of the first row. The fastest way to see which id fields a
   *  record type actually carries. */
  first_row_keys?: string[];
  /** The whole first row, once, so the shape is on record rather than inferred. */
  first_row?: unknown;
  /** Verbatim, truncated. A 400 here names the parameter that is wrong. */
  body?: string;
}

function trunc(s: string, n = 1200): string {
  return s.length > n ? s.slice(0, n) + `…[+${s.length - n}]` : s;
}

/** Mirrors `normaliseCallRecord` in `_shared/telnyx.ts`. Deliberately a COPY,
 *  not an import: the point of this probe is to measure what that function
 *  discards, and importing it would move with it. */
function hasReadableId(r: Record<string, unknown>): boolean {
  return !!(r.call_session_id ?? r.session_id ?? r.call_leg_id ?? r.leg_id);
}

async function probe(key: string, params: Record<string, string>, budget: { left: number }): Promise<Probe> {
  const qs = new URLSearchParams(params).toString();
  const url = `${TELNYX}/detail_records?${qs}`;
  if (budget.left <= 0) return { url, http: 0, raw_rows: null, normalised: null, body: "request budget exhausted" };
  budget.left--;

  let res: Response;
  try {
    res = await fetch(url, { headers: { Authorization: `Bearer ${key}` } });
  } catch (e) {
    return { url, http: 0, raw_rows: null, normalised: null, body: `transport: ${String(e)}` };
  }
  const text = await res.text();
  if (!res.ok) return { url, http: res.status, raw_rows: null, normalised: null, body: trunc(text) };

  let rows: Record<string, unknown>[] = [];
  try {
    const j = JSON.parse(text) as { data?: unknown };
    rows = Array.isArray(j.data) ? (j.data as Record<string, unknown>[]) : [];
  } catch {
    return { url, http: res.status, raw_rows: null, normalised: null, body: trunc(text) };
  }
  const out: Probe = {
    url,
    http: res.status,
    raw_rows: rows.length,
    normalised: rows.filter(hasReadableId).length,
  };
  if (rows.length > 0) {
    out.first_row_keys = Object.keys(rows[0]).sort();
    out.first_row = rows[0];
  }
  return out;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const secret = Deno.env.get("CRON_SECRET");
  if (!secret || req.headers.get("x-cron-secret") !== secret) {
    return new Response("forbidden", { status: 403 });
  }
  const key = Deno.env.get("TELNYX_API_KEY");
  if (!key) return Response.json({ error: "no_api_key" }, { status: 500 });

  const body = req.method === "POST"
    ? await req.json().catch(() => ({})) as Record<string, unknown>
    : {};

  // ── Mode 2: the detail-record probe ───────────────────────────────────────
  if (body.probe === "cdr") {
    const days = Math.min(Math.max(Number(body.days ?? 30) || 30, 1), 90);
    const until = new Date();
    const since = new Date(until.getTime() - days * 24 * 60 * 60_000);
    const types = Array.isArray(body.types) && body.types.length
      ? (body.types as string[]).slice(0, 8)
      : [...DEFAULT_TYPES];
    const ids = (Array.isArray(body.session_ids) ? body.session_ids as string[] : [])
      .filter((s) => typeof s === "string" && s.length > 8).slice(0, 3);
    const budget = { left: MAX_REQUESTS };

    // (1) No filters at all, and record_type with no window. The first answers
    //     "which filters does Telnyx consider required"; the second answers
    //     "is a date filter mandatory for this record type" — a question the
    //     spec leaves open (`required: ["record_type"]` only) and which no
    //     amount of re-reading will settle.
    const required = {
      no_filters: await probe(key, { "page[size]": "5" }, budget),
      record_type_only: await probe(key, { "filter[record_type]": types[0], "page[size]": "5" }, budget),
    };

    // (2) Ask Telnyx to enumerate the valid record types in its own words. The
    //     400 for `call` is already known; capturing it verbatim is how we
    //     learn whether the message lists the alternatives.
    const invalid_type = await probe(key, { "filter[record_type]": "call", "page[size]": "5" }, budget);

    // (3) `page[size]` is capped at 50 in the spec and `sync-telnyx-cdr` sends
    //     250. If 250 returns 200-and-empty while 50 returns rows, THAT is the
    //     whole bug and every other cell here will look healthy.
    const page_size = {
      size_50: await probe(key, { "filter[record_type]": types[0], "filter[date_range]": `last_${days}_days`, "page[size]": "50" }, budget),
      size_250: await probe(key, { "filter[record_type]": types[0], "filter[date_range]": `last_${days}_days`, "page[size]": "250" }, budget),
    };

    // (4) The matrix: every window shape × every record type. `raw_rows` vs
    //     `normalised` is the discriminator that the heartbeat's single
    //     `records` figure cannot give — see cause (d) in the header.
    const matrix: Record<string, Record<string, Probe>> = {};
    for (const shape of windowShapes(since.toISOString(), until.toISOString(), days)) {
      matrix[shape.name] = {};
      for (const t of types) {
        matrix[shape.name][t] = await probe(key, {
          "filter[record_type]": t,
          ...shape.params,
          "page[size]": "50",
        }, budget);
      }
    }

    // (5) Direct id lookups, original AND lowercased. Our stored ids are
    //     already lowercase, so a difference here would mean the mismatch is
    //     on Telnyx's side rather than ours — worth one request to know rather
    //     than to assume.
    const by_id: Record<string, Record<string, Probe>> = {};
    for (const raw of ids) {
      for (const form of [raw, raw.toLowerCase()].filter((v, i, a) => a.indexOf(v) === i)) {
        by_id[form] = {};
        for (const fk of ID_FILTER_KEYS) {
          by_id[form][fk] = await probe(key, {
            "filter[record_type]": types[0],
            [fk]: form,
            "page[size]": "5",
          }, budget);
        }
      }
    }

    return Response.json({
      mode: "cdr",
      window: { since: since.toISOString(), until: until.toISOString(), days },
      types,
      ids_probed: ids,
      requests_used: MAX_REQUESTS - budget.left,
      // Read in this order. `required` and `invalid_type` say what the API
      // wants; `page_size` and `matrix` say whether our request was ever
      // capable of returning a row; `by_id` says whether the row exists at all
      // under a different key.
      required,
      invalid_type,
      page_size,
      matrix,
      by_id,
      note:
        "raw_rows > 0 with normalised = 0 means Telnyx IS returning records and " +
        "normaliseCallRecord is discarding them — fix the id field names, not the filter.",
    });
  }

  // ── Mode 1: the credential-connection probe ───────────────────────────────
  const url = new URL(req.url);
  const id = url.searchParams.get("connection_id") ?? (body.connection_id as string | undefined) ?? null;
  if (!id || !/^\d{6,30}$/.test(id)) {
    return Response.json(
      { error: "connection_id required (digits), or POST {\"probe\":\"cdr\"}" },
      { status: 400 },
    );
  }
  const r = await fetch(`${TELNYX}/credential_connections/${id}`, {
    headers: { Authorization: `Bearer ${key}` },
  });
  const j = await r.json().catch(() => ({}));
  const d = (j as { data?: Record<string, unknown> }).data ?? {};
  const outbound = (d.outbound ?? null) as Record<string, unknown> | null;
  return Response.json({
    http: r.status,
    connection_id: d.id ?? null,
    active: d.active ?? null,
    // The two places the profile could live. Docs say `outbound.*`.
    outbound_voice_profile_id_top_level: d.outbound_voice_profile_id ?? null,
    outbound_voice_profile_id_nested: outbound?.outbound_voice_profile_id ?? null,
    outbound_block_keys: outbound ? Object.keys(outbound) : null,
    ios_push_credential_id: d.ios_push_credential_id ?? null,
    sip_uri_calling_preference: d.sip_uri_calling_preference ?? null,
  });
});
