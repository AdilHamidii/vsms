// probe-telnyx-connection — READ-ONLY diagnostic. Cron-secret gated.
//
// THREE modes. All are GETs against Telnyx and none of them spends money.
//
//  1. GET  ?connection_id=<digits>          — the credential-connection probe
//  2. POST {"probe":"cdr", …}               — the detail-record probe
//  3. POST {"probe":"coverage"}             — the country-catalogue probe
//  4. POST {"probe":"numbers"}              — every number Telnyx says we own, joined to phone_lines
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
// ── Mode 3: why it exists ───────────────────────────────────────────────────
// The rentable-number line sells from a hardcoded 7-Canadian-city list, and
// `_shared/telnyx.ts::searchNumbers` hardcodes BOTH
// `filter[phone_number_type]=local` AND `filter[features][]=sms,voice`. On a
// country whose local numbers carry voice but no SMS that filter returns zero
// rows, which every caller reads as "out of stock" — a SILENT FALSE STOCKOUT,
// not a provider fact. Nothing in the repo has ever called
// `GET /v2/requirements`, and `regulatory_requirements` in a search result is
// always null and means nothing (it cost $3.83 to learn that).
//
// So three questions, each with a cell that separates it from the others:
//
//   (i)   WHAT DOES EACH COUNTRY ACTUALLY SUPPORT? → `/v2/country_coverage`,
//         list plus a per-country detail attempt, so we learn which shape
//         exists rather than assuming one.
//   (ii)  WHICH COUNTRIES NEED DOCUMENTS? → `/v2/requirements?…&action=ordering`
//         per sample country. Empty ⇒ orderable with no paperwork. This is the
//         reliable pre-purchase source; the search endpoint is not.
//   (iii) THE FALSIFIER: GB (and DE) local searched three ways — no features
//         filter, `voice` only, and the `sms+voice` pair we hardcode today. If
//         (c) is empty while (a)/(b) are not, the false stockout is PROVEN
//         rather than argued.
//
// Plus two controls, because on this API a 200 is not evidence (documented
// three times already): a nonsense country code, which says whether a bad
// filter is silently accepted, and `/v2/requirement_groups`, which says
// whether the pre-verification path we would need even has an entity yet.
//
// NOTHING IS CACHED and nothing Telnyx-side is written. Mode 3 upserts its own
// result into `app_config.telnyx_coverage_probe` for one reason only: the
// response is far larger than `net._http_response` will retain, and a probe
// nobody can read is not a probe. Same shape as `telnyx_cdr_probe`.
import { corsHeaders } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";

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

const UUID_LIKE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

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

// ── Mode 3 plumbing ─────────────────────────────────────────────────────────

/** The sample set. US/CA/PR are the NANP catalogue we already sell or could;
 *  GB/FR/DE/NL/PL/AU are the "voice-only?" candidates the plan turns on. */
const COVERAGE_COUNTRIES = ["US", "CA", "GB", "FR", "DE", "NL", "PL", "AU", "PR"] as const;

/** Cap on mode-3 requests. The whole sweep is ~28; anything past this is a
 *  loop bug, and a runaway sweep reads as a hang at the ~150s edge kill. */
const MAX_COVERAGE_REQUESTS = 34;

interface Get {
  url: string;
  http: number;
  /** Length of `data` when the body parses to `{data: [...]}`. */
  rows?: number | null;
  /** Key names of the first row — the fastest way to see a shape we guessed. */
  first_row_keys?: string[];
  /** Parsed `data`, kept only where the caller asked for it. */
  data?: unknown;
  /** Verbatim, truncated. A 4xx here names the parameter that is wrong. */
  body?: string;
}

/** Telnyx rate-limits this account. The first run of mode 3 fired ~28 requests
 *  back to back and took **429 on four of the nine requirement reads** — which
 *  is indistinguishable from "this country has no requirements" unless the
 *  status is read, and reading a 429 as zero documents would mark a country
 *  sellable that needs paperwork. Space them out; the whole sweep is still well
 *  inside the ~150s edge kill. */
const COVERAGE_SPACING_MS = 400;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** One GET, budgeted. Returns the parsed `data` only when `keep` is set —
 *  everything else is reduced to counts and key names so the result stays
 *  readable and storable. */
async function get(
  key: string,
  path: string,
  budget: { left: number },
  keep = false,
): Promise<Get> {
  const url = `${TELNYX}${path}`;
  if (budget.left <= 0) return { url, http: 0, body: "request budget exhausted" };
  budget.left--;
  await sleep(COVERAGE_SPACING_MS);

  let res: Response;
  try {
    res = await fetch(url, { headers: { Authorization: `Bearer ${key}` } });
  } catch (e) {
    return { url, http: 0, body: `transport: ${String(e)}` };
  }
  const text = await res.text();
  if (!res.ok) return { url, http: res.status, body: trunc(text, 900) };

  let data: unknown = null;
  try {
    data = (JSON.parse(text) as { data?: unknown }).data ?? null;
  } catch {
    return { url, http: res.status, body: trunc(text, 900) };
  }
  const rows = Array.isArray(data) ? data.length : null;
  const out: Get = { url, http: res.status, rows };
  if (Array.isArray(data) && data.length > 0 && typeof data[0] === "object" && data[0]) {
    out.first_row_keys = Object.keys(data[0] as Record<string, unknown>).sort();
  }
  if (keep) out.data = data;
  return out;
}

/** 🔴 `/v2/requirements` returns ONE row per (country, phone_number_type,
 *  action) — a requirement *set* — and the individual documents live in that
 *  row's `requirement_types[]`. So `data.length` is 0 or 1 and is NOT the
 *  document count; the first run of this probe slimmed the outer row and got a
 *  field of nulls. Measured shape of the outer row: `{id, country_code,
 *  phone_number_type, action, locality, requirement_types, record_type,
 *  version, effective_start_at/end_at, created_at, updated_at}`.
 *
 *  Entries are kept VERBATIM apart from truncating long prose, because their
 *  own shape is not something to guess a second time. */
function slimRequirementType(t: unknown): unknown {
  if (!t || typeof t !== "object") return t;
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(t as Record<string, unknown>)) {
    out[k] = typeof v === "string" && v.length > 180 ? trunc(v, 180) : v;
  }
  return out;
}

/** Three-way search on ONE (country, type): no features filter, voice only,
 *  and the sms+voice pair `searchNumbers` hardcodes today. The gap between the
 *  first two and the third IS the false stockout. */
async function featureTriplet(
  key: string,
  country: string,
  budget: { left: number },
): Promise<Record<string, Get & { first_row_features?: unknown; first_row_cost?: unknown }>> {
  const base =
    `/available_phone_numbers?filter[country_code]=${country}` +
    `&filter[phone_number_type]=local&filter[limit]=3`;
  const cells: Record<string, string> = {
    a_no_features_filter: base,
    b_voice_only: `${base}&filter[features][]=voice`,
    "c_sms_and_voice(what_we_send_today)": `${base}&filter[features][]=sms&filter[features][]=voice`,
  };
  const out: Record<string, Get & { first_row_features?: unknown; first_row_cost?: unknown }> = {};
  for (const [name, path] of Object.entries(cells)) {
    const keep = name === "a_no_features_filter";
    const r = await get(key, path, budget, keep) as
      Get & { first_row_features?: unknown; first_row_cost?: unknown };
    if (keep && Array.isArray(r.data) && r.data.length > 0) {
      const row = r.data[0] as Record<string, unknown>;
      r.first_row_features = row.features ?? null;
      r.first_row_cost = row.cost_information ?? null;
      // The full row list is noise once its two interesting fields are lifted.
      r.data = undefined;
    }
    out[name] = r;
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

  // ── Mode 3: the country-catalogue probe ───────────────────────────────────
  if (body.probe === "coverage") {
    const budget = { left: MAX_COVERAGE_REQUESTS };

    // (1) The whole coverage table, once. We keep only the row count, the key
    //     names (the shape is guessed nowhere else in this repo) and the rows
    //     for the sample countries — the full table is hundreds of rows.
    //     ⚠️ `data` here is an OBJECT, not an array — measured, not assumed —
    //     so `rows` is null and the useful figure is the key count.
    const listed = await get(key, `/country_coverage`, budget, true);
    const listObj = (listed.data && typeof listed.data === "object" && !Array.isArray(listed.data))
      ? listed.data as Record<string, unknown>
      : null;
    const coverage_list = {
      http: listed.http,
      data_kind: Array.isArray(listed.data) ? "array" : listed.data === null ? "null" : typeof listed.data,
      entry_count: listObj ? Object.keys(listObj).length : (listed.rows ?? null),
      first_entry_key: listObj ? Object.keys(listObj)[0] ?? null : null,
      first_entry_field_keys: listObj && typeof Object.values(listObj)[0] === "object"
        ? Object.keys(Object.values(listObj)[0] as Record<string, unknown>).sort()
        : (listed.first_row_keys ?? null),
      body: listed.body ?? null,
    };

    // The per-country detail endpoint EXISTS and returns the richer shape,
    // keyed by the country's full NAME rather than its code.
    const coverage_detail: Record<string, Get> = {};
    for (const cc of COVERAGE_COUNTRIES) {
      coverage_detail[cc] = await get(key, `/country_coverage/countries/${cc}`, budget, true);
    }

    // (2) Ordering requirements per sample country. EMPTY IS THE WHOLE ANSWER:
    //     zero rows ⇒ no documents ⇒ orderable today. A fault is NOT empty and
    //     must never be read as one.
    const requirements: Record<string, unknown> = {};
    for (const cc of COVERAGE_COUNTRIES) {
      const r = await get(
        key,
        `/requirements?filter[country_code]=${cc}` +
          `&filter[phone_number_type]=local&filter[action]=ordering`,
        budget,
        true,
      );
      const rows = Array.isArray(r.data) ? r.data as Record<string, unknown>[] : [];
      // Flatten every set's documents. `sets` is 0 or 1; `document_count` is
      // the number that decides sellability, and a non-200 leaves BOTH null so
      // a failed read can never be mistaken for "no documents".
      const docs = rows.flatMap((row) =>
        Array.isArray(row.requirement_types) ? row.requirement_types : []
      );
      requirements[cc] = {
        http: r.http,
        sets: r.rows ?? null,
        document_count: r.http === 200 ? docs.length : null,
        set_keys: r.first_row_keys ?? null,
        requirement_types: docs.slice(0, 12).map(slimRequirementType),
        body: r.body ?? null,
      };
    }

    // (3) THE FALSIFIER. GB is the country the plan names; DE is the one the
    //     portal and Telnyx's own marketing disagree about, so it settles a
    //     second question for three more requests.
    const falsifier = {
      GB_local: await featureTriplet(key, "GB", budget),
      DE_local: await featureTriplet(key, "DE", budget),
      US_local_control: await get(
        key,
        `/available_phone_numbers?filter[country_code]=US&filter[phone_number_type]=local&filter[limit]=3`,
        budget,
      ),
    };

    // (4) Does the pre-verification path exist as an entity on this account?
    const requirement_groups = await get(key, `/requirement_groups`, budget, true);

    // (5) The control this API has earned: a nonsense country code. If it 200s
    //     with rows, no filter on this endpoint can be trusted at all.
    const nonsense_country = await get(
      key,
      `/available_phone_numbers?filter[country_code]=ZZ&filter[limit]=1`,
      budget,
    );

    const result = {
      mode: "coverage",
      at: new Date().toISOString(),
      countries: COVERAGE_COUNTRIES,
      requests_used: MAX_COVERAGE_REQUESTS - budget.left,
      coverage_list,
      coverage_detail,
      requirements,
      falsifier,
      requirement_groups,
      nonsense_country,
      note:
        "requirements.rows === 0 means no documents. A non-200 is NOT zero. " +
        "In `falsifier`, cell (c) empty while (a)/(b) are not proves the " +
        "hardcoded sms+voice filter is manufacturing a false stockout.",
    };

    // Persist it: the response is larger than `net._http_response` retains, and
    // a probe whose output cannot be read afterwards settles nothing.
    const { error: writeErr } = await admin().from("app_config").upsert({
      key: "telnyx_coverage_probe",
      value: result,
    });

    return Response.json({ ...result, stored: writeErr ? `error: ${writeErr.message}` : true });
  }

  // ── Mode 4: the owned-numbers reconciliation ──────────────────────────────
  // POST {"probe":"numbers"}. Answers "why does the Telnyx dashboard say N
  // active numbers" by putting Telnyx's own list beside ours. The orphan sweep
  // in `release-lines` deliberately judges ONLY numbers carrying a UUID
  // `customer_reference`; a number without one is invisible to it and still
  // bills every month. This mode lists every number, tagged with how (or
  // whether) it joins back to `phone_lines` / `line_number_swaps`, and writes
  // the result to `app_config.telnyx_numbers_probe` (service-role only).
  if (body.probe === "numbers") {
    const r = await fetch(`${TELNYX}/phone_numbers?page[size]=250`, {
      headers: { Authorization: `Bearer ${key}` },
    });
    const j = await r.json().catch(() => ({})) as { data?: Array<Record<string, unknown>>; meta?: unknown };
    const owned = Array.isArray(j.data) ? j.data : [];
    const sb = admin();
    const e164s = owned.map((n) => String(n.phone_number));
    const refs = owned.map((n) => String(n.customer_reference ?? "")).filter((s) => UUID_LIKE.test(s));
    const [{ data: byE164 }, { data: byRef }, { data: swaps }] = await Promise.all([
      sb.from("phone_lines").select("id, e164, status, billing, user_id, released_at").in("e164", e164s),
      refs.length
        ? sb.from("phone_lines").select("id, e164, status, billing, user_id, released_at").in("id", refs)
        : Promise.resolve({ data: [] as Array<Record<string, unknown>> }),
      sb.from("line_number_swaps").select("old_e164, new_e164, state, old_released_at")
        .or(`old_e164.in.(${e164s.join(",")}),new_e164.in.(${e164s.join(",")})`),
    ]);
    const lineByE164 = new Map((byE164 ?? []).map((l) => [String(l.e164), l]));
    const lineById = new Map((byRef ?? []).map((l) => [String(l.id), l]));
    const numbers = owned.map((n) => {
      const e164 = String(n.phone_number);
      const ref = (n.customer_reference as string | null) ?? null;
      const viaE164 = lineByE164.get(e164) ?? null;
      const viaRef = ref && UUID_LIKE.test(ref) ? lineById.get(ref) ?? null : null;
      const swap = (swaps ?? []).filter((s) => s.old_e164 === e164 || s.new_e164 === e164);
      const line = viaE164 ?? viaRef;
      const verdict = !line
        ? (ref ? "ref_points_nowhere" : "no_reference_no_row")
        : line.status === "released" || line.status === "failed"
          ? `row_${line.status}_but_still_at_telnyx`
          : `held_by_${line.status}_line`;
      return {
        e164, id: String(n.id), telnyx_status: n.status ?? null,
        created_at: n.created_at ?? null, purchased_at: n.purchased_at ?? null,
        customer_reference: ref, tags: n.tags ?? null,
        connection_id: n.connection_id ?? null,
        messaging_profile_id: n.messaging_profile_id ?? null,
        line: line ? {
          id: String(line.id), status: line.status, billing: line.billing,
          user: String(line.user_id).slice(0, 8), released_at: line.released_at,
          matched_by: viaE164 ? "e164" : "reference",
        } : null,
        swaps: swap.map((s) => ({ role: s.old_e164 === e164 ? "old" : "new", state: s.state, old_released_at: s.old_released_at })),
        verdict,
      };
    });
    const result = {
      mode: "numbers", at: new Date().toISOString(), http: r.status,
      telnyx_count: owned.length, meta: j.meta ?? null,
      by_verdict: numbers.reduce<Record<string, number>>((acc, n) => {
        acc[n.verdict] = (acc[n.verdict] ?? 0) + 1; return acc;
      }, {}),
      numbers,
    };
    const { error: writeErr } = await sb.from("app_config").upsert(
      { key: "telnyx_numbers_probe", value: result }, { onConflict: "key" });
    return Response.json({ ...result, stored: writeErr ? `error: ${writeErr.message}` : true });
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
