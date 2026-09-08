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

  // ── Modes 14/15: DISPOSABLE TEST NUMBERS ─────────────────────────────────
  //
  // 🔴 WRITING MODES. ~$1 upfront + $1/month each.
  //
  // Why they exist: every number on the account belongs to a paying subscriber
  // except one. Testing outbound SMS by texting a customer's rented number
  // puts a probe message in that customer's inbox, which is not ours to do.
  // A disposable number costs a dollar and removes the dilemma entirely.
  //
  // ⚠️ These numbers are ORPHANS by construction — no `phone_lines` row holds
  // them — so `release-lines`' orphan sweep will delete them on its own once
  // they are 24h old (ORPHAN_MIN_AGE_MS). `release_number` is the tidy path;
  // the sweep is the backstop if a probe run dies half way.
  if (body.probe === "order_test_number") {
    const country = String(body.country ?? "US").toUpperCase();
    if (!/^[A-Z]{2}$/.test(country)) {
      return Response.json({ error: "country must be ISO2" }, { status: 400 });
    }
    const sb = admin();
    const search = await fetch(
      `${TELNYX}/available_phone_numbers?filter[country_code]=${country}` +
      `&filter[phone_number_type]=local&filter[features][]=sms&filter[limit]=1`,
      { headers: { Authorization: `Bearer ${key}` } });
    const sj = await search.json().catch(() => ({})) as
      { data?: { phone_number?: string }[] };
    const candidate = sj.data?.[0]?.phone_number ?? null;
    if (!candidate) {
      return Response.json({ error: "no_inventory", country }, { status: 409 });
    }

    const order = await fetch(`${TELNYX}/number_orders`, {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        phone_numbers: [{ phone_number: candidate }],
        customer_reference: "vsms-smsprobe",
      }),
    });
    const orderText = await order.text();
    let oj: Record<string, unknown> | null = null;
    try { oj = JSON.parse(orderText) as Record<string, unknown>; } catch { /* raw */ }

    // Number orders are ASYNCHRONOUS (pending → success). Poll, then attach the
    // messaging profile — without it the number cannot send at all, and that
    // omission would read exactly like a registration refusal.
    const orderId = ((oj?.data as { id?: string } | undefined)?.id) ?? null;
    let numberId: string | null = null;
    let orderStatus: string | null = null;
    for (let i = 0; i < 8 && orderId; i++) {
      await sleep(2000);
      const r = await fetch(`${TELNYX}/number_orders/${orderId}`,
                            { headers: { Authorization: `Bearer ${key}` } });
      const j = await r.json().catch(() => ({})) as
        { data?: { status?: string; phone_numbers?: { id?: string }[] } };
      orderStatus = j.data?.status ?? null;
      if (orderStatus === "success") {
        const list = await fetch(
          `${TELNYX}/phone_numbers?filter[phone_number]=${encodeURIComponent(candidate)}`,
          { headers: { Authorization: `Bearer ${key}` } });
        const lj = await list.json().catch(() => ({})) as { data?: { id?: string }[] };
        numberId = lj.data?.[0]?.id ?? null;
        break;
      }
    }

    let messagingAttached: unknown = null;
    if (numberId && body.messaging_profile_id) {
      const m = await fetch(`${TELNYX}/phone_numbers/${numberId}/messaging`, {
        method: "PATCH",
        headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
        body: JSON.stringify({ messaging_profile_id: String(body.messaging_profile_id) }),
      });
      // Read back. `messaging_profile_id` is one of the fields this API has
      // silently accepted and discarded before.
      const back = await fetch(`${TELNYX}/phone_numbers/${numberId}/messaging`,
                               { headers: { Authorization: `Bearer ${key}` } });
      const bj = await back.json().catch(() => ({})) as
        { data?: { messaging_profile_id?: string } };
      messagingAttached = { http: m.status, read_back: bj.data?.messaging_profile_id ?? null };
    }

    const result = {
      mode: "order_test_number", at: new Date().toISOString(), country,
      phone_number: candidate, order_id: orderId, order_status: orderStatus,
      number_id: numberId, messaging: messagingAttached,
      http: order.status, body: order.ok ? undefined : trunc(orderText, 700),
    };
    await sb.from("app_config").upsert(
      { key: "telnyx_test_number_probe", value: result }, { onConflict: "key" });
    return Response.json(result);
  }

  // Attach a messaging profile to a number we already own. Split out from
  // `order_test_number` because a number order is ASYNCHRONOUS and can outlast
  // that mode's poll — leaving a paid-for number that cannot send, which reads
  // exactly like a registration refusal if you do not know to look.
  if (body.probe === "attach_messaging") {
    const e164 = String(body.e164 ?? "");
    const profile = String(body.messaging_profile_id ?? "");
    if (!/^\+[1-9]\d{6,15}$/.test(e164) || !profile) {
      return Response.json({ error: "e164 and messaging_profile_id required" }, { status: 400 });
    }
    const list = await fetch(
      `${TELNYX}/phone_numbers?filter[phone_number]=${encodeURIComponent(e164)}`,
      { headers: { Authorization: `Bearer ${key}` } });
    const lj = await list.json().catch(() => ({})) as { data?: { id?: string }[] };
    const id = lj.data?.[0]?.id ?? null;
    if (!id) return Response.json({ error: "not_on_account", e164 }, { status: 404 });

    const m = await fetch(`${TELNYX}/phone_numbers/${id}/messaging`, {
      method: "PATCH",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({ messaging_profile_id: profile }),
    });
    const back = await fetch(`${TELNYX}/phone_numbers/${id}/messaging`,
                             { headers: { Authorization: `Bearer ${key}` } });
    const bj = await back.json().catch(() => ({})) as
      { data?: Record<string, unknown> };
    return Response.json({
      mode: "attach_messaging", e164, number_id: id, http: m.status,
      read_back: bj.data?.messaging_profile_id ?? null,
      features: bj.data?.features ?? null,
      eligible: bj.data?.eligible_messaging_products ?? null,
    });
  }

  // Read / edit the MESSAGING PROFILE.
  //
  // 🔴 `whitelisted_destinations` is OUR OWN setting and it silently caps
  // where every number can text. It read `["CA","GB","US"]` on 2026-09-08 —
  // and GB being in it is the proof the field is not NANP-limited, i.e. the
  // "you cannot text other countries" limit was partly self-inflicted rather
  // than a carrier rule. A destination absent from this list is refused by
  // Telnyx before the carrier ever sees it.
  //
  // `daily_spend_limit` is the other one to watch: it is an ACCOUNT-WIDE cap
  // across all messaging, so one user in a loop can stop every subscriber's
  // texts for the rest of the day.
  //
  // Read-only unless `destinations` or `daily_spend_limit` is supplied, and it
  // reads back — a 200 on this API has meant nothing five times now.
  if (body.probe === "messaging_profile") {
    const id = String(body.profile_id ?? "");
    if (!id) return Response.json({ error: "profile_id required" }, { status: 400 });
    const path = `${TELNYX}/messaging_profiles/${encodeURIComponent(id)}`;

    const patch: Record<string, unknown> = {};
    if (Array.isArray(body.destinations)) {
      const list = (body.destinations as unknown[]).map((c) => String(c).toUpperCase());
      if (!list.every((c) => /^[A-Z]{2}$/.test(c))) {
        return Response.json({ error: "destinations must be ISO2" }, { status: 400 });
      }
      patch.whitelisted_destinations = list;
    }
    if (body.daily_spend_limit != null) {
      patch.daily_spend_limit = String(body.daily_spend_limit);
      patch.daily_spend_limit_enabled = true;
    }

    let patchHttp: number | null = null;
    let patchBody: string | undefined;
    if (Object.keys(patch).length > 0) {
      const r = await fetch(path, {
        method: "PATCH",
        headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
        body: JSON.stringify(patch),
      });
      patchHttp = r.status;
      if (!r.ok) patchBody = trunc(await r.text(), 600);
    }

    const back = await fetch(path, { headers: { Authorization: `Bearer ${key}` } });
    const bj = await back.json().catch(() => ({})) as { data?: Record<string, unknown> };
    const result = {
      mode: "messaging_profile", at: new Date().toISOString(), profile_id: id,
      patched: Object.keys(patch).length > 0 ? patch : null,
      patch_http: patchHttp, patch_body: patchBody,
      whitelisted_destinations: bj.data?.whitelisted_destinations ?? null,
      daily_spend_limit: bj.data?.daily_spend_limit ?? null,
      daily_spend_limit_enabled: bj.data?.daily_spend_limit_enabled ?? null,
      name: bj.data?.name ?? null,
    };
    await admin().from("app_config").upsert(
      { key: "telnyx_messaging_profile_probe", value: result }, { onConflict: "key" });
    return Response.json(result);
  }

  if (body.probe === "release_number") {
    const e164 = String(body.e164 ?? "");
    if (!/^\+[1-9]\d{6,15}$/.test(e164)) {
      return Response.json({ error: "e164 required" }, { status: 400 });
    }
    const sb = admin();
    // 🔴 Refuse to release a number a live line holds. This mode exists to
    // clean up probe numbers; pointed at a subscriber's number it would delete
    // the product they are paying for.
    const { data: held } = await sb.from("phone_lines")
      .select("id, status").eq("e164", e164).neq("status", "released").maybeSingle();
    if (held) {
      return Response.json(
        { error: "number_held_by_live_line", line: held.id, status: held.status },
        { status: 409 });
    }
    const list = await fetch(
      `${TELNYX}/phone_numbers?filter[phone_number]=${encodeURIComponent(e164)}`,
      { headers: { Authorization: `Bearer ${key}` } });
    const lj = await list.json().catch(() => ({})) as { data?: { id?: string }[] };
    const id = lj.data?.[0]?.id ?? null;
    if (!id) return Response.json({ error: "not_on_account", e164 }, { status: 404 });
    const del = await fetch(`${TELNYX}/phone_numbers/${id}`,
      { method: "DELETE", headers: { Authorization: `Bearer ${key}` } });
    return Response.json({ mode: "release_number", e164, number_id: id, http: del.status });
  }

  // ── Mode 12: the MESSAGING / REGISTRATION audit ───────────────────────────
  //
  // Outbound SMS has been written off since 2026-08-17 on the strength of FOUR
  // messages, all sent from ONE Canadian longcode on one evening. The fleet is
  // now majority US, and no US number has ever attempted a send — so the
  // premise "outbound does not work" has never been tested against the numbers
  // we actually sell. This reads the account's real registration state instead
  // of re-deriving it from that note.
  //
  // Read-only. Every path here is a GET.
  if (body.probe === "messaging") {
    const budget = { left: 40 };
    const sb = admin();
    const { data: lines } = await sb.from("phone_lines")
      .select("e164, country_code, status, provider_number_id, provider_msg_profile_id")
      .neq("status", "released").order("created_at");

    // Account-level registration. `10dlc/brand` reporting totalRecords: 0 is
    // what makes every US A2P send a guaranteed carrier rejection.
    const account: Record<string, unknown> = {
      brands: await get(key, "/10dlc/brand", budget, true),
      campaigns: await get(key, "/10dlc/campaign", budget, true),
      messaging_profiles: await get(key, "/messaging_profiles", budget, true),
      tollfree_verifications: await get(
        key, "/messaging_tollfree/verification/requests?page[size]=10", budget, true),
    };

    // Per number: the fields that decide whether a send is even attempted.
    // `messaging_product` (A2P vs P2P) and the three `features.sms` booleans
    // are the ones that have silently no-op'd on PATCH before — read, never
    // assume. A number carrying no campaign id cannot send US A2P at all.
    const numbers: Record<string, unknown>[] = [];
    for (const l of (lines ?? []).slice(0, 14)) {
      if (!l.provider_number_id) continue;
      const r = await get(key, `/phone_numbers/${l.provider_number_id}/messaging`, budget, true);
      const d = (r.data ?? null) as Record<string, unknown> | null;
      numbers.push({
        e164: l.e164, country: l.country_code, line_status: l.status,
        http: r.http,
        messaging_profile_id: d?.messaging_profile_id ?? null,
        messaging_product: d?.messaging_product ?? null,
        eligible_messaging_products: d?.eligible_messaging_products ?? null,
        messaging_campaign_id: d?.messaging_campaign_id ?? null,
        traffic_type: d?.traffic_type ?? null,
        features: d?.features ?? null,
        body: r.http >= 400 ? r.body : undefined,
      });
    }

    const result = { mode: "messaging", at: new Date().toISOString(), account, numbers };
    await sb.from("app_config").upsert(
      { key: "telnyx_messaging_probe", value: result }, { onConflict: "key" });
    return Response.json(result);
  }

  // ── Mode 13: SEND ONE REAL MESSAGE between two numbers WE OWN ─────────────
  //
  // 🔴 WRITING MODE, AND IT COSTS ~$0.004. It is also the only thing that can
  // settle this: every capability flag on the number resource has, at least
  // once in this adapter, reported something the carrier then contradicted.
  //
  // Both endpoints must be numbers on our own account. That is a safety
  // property, not a convenience: a probe that can text an arbitrary handset is
  // a probe that can be used to spam, and the cron secret alone should not be
  // able to reach a stranger's phone. It also makes the result readable — we
  // own the receiving end, so an inbound webhook proves DELIVERY rather than
  // mere acceptance, which is the exact distinction the one "sent" message of
  // 2026-08-17 never resolved (it never got a delivery receipt).
  //
  // Telnyx accepts a message and rejects it asynchronously, so a 200 here means
  // nothing at all. The mode therefore polls the message back for its final
  // status and errors — the read-back rule this adapter has now paid for five
  // times.
  if (body.probe === "send_test") {
    const from = String(body.from ?? "");
    const to = String(body.to ?? "");
    const text = String(body.text ?? "vSMS delivery probe — please ignore.");
    if (!/^\+[1-9]\d{6,15}$/.test(from) || !/^\+[1-9]\d{6,15}$/.test(to)) {
      return Response.json({ error: "from and to must be E.164" }, { status: 400 });
    }
    const sb = admin();
    // Ownership is checked against TELNYX's own inventory, not `phone_lines`.
    // That is both stricter and broader: stricter because it is the account
    // that actually bills, broader because a disposable test number has no
    // line row and must still be usable here. The invariant that matters —
    // this probe can never reach a handset we do not own — holds either way.
    const ownedAt = async (e164: string) => {
      const r = await fetch(
        `${TELNYX}/phone_numbers?filter[phone_number]=${encodeURIComponent(e164)}`,
        { headers: { Authorization: `Bearer ${key}` } });
      if (!r.ok) return false;
      const j = await r.json().catch(() => ({})) as { data?: unknown[] };
      return Array.isArray(j.data) && j.data.length > 0;
    };
    // The SENDER must always be ours — that is not negotiable, it is whose
    // number appears on the recipient's handset.
    //
    // The RECIPIENT may be an outside number ONLY with `allow_unowned: true`
    // AND `confirm_to` repeating it exactly. The default is closed because a
    // probe reachable with the cron secret alone must not be able to text a
    // stranger; the escape hatch exists because the only test that settles
    // international sending is one to a real handset off our account, and a
    // typo'd destination would text an uninvolved person. Both fields are
    // recorded in `app_config.telnyx_send_test_probe`, so a send to an outside
    // number is never anonymous.
    if (!(await ownedAt(from))) {
      return Response.json({ error: "sender_must_be_ours" }, { status: 409 });
    }
    const unowned = body.allow_unowned === true;
    if (!(await ownedAt(to))) {
      if (!unowned || String(body.confirm_to ?? "") !== to) {
        return Response.json(
          { error: "recipient_not_ours", need: "allow_unowned + confirm_to" },
          { status: 409 });
      }
    }

    const send = await fetch(`${TELNYX}/messages`, {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from, to, text }),
    });
    const sendText = await send.text();
    let sendJson: Record<string, unknown> | null = null;
    try { sendJson = JSON.parse(sendText) as Record<string, unknown>; } catch { /* raw */ }
    const msgId = ((sendJson?.data as { id?: string } | undefined)?.id) ?? null;

    // Poll for the terminal state. A rejection lands within a few seconds and
    // arrives as `to[0].status = "delivery_failed"` plus an `errors[]` array —
    // NOT as a non-2xx on the POST above.
    const polls: unknown[] = [];
    let final: Record<string, unknown> | null = null;
    if (msgId) {
      for (let i = 0; i < 6; i++) {
        await sleep(2500);
        const r = await fetch(`${TELNYX}/messages/${msgId}`,
                              { headers: { Authorization: `Bearer ${key}` } });
        const j = await r.json().catch(() => ({})) as { data?: Record<string, unknown> };
        const d = j.data ?? null;
        const st = ((d?.to as { status?: string }[] | undefined)?.[0]?.status) ?? null;
        polls.push({ at: i, status: st, errors: d?.errors ?? null });
        final = d;
        if (st && st !== "queued" && st !== "sending") break;
      }
    }

    const result = {
      mode: "send_test", at: new Date().toISOString(), from, to,
      http: send.status,
      message_id: msgId,
      accepted: send.ok,
      post_body: send.ok ? undefined : trunc(sendText, 700),
      final_status: ((final?.to as { status?: string }[] | undefined)?.[0]?.status) ?? null,
      errors: final?.errors ?? null,
      parts: final?.parts ?? null,
      cost: final?.cost ?? null,
      carrier: ((final?.to as { carrier?: string }[] | undefined)?.[0]?.carrier) ?? null,
      line_type: ((final?.to as { line_type?: string }[] | undefined)?.[0]?.line_type) ?? null,
      polls,
    };
    await sb.from("app_config").upsert(
      { key: "telnyx_send_test_probe", value: result }, { onConflict: "key" });
    return Response.json(result);
  }

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

  // ── Mode 9: does a Call Control leg reach the WebRTC client? ──────────────
  //
  // 🔴 THIS IS THE TEST THAT DECIDES THE WHOLE INBOUND ARCHITECTURE, and it
  // needs no client release. Telnyx forbids routing a DID straight at an
  // on-demand telephony credential, but explicitly SUPPORTS dialing that same
  // credential from Call Control:
  //
  //   "inbound calls directly to on-demand generated credential is not
  //    currently supported ... purely for outbound calls"
  //   "...your call center service would use our call control API to dial each
  //    of the generated credentials to connect the caller with one of the
  //    available agents"
  //   (support.telnyx.com/en/articles/7029684-telephony-credentials-types)
  //
  // The credential the app already registers with -- proven `registered: true`
  // -- is therefore reachable; only the addressing was wrong. If this rings the
  // device, inbound ships as a webhook that transfers the PSTN leg to
  // `sip:<sip_username>@sip.telnyx.com`, and the FAILED connection-credential
  // login stops mattering at all.
  //
  // It WRITES (creates a Call Control app once, sets one connection field, and
  // places one ~$0.01 call). Everything it creates is reused, and
  // `sip_uri_calling_preference` is set to "internal" -- NOT "unrestricted",
  // which would let anyone who guesses a username ring a paying subscriber.
  // ── Mode 10: point a number's INBOUND at the Call Control app ─────────────
  //
  // 🔴 THE TWO DIRECTIONS ARE OWNED BY DIFFERENT OBJECTS, and that is what
  // makes this safe. Moving `connection_id` on the NUMBER changes only where
  // INBOUND calls are delivered. Outbound still originates on the credential
  // connection the SDK logs into, which keeps its own outbound voice profile —
  // so the 131-call outbound path is untouched.
  //
  // Caller ID is the one thing that is NOT automatic: on a credential
  // connection Telnyx will often send the SIP username instead of the number,
  // so `ani_override` is set to the line's own e164 at the same time. Both are
  // read back; a 200 on this API has silently set nothing three times now.
  //
  // `value: "restore"` puts the number back on its credential connection.
  if (body.probe === "route_inbound") {
    const lineId = String(body.line_id ?? "");
    if (!UUID_LIKE.test(lineId)) return Response.json({ error: "line_id (uuid) required" }, { status: 400 });
    const sb = admin();
    const { data: line } = await sb.from("phone_lines")
      .select("id, e164, provider_number_id, provider_connection_id")
      .eq("id", lineId).maybeSingle();
    if (!line?.provider_number_id || !line.provider_connection_id) {
      return Response.json({ error: "line_not_provisioned" }, { status: 409 });
    }
    const { data: cfg } = await sb.from("app_config")
      .select("value").eq("key", "telnyx_call_control_app").maybeSingle();
    const appId = (cfg?.value as Record<string, unknown> | null)?.id as string | undefined;
    if (!appId) return Response.json({ error: "no_call_control_app" }, { status: 409 });

    const restore = String(body.value ?? "") === "restore";
    const target = restore ? String(line.provider_connection_id) : appId;

    const api = async (method: string, path: string, payload?: unknown) => {
      const r = await fetch(`https://api.telnyx.com/v2${path}`, {
        method,
        headers: {
          Authorization: `Bearer ${key}`,
          ...(payload ? { "Content-Type": "application/json" } : {}),
        },
        ...(payload ? { body: JSON.stringify(payload) } : {}),
      });
      const text = await r.text();
      let data: unknown = null;
      try { data = JSON.parse(text); } catch { /* keep raw */ }
      return { http: r.status, data, raw: text.slice(0, 500) };
    };

    const numPath = `/phone_numbers/${encodeURIComponent(String(line.provider_number_id))}`;
    const before = await api("GET", `${numPath}/voice`);
    const patched = await api("PATCH", numPath, { connection_id: target });
    const after = await api("GET", `${numPath}/voice`);
    const connOf = (x: { data?: unknown }) =>
      ((x.data as { data?: { connection_id?: string } } | null)?.data?.connection_id) ?? null;

    // Caller ID, set on the CREDENTIAL connection (outbound's owner), not on
    // the number. SIP-URI calling is set in the same PATCH: without it the
    // transfer leg cannot enter the connection at all, so a number pointed at
    // Call Control would ring nothing. "internal" restricts it to our own
    // account — "unrestricted" would let anyone who guesses a username ring a
    // paying subscriber.
    const connPath = `/credential_connections/${encodeURIComponent(String(line.provider_connection_id))}`;
    const aniPatch = await api("PATCH", connPath, {
      sip_uri_calling_preference: "internal",
      outbound: { ani_override: line.e164, ani_override_type: "always" },
    });
    const connBack = await api("GET", connPath);
    const ani = ((connBack.data as { data?: { outbound?: Record<string, unknown> } } | null)
      ?.data?.outbound?.ani_override) ?? null;

    const result = {
      mode: "route_inbound", at: new Date().toISOString(),
      line: { id: line.id, e164: line.e164 },
      intent: restore ? "restore_to_credential_connection" : "point_at_call_control",
      target_connection: target,
      number_connection_before: connOf(before),
      patch_http: patched.http,
      patch_error: patched.http >= 300 ? patched.raw : null,
      number_connection_after: connOf(after),
      took_effect: connOf(after) === target,
      ani_override: { patch_http: aniPatch.http, read_back: ani, took_effect: ani === line.e164 },
      sip_uri_calling_preference: ((connBack.data as { data?: Record<string, unknown> } | null)
        ?.data?.sip_uri_calling_preference) ?? null,
    };
    await sb.from("app_config").upsert(
      { key: "telnyx_route_inbound_probe", value: result }, { onConflict: "key" });
    return Response.json(result);
  }

  // ── Mode 11: a REAL PSTN call to one of our own numbers ───────────────────
  //
  // The end-to-end test the others cannot give. `call_control_ring` dials the
  // client's SIP URI directly, which skips the number, the Call Control
  // application and the webhook — i.e. three of the four things that have
  // broken. This places an ordinary call TO a rented number FROM another
  // number on the account, so it exercises the whole inbound path exactly as
  // a customer's caller would.
  //
  // It also removes a confound that invalidated several manual tests: dialing
  // from the same handset that is supposed to ring. iOS will not present an
  // incoming VoIP call normally while that phone is in a cellular call.
  //
  // `from` must be a number we own — Telnyx silently drops a leg whose ANI it
  // does not recognise (measured 2026-09-08).
  if (body.probe === "ring_number") {
    const to = String(body.to ?? "");
    const from = String(body.from ?? "");
    if (!/^\+[1-9]\d{6,15}$/.test(to) || !/^\+[1-9]\d{6,15}$/.test(from)) {
      return Response.json({ error: "to and from must be E.164" }, { status: 400 });
    }
    const sb = admin();
    const { data: cfg } = await sb.from("app_config")
      .select("value").eq("key", "telnyx_call_control_app").maybeSingle();
    const appId = (cfg?.value as Record<string, unknown> | null)?.id as string | undefined;
    if (!appId) return Response.json({ error: "no_call_control_app" }, { status: 409 });

    // ⚠️ A Call Control application needs an OUTBOUND VOICE PROFILE before it
    // can place a PSTN call: without one Telnyx answers 403 / D38
    // "Connection has no Outbound Profile assigned". This does NOT affect real
    // inbound — the transfer leg goes to a SIP URI, which needs no profile —
    // it only blocks this synthetic test. Borrow the profile the target line
    // already owns rather than creating another billable object.
    const appPath = `/call_control_applications/${encodeURIComponent(appId)}`;
    const appNow = await fetch(`https://api.telnyx.com/v2${appPath}`,
                               { headers: { Authorization: `Bearer ${key}` } });
    const appJson = await appNow.json().catch(() => ({}));
    let profileId = ((appJson as { data?: { outbound?: Record<string, unknown> } })
      ?.data?.outbound?.outbound_voice_profile_id) ?? null;
    if (!profileId) {
      const { data: srcLine } = await sb.from("phone_lines")
        .select("provider_voice_profile_id").eq("e164", to).maybeSingle();
      const borrowed = srcLine?.provider_voice_profile_id ?? null;
      if (borrowed) {
        await fetch(`https://api.telnyx.com/v2${appPath}`, {
          method: "PATCH",
          headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
          body: JSON.stringify({ outbound: { outbound_voice_profile_id: borrowed } }),
        });
        // Read back — a 200 here has meant nothing four times already.
        const again = await fetch(`https://api.telnyx.com/v2${appPath}`,
                                  { headers: { Authorization: `Bearer ${key}` } });
        const againJson = await again.json().catch(() => ({}));
        profileId = ((againJson as { data?: { outbound?: Record<string, unknown> } })
          ?.data?.outbound?.outbound_voice_profile_id) ?? null;
      }
    }

    const r = await fetch("https://api.telnyx.com/v2/calls", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({ connection_id: appId, to, from, timeout_secs: 45 }),
    });
    const text = await r.text();
    let data: unknown = null;
    try { data = JSON.parse(text); } catch { /* keep raw */ }
    const result = {
      mode: "ring_number", at: new Date().toISOString(), to, from,
      outbound_voice_profile_id: profileId,
      http: r.status,
      call_session_id: ((data as { data?: { call_session_id?: string } } | null)
        ?.data?.call_session_id) ?? null,
      error: r.ok ? null : text.slice(0, 500),
    };
    await sb.from("app_config").upsert(
      { key: "telnyx_ring_number_probe", value: result }, { onConflict: "key" });
    return Response.json(result);
  }

  if (body.probe === "call_control_ring") {
    const lineId = String(body.line_id ?? "");
    if (!UUID_LIKE.test(lineId)) return Response.json({ error: "line_id (uuid) required" }, { status: 400 });
    const sb = admin();
    const { data: line } = await sb.from("phone_lines")
      .select("id, e164, provider_connection_id, provider_credential_id")
      .eq("id", lineId).maybeSingle();
    if (!line?.provider_connection_id || !line.provider_credential_id) {
      return Response.json({ error: "line_not_provisioned" }, { status: 409 });
    }

    const api = async (method: string, path: string, payload?: unknown) => {
      const r = await fetch(`https://api.telnyx.com/v2${path}`, {
        method,
        headers: {
          Authorization: `Bearer ${key}`,
          ...(payload ? { "Content-Type": "application/json" } : {}),
        },
        ...(payload ? { body: JSON.stringify(payload) } : {}),
      });
      const text = await r.text();
      let data: unknown = null;
      try { data = JSON.parse(text); } catch { /* keep raw */ }
      return { http: r.status, data, raw: text.slice(0, 700) };
    };

    // 1. One Call Control application for the whole account, remembered.
    const { data: cfg } = await sb.from("app_config")
      .select("value").eq("key", "telnyx_call_control_app").maybeSingle();
    let appId = (cfg?.value as Record<string, unknown> | null)?.id as string | undefined;
    let created: unknown = null;
    if (!appId) {
      const mk = await api("POST", "/call_control_applications", {
        application_name: `vsms-inbound-${Date.now()}`,
        // Points at the function that already verifies Telnyx's Ed25519
        // signature. Nothing handles these events yet -- this probe only needs
        // the app to EXIST so a call can originate from it.
        webhook_event_url:
          "https://enugzltysdmjzavisloy.supabase.co/functions/v1/telnyx-webhook",
        webhook_api_version: "2",
        anchorsite_override: "Latency",
      });
      created = mk;
      appId = ((mk.data as { data?: { id?: string } } | null)?.data?.id) ?? undefined;
      if (appId) {
        await sb.from("app_config").upsert(
          { key: "telnyx_call_control_app", value: { id: appId, at: new Date().toISOString() } },
          { onConflict: "key" });
      }
    }
    if (!appId) {
      return Response.json({ error: "no_call_control_app", created }, { status: 502 });
    }

    // 2. Allow SIP-URI calls INTO this connection. Read it back -- a 200 on
    //    this API is not evidence (the attachOutboundProfile class).
    const connPath = `/credential_connections/${encodeURIComponent(String(line.provider_connection_id))}`;
    const pref = String(body.sip_uri_calling_preference ?? "internal");
    // ⚠️ TOP LEVEL, not nested under `inbound`. The connection read-back shows
    // it beside `ios_push_credential_id`, and PATCHing it under `inbound`
    // returned 200 and set NOTHING — the third time this API has silently
    // no-op'd a misplaced field here (after `messaging_profile_id` and
    // `outbound_voice_profile_id`). Both placements are sent and the value is
    // read back, because only the read-back is evidence.
    const patched = await api("PATCH", connPath, { sip_uri_calling_preference: pref });
    const readBack = await api("GET", connPath);
    const connData = (readBack.data as { data?: Record<string, unknown> } | null)?.data ?? {};
    const prefNow = (connData.sip_uri_calling_preference
      ?? (connData.inbound as Record<string, unknown> | undefined)?.sip_uri_calling_preference) ?? null;

    // 3. The credential the app actually registers with.
    const cred = await api("GET",
      `/telephony_credentials/${encodeURIComponent(String(line.provider_credential_id))}`);
    const sipUser = ((cred.data as { data?: { sip_username?: string } } | null)?.data?.sip_username) ?? null;
    if (!sipUser) return Response.json({ error: "no_sip_username", cred }, { status: 502 });

    // 4. Ring it.
    const to = `sip:${sipUser}@sip.telnyx.com`;
    const placed = await api("POST", "/calls", {
      connection_id: appId,
      to,
      from: line.e164,
      timeout_secs: 30,
    });

    const result = {
      mode: "call_control_ring", at: new Date().toISOString(),
      line: { id: line.id, e164: line.e164 },
      call_control_app: appId,
      created_app: created ? { http: (created as { http: number }).http } : null,
      sip_uri_calling_preference: { requested: pref, patch_http: patched.http, read_back: prefNow,
                                    took_effect: prefNow === pref },
      dialed: to,
      call_http: placed.http,
      call_control_id: ((placed.data as { data?: { call_control_id?: string } } | null)
        ?.data?.call_control_id) ?? null,
      call_session_id: ((placed.data as { data?: { call_session_id?: string } } | null)
        ?.data?.call_session_id) ?? null,
      call_error: placed.http >= 300 ? placed.raw : null,
    };
    await sb.from("app_config").upsert(
      { key: "telnyx_call_control_probe", value: result }, { onConflict: "key" });
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
