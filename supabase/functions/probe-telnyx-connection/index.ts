// probe-telnyx-connection — READ-ONLY diagnostic. Cron-secret gated.
//
// THREE modes. All are GETs against Telnyx and none of them spends money.
//
//  1. GET  ?connection_id=<digits>          — the credential-connection probe
//  2. POST {"probe":"cdr", …}               — the detail-record probe
//  3. POST {"probe":"coverage"}             — the country-catalogue probe
//  4. POST {"probe":"numbers"}              — every number Telnyx says we own, joined to phone_lines
//  5. POST {"probe":"push_credentials"}     — every mobile push credential + the configured one read back (cert PEM)
//  6. POST {"probe":"inbound_cdr"}          — every detail record in the window, filtered client-side to INBOUND / to our numbers
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

  // ── Mode 5: the push-credential probe ─────────────────────────────────────
  // POST {"probe":"push_credentials"}. Every live credential connection reads
  // back `ios_push_credential_id = TELNYX_IOS_PUSH_CREDENTIAL_ID` (verified
  // 2026-09-07, 9 of 9) — but nothing anywhere had ever read the CREDENTIAL
  // itself. The account also holds two Telnyx demo credentials (`is_public:
  // true`, issued to com.telnyx.webrtcapp, the iOS one expired 2026-04-12), so
  // "the id matches the env var" proves nothing about whose certificate is
  // behind it, and an expired VoIP certificate is silent: Telnyx keeps
  // accepting the connection and the phone never rings. This lists every
  // credential and reads the configured one back. The `certificate` field is
  // the PUBLIC cert (PEM) — returned verbatim so `openssl x509 -noout -subject
  // -dates` can be run on it; Telnyx never returns the private key. Result is
  // stored in `app_config.telnyx_push_credentials_probe` (service-role only).
  if (body.probe === "push_credentials") {
    const budget = { left: 24 };
    const configured = Deno.env.get("TELNYX_IOS_PUSH_CREDENTIAL_ID") ?? null;
    const list = await get(key, "/mobile_push_credentials?page[size]=50", budget, true);
    const rows = Array.isArray(list.data) ? list.data as Array<Record<string, unknown>> : [];
    const slim = (c: Record<string, unknown>) => ({
      id: c.id ?? null, alias: c.alias ?? null, type: c.type ?? null,
      is_public: c.is_public ?? null, created_at: c.created_at ?? null,
      updated_at: c.updated_at ?? null,
      certificate: typeof c.certificate === "string" ? c.certificate : null,
      certificate_present: typeof c.certificate === "string" && c.certificate.length > 0,
      other_keys: Object.keys(c).filter((k) =>
        !["id", "alias", "type", "is_public", "created_at", "updated_at", "certificate", "record_type"].includes(k)),
      is_configured: configured != null && String(c.id) === configured,
    });
    const one = configured
      ? await get(key, `/mobile_push_credentials/${encodeURIComponent(configured)}`, budget, true)
      : null;
    const oneRow = one && one.data && typeof one.data === "object" && !Array.isArray(one.data)
      ? slim(one.data as Record<string, unknown>) : null;
    const result = {
      mode: "push_credentials", at: new Date().toISOString(),
      configured_id: configured,
      list: { http: list.http, rows: list.rows, body: list.body ?? null },
      credentials: rows.map(slim),
      configured: one ? { http: one.http, body: one.body ?? null, credential: oneRow } : null,
      verdict: !configured
        ? "env_missing"
        : !oneRow
          ? `configured_id_unreadable_http_${one?.http ?? 0}`
          : oneRow.is_public === true
            ? "CONFIGURED_ID_IS_A_PUBLIC_TELNYX_DEMO_CREDENTIAL"
            : String(oneRow.type ?? "").toLowerCase() !== "ios"
              ? `configured_id_type_${String(oneRow.type)}`
              : "configured_id_is_private_ios_credential",
    };
    const { error: writeErr } = await admin().from("app_config").upsert(
      { key: "telnyx_push_credentials_probe", value: result }, { onConflict: "key" });
    return Response.json({ ...result, stored: writeErr ? `error: ${writeErr.message}` : true });
  }

  // ── Mode 6: the inbound detail-record sweep ───────────────────────────────
  // POST {"probe":"inbound_cdr"} (optional "window": one of last_7_days /
  // last_30_days / yesterday / today). `line_calls` has NEVER held a row with
  // direction='inbound', and telnyx-webhook handles no call events, so our DB
  // can only prove the app never RECORDED an inbound call — not that Telnyx
  // never RECEIVED one. This pages every record type over the window and
  // filters CLIENT-SIDE on `direction == inbound` or `cld` ∈ our numbers.
  // Client-side on purpose: on this endpoint an unknown filter key returns
  // 200-with-zero-rows (measured 2026-09-07 for four id-filter keys), so a
  // server-side `filter[direction]` returning nothing would be uninterpretable.
  // It also joins every session id against `line_calls`, so "sessions Telnyx
  // holds that no row of ours names" gets a direction instead of a guess.
  // Result stored in `app_config.telnyx_inbound_probe` (service-role only).
  if (body.probe === "inbound_cdr") {
    const allowed = ["last_7_days", "last_30_days", "yesterday", "today"];
    const window = allowed.includes(String(body.window)) ? String(body.window) : "last_30_days";
    const types = ["webrtc", "sip-trunking", "call-control", "conference"];
    const SIZE = 50, MAX_PAGES = 12;
    const budget = { left: types.length * MAX_PAGES };
    const sb = admin();
    const [{ data: lines }, { data: swaps }, { data: calls }] = await Promise.all([
      sb.from("phone_lines").select("e164, status"),
      sb.from("line_number_swaps").select("old_e164, new_e164"),
      sb.from("line_calls").select("provider_call_session_id, direction, status")
        .not("provider_call_session_id", "is", null),
    ]);
    const digits = (s: unknown) => String(s ?? "").replace(/\D/g, "");
    const ours = new Set<string>();
    for (const l of lines ?? []) ours.add(digits(l.e164));
    for (const s of swaps ?? []) { ours.add(digits(s.old_e164)); ours.add(digits(s.new_e164)); }
    ours.delete("");
    const known = new Map<string, string>();
    for (const c of calls ?? []) known.set(String(c.provider_call_session_id).toLowerCase(), `${c.direction}/${c.status}`);

    const slimRec = (r: Record<string, unknown>) => ({
      record_type: r.record_type ?? null, direction: r.direction ?? null,
      cli: r.cli ?? null, cld: r.cld ?? null,
      telnyx_session_id: r.telnyx_session_id ?? null, connection_id: r.connection_id ?? null,
      started_at: r.started_at ?? r.created_at ?? null, answered_at: r.answered_at ?? null,
      ended_at: r.ended_at ?? null, call_sec: r.call_sec ?? null, billed_sec: r.billed_sec ?? null,
      hangup_cause: r.hangup_cause ?? null, hangup_source: r.hangup_source ?? null,
      status: r.status ?? null, is_webrtc: r.is_webrtc ?? null,
      cost: r.cost ?? null, currency: r.currency ?? null,
      known_to_line_calls: known.get(String(r.telnyx_session_id ?? "").toLowerCase()) ?? null,
    });

    const pagesByType: Record<string, { pages: number; rows: number; http: number[] }> = {};
    const byDirection: Record<string, number> = {};
    const sessions = new Map<string, { direction: string; to_ours: boolean; known: string | null }>();
    const inbound: Array<ReturnType<typeof slimRec>> = [];
    const toOurs: Array<ReturnType<typeof slimRec>> = [];
    let truncated = false;
    for (const t of types) {
      const stat = { pages: 0, rows: 0, http: [] as number[] };
      pagesByType[t] = stat;
      for (let page = 1; page <= MAX_PAGES; page++) {
        const params = new URLSearchParams({
          "filter[record_type]": t, "filter[date_range]": window,
          "page[size]": String(SIZE), "page[number]": String(page),
        });
        const r = await get(key, `/detail_records?${params}`, budget, true);
        stat.http.push(r.http);
        if (r.http !== 200) break;
        stat.pages++;
        const rows = Array.isArray(r.data) ? r.data as Array<Record<string, unknown>> : [];
        stat.rows += rows.length;
        for (const x of rows) {
          const dir = String(x.direction ?? "unknown").toLowerCase();
          byDirection[dir] = (byDirection[dir] ?? 0) + 1;
          const sid = String(x.telnyx_session_id ?? "").toLowerCase();
          const isOurs = ours.has(digits(x.cld));
          if (sid) {
            const prev = sessions.get(sid);
            sessions.set(sid, {
              direction: prev?.direction === "inbound" ? "inbound" : dir,
              to_ours: (prev?.to_ours ?? false) || isOurs,
              known: known.get(sid) ?? null,
            });
          }
          if (dir === "inbound" && inbound.length < 150) inbound.push(slimRec(x));
          else if (isOurs && dir !== "outbound" && toOurs.length < 50) toOurs.push(slimRec(x));
        }
        if (rows.length < SIZE) break;
        if (page === MAX_PAGES) truncated = true;
      }
    }
    let unknownSessions = 0, unknownInbound = 0;
    const unknownSample: Array<Record<string, unknown>> = [];
    for (const [sid, s] of sessions) {
      if (s.known) continue;
      unknownSessions++;
      if (s.direction === "inbound") unknownInbound++;
      if (unknownSample.length < 20) unknownSample.push({ sid, ...s });
    }
    const result = {
      mode: "inbound_cdr", at: new Date().toISOString(), window, truncated,
      our_numbers: ours.size, pages_by_type: pagesByType, by_direction: byDirection,
      sessions_total: sessions.size, sessions_known_to_line_calls: sessions.size - unknownSessions,
      sessions_unknown: unknownSessions, sessions_unknown_inbound: unknownInbound,
      unknown_sample: unknownSample,
      inbound_count: inbound.length, inbound,
      non_outbound_to_our_numbers: toOurs,
      verdict: inbound.length === 0 && byDirection.inbound == null
        ? "NO_INBOUND_RECORD_IN_WINDOW"
        : `${byDirection.inbound ?? 0}_inbound_records`,
    };
    const { error: writeErr } = await sb.from("app_config").upsert(
      { key: "telnyx_inbound_probe", value: result }, { onConflict: "key" });
    return Response.json({ ...result, stored: writeErr ? `error: ${writeErr.message}` : true });
  }

  // ── Mode 7: everything Telnyx holds for ONE line ──────────────────────────
  // POST {"probe":"line_voice","line_id":"<uuid>"}. Reads the four objects an
  // inbound call depends on and returns them nearly verbatim: the telephony
  // credential the app logs in with (does it belong to THIS connection? is it
  // expired?), the number (`connection_id`), the number's /voice settings
  // (forwarding, screening — anything that could swallow a call), and the full
  // credential connection. Added 2026-09-07 when a build that provably logged
  // in still had Telnyx clear every inbound leg in under a second. Secrets
  // Telnyx returns on the credential (`sip_password` and friends) are REDACTED
  // before the result is stored in `app_config.telnyx_line_voice_probe`.
  // ── Mode 8: the ONE write. Deliberately narrow. ───────────────────────────
  //
  // 🔴 Every other mode in this file is read-only and must stay that way. This
  // one exists to test a single reversible hypothesis: inbound dies because the
  // DID is addressed to the CONNECTION, whose own SIP user has never
  // registered, while the app registers as an on-demand telephony credential
  // that Telnyx documents as outbound-only. Rewriting the called number to the
  // credential's username is the only fix that needs no client release.
  //
  // Reverting is passing `""`. It touches ONE line's number and nothing else.
  if (body.probe === "set_translated_number") {
    const lineId = String(body.line_id ?? "");
    if (!UUID_LIKE.test(lineId)) return Response.json({ error: "line_id (uuid) required" }, { status: 400 });
    if (typeof body.value !== "string") {
      return Response.json({ error: 'value (string) required; "" reverts' }, { status: 400 });
    }
    const value = String(body.value);
    const sb = admin();
    const { data: line } = await sb.from("phone_lines")
      .select("id, e164, provider_number_id").eq("id", lineId).maybeSingle();
    if (!line?.provider_number_id) return Response.json({ error: "line_not_found" }, { status: 404 });
    const numPath = `https://api.telnyx.com/v2/phone_numbers/${encodeURIComponent(String(line.provider_number_id))}/voice`;
    const before = await fetch(numPath, { headers: { Authorization: `Bearer ${key}` } });
    const beforeJson = await before.text();
    const patch = await fetch(numPath, {
      method: "PATCH",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({ translated_number: value }),
    });
    const patchBody = (await patch.text()).slice(0, 900);
    // A 200 is not evidence on this API — read it back.
    const after = await fetch(numPath, { headers: { Authorization: `Bearer ${key}` } });
    const afterJson = await after.text();
    const readBack = (t: string): unknown => {
      try { return (JSON.parse(t) as { data?: Record<string, unknown> }).data?.translated_number ?? null; }
      catch { return null; }
    };
    const result = {
      mode: "set_translated_number", at: new Date().toISOString(),
      line: { id: line.id, e164: line.e164, number_id: line.provider_number_id },
      requested: value,
      before: readBack(beforeJson),
      patch_http: patch.status,
      patch_body: patch.ok ? null : patchBody,
      after: readBack(afterJson),
      took_effect: readBack(afterJson) === value,
    };
    await sb.from("app_config").upsert(
      { key: "telnyx_translated_number_probe", value: result }, { onConflict: "key" });
    return Response.json(result);
  }

  if (body.probe === "line_voice") {
    const lineId = String(body.line_id ?? "");
    if (!UUID_LIKE.test(lineId)) return Response.json({ error: "line_id (uuid) required" }, { status: 400 });
    const sb = admin();
    const { data: line } = await sb.from("phone_lines")
      .select("id, e164, status, provider_number_id, provider_connection_id, provider_credential_id, provider_voice_profile_id, provider_voice_attached")
      .eq("id", lineId).maybeSingle();
    if (!line) return Response.json({ error: "line_not_found" }, { status: 404 });
    const redact = (v: unknown): unknown => {
      if (Array.isArray(v)) return v.map(redact);
      if (v && typeof v === "object") {
        const out: Record<string, unknown> = {};
        for (const [k, x] of Object.entries(v as Record<string, unknown>)) {
          out[k] = /password|secret|token|api_key/i.test(k) ? (x == null ? null : "<redacted>") : redact(x);
        }
        return out;
      }
      return v;
    };
    const budget = { left: 24 };
    const read = async (path: string) => {
      const r = await get(key, path, budget, true);
      return { http: r.http, body: r.body ?? null, data: redact(r.data ?? null) };
    };
    const credential = line.provider_credential_id
      ? await read(`/telephony_credentials/${encodeURIComponent(String(line.provider_credential_id))}`) : null;
    const number = line.provider_number_id
      ? await read(`/phone_numbers/${encodeURIComponent(String(line.provider_number_id))}`) : null;
    const numberVoice = line.provider_number_id
      ? await read(`/phone_numbers/${encodeURIComponent(String(line.provider_number_id))}/voice`) : null;
    const connection = line.provider_connection_id
      ? await read(`/credential_connections/${encodeURIComponent(String(line.provider_connection_id))}`) : null;
    // Read once, unredacted, and never store it — only its shape is reported.
    let rawConnectionPassword: string | null = null;
    if (line.provider_connection_id) {
      try {
        const rr = await fetch(
          `https://api.telnyx.com/v2/credential_connections/${encodeURIComponent(String(line.provider_connection_id))}`,
          { headers: { Authorization: `Bearer ${key}` } });
        const jj = await rr.json().catch(() => ({}));
        const pw = (jj as { data?: Record<string, unknown> }).data?.password;
        rawConnectionPassword = pw == null ? null : String(pw);
      } catch { /* shape stays absent */ }
    }
    // 🔴 A telephony credential names its owner in `resource_id`
    // ("connection:<id>"), NOT in `connection_id` — which does not exist on
    // this resource. Reading the wrong field made this check a permanent
    // false negative while the credential was correctly attached.
    const credRes = (credential?.data as Record<string, unknown> | null)?.resource_id ?? null;
    const credConn = credRes == null ? null : String(credRes).replace(/^connection:/, "");
    const numConn = (number?.data as Record<string, unknown> | null)?.connection_id ?? null;

    // Inbound needs a SIP REGISTRATION, outbound needs only authentication —
    // so a connection that places calls happily can still be unreachable.
    // Telnyx does not document one stable path for reading it, so sweep the
    // candidates and keep every answer: a 404 here is data, not an error.
    const sipUser = String(
      (credential?.data as Record<string, unknown> | null)?.sip_username ?? "");
    // The CONNECTION's own SIP user is a second address of record, and the
    // docs say SDKs authenticate as it — so ask about both.
    const connUser = String(
      (connection?.data as Record<string, unknown> | null)?.user_name ?? "");
    const connId = String(line.provider_connection_id ?? "");
    const regPaths = [
      `/connections/${encodeURIComponent(connId)}/registration_status`,
      `/credential_connections/${encodeURIComponent(connId)}/registration_status`,
      `/telephony_credentials/${encodeURIComponent(String(line.provider_credential_id ?? ""))}/status`,
      // `/sip_registration_status` is real — it answered 400 naming the one
      // param it wants. `credential_type` is undocumented at any path we can
      // fetch, so sweep the plausible values and keep every answer.
      // Shape learned from the API's own 400s: the param is `username` (NOT
      // `filter[sip_username]`) and `credential_type` accepts exactly
      // uac_external_credential | telephony_credential | sip_credential_connection.
      // Ask about BOTH addresses of record: the on-demand telephony credential
      // the app logs in as, and the connection's own SIP user.
      sipUser
        ? `/sip_registration_status?username=${encodeURIComponent(sipUser)}&credential_type=telephony_credential`
        : null,
      connUser
        ? `/sip_registration_status?username=${encodeURIComponent(connUser)}&credential_type=sip_credential_connection`
        : null,
    ].filter((x): x is string => typeof x === "string" && !x.includes("//"));
    const registration: Record<string, unknown> = {};
    // ⚠️ `get()` unwraps `.data`, and this endpoint answers with a BARE object
    // — so the generic reader stored null on a 200 and the answer looked
    // empty. Keep the raw text here; a 200 is not evidence, the body is.
    for (const path of regPaths) {
      if (budget.left <= 0) { registration[path] = { http: 0, raw: "budget exhausted" }; continue; }
      budget.left--;
      try {
        const rr = await fetch(`https://api.telnyx.com/v2${path}`, {
          headers: { Authorization: `Bearer ${key}` },
        });
        registration[path] = { http: rr.status, raw: (await rr.text()).slice(0, 900) };
      } catch (e) {
        registration[path] = { http: 0, raw: `transport: ${String(e)}` };
      }
    }
    const result = {
      mode: "line_voice", at: new Date().toISOString(), line,
      checks: {
        credential_on_this_connection: credConn != null && String(credConn) === String(line.provider_connection_id),
        number_on_this_connection: numConn != null && String(numConn) === String(line.provider_connection_id),
        credential_expired: (credential?.data as Record<string, unknown> | null)?.expired ?? null,
        // ⚠️ The credential is redacted in this output, so a MASKED value from
        // Telnyx would look identical to a real one. Report its SHAPE instead:
        // `createCredentialConnection` writes "v" + 24 hex chars, so anything
        // else means the API is not handing back the password we set — which
        // would make an app that logs in with it fail authentication and never
        // register, with no server-side fault to see.
        connection_password_shape: (() => {
          const raw = rawConnectionPassword;
          if (raw == null) return "absent";
          if (/^v[0-9a-f]{24}$/.test(raw)) return "matches_generated_form";
          return `unexpected(len=${raw.length},sample=${raw.slice(0, 2)}…)`;
        })(),
        connection_user_name: (connection?.data as Record<string, unknown> | null)?.user_name ?? null,
      },
      credential, number, number_voice: numberVoice, connection, registration,
    };
    const { error: writeErr } = await sb.from("app_config").upsert(
      { key: "telnyx_line_voice_probe", value: result }, { onConflict: "key" });
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
