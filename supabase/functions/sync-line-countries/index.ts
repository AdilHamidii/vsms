// Keep `line_country_catalog` describing what Telnyx will actually sell us.
//
// Daily (`relay-sync-line-countries`, 40 3 * * *) — regulatory timescales, not
// inventory ones. Five jobs per run:
//
//   1. COVERAGE      one list call, every country × number type upserted.
//   2. REQUIREMENTS  the regulatory gate, CURSOR-CHUNKED (see below).
//   3. SAMPLES       one search per sellable row, for the ops wholesale figure.
//   4. GROUPS        reconcile requirement-group status.
//   5. SELLABILITY   `refresh_line_country_sellability()` recomputes the verdict.
//
// ── Why the requirements sweep is chunked and SPACED ──────────────────────
// Edge functions die at ~150s wall clock, and the 2026-08-26 probe took FOUR
// 429s firing ~28 requirement reads back to back. Both facts point the same
// way: a bounded slice per run, ~450 ms apart. A backlog drains over a few
// days, which is the right timescale for a table whose subject is paperwork.
//
// 🔴 A FAULT MUST NEVER LOOK LIKE "NO DOCUMENTS". `requirements_empty` is
// NULLABLE and NULL means NEVER PROBED, which `refresh_line_country_sellability`
// treats as blocked. On any non-200 — 429 included — this writes `last_fault`
// and touches NOTHING else. Writing `requirements_empty = true` from a failed
// read would sell a number that arrives `requirement-info-pending` and never
// works; the repo already paid $3.83 learning that on a GB number.
//
// Cron-gated: deploy with `--no-verify-jwt`.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import { loadLineCatalogConfig } from "../_shared/lineCatalog.ts";
import {
  faultOf,
  getCountryCoverage,
  getOrderingRequirements,
  listRequirementGroups,
  searchNumbers,
} from "../_shared/telnyx.ts";

/** The only number types this catalog carries. Telnyx also reports
 *  `national`, `toll_free` and `shared_cost`; we do not sell those, and a row
 *  we never probe requirements for would sit blocked forever anyway — so it
 *  would be inventory noise in `line_country_menu`, which is public. Widen this
 *  list and the requirements sweep picks the new rows up on its own. */
const NUMBER_TYPES = ["local", "mobile"] as const;

/** Requirement reads per run. 30 × ~0.8 s ≈ 25 s, well under the ~150 s kill
 *  even with the samples and the coverage call on top. */
const REQ_PER_RUN = 30;

/** ~450 ms between requirement reads. The probe was rate-limited at zero
 *  spacing; this is the mitigation that made it stop. */
const REQ_SPACING_MS = 450;

/** Wholesale samples per run. Each is a real search, so it is the most
 *  expensive step per call; sellable countries are few and rotate. */
const SAMPLES_PER_RUN = 10;
const SAMPLE_SPACING_MS = 450;

/** Re-probe a country's paperwork when the reading is older than this —
 *  for rows we are NOT selling. */
const REQUIREMENTS_MAX_AGE_DAYS = 7;

/** 🔴 SELLABLE rows are re-probed on a much shorter leash: at HALF the gate's
 *  `line_country_catalog_max_age_hours`, so the daily run always refreshes
 *  them before `sellableCountry()` starts refusing. This is the fix for the
 *  outage found 2026-09-05: the weekly cadence above versus the 48h gate meant
 *  every sellable country went dark 48h after its probe and stayed dark until
 *  the sweep came round — measured 89/97/53 `line_catalog_stale` refusals on
 *  08-30, 09-01 and 09-02, i.e. the ENTIRE "2.7 sold nothing" window, plus
 *  three hours on 09-05 before anyone noticed. The gate and the sweep are two
 *  constants in two files; this is the one place that ties them together. */
const SELLABLE_REPROBE_FRACTION = 0.5;

/** Bootstrap/ops convenience: these are probed FIRST regardless of rotation,
 *  because they are the countries the product actually depends on today.
 *  Override per-run with `{"priority": ["US","CA", …]}` in the request body. */
const DEFAULT_PRIORITY = ["US", "CA", "PR", "VI", "GB", "FR", "DE", "NL", "PL", "AU"];

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function cronOk(req: Request): boolean {
  const secret = Deno.env.get("CRON_SECRET");
  return !!secret && req.headers.get("x-cron-secret") === secret;
}

function featureSet(block: Record<string, unknown>): Set<string> {
  const raw = block.features;
  const out = new Set<string>();
  if (!Array.isArray(raw)) return out;
  for (const f of raw) {
    // Coverage sends plain strings; `available_phone_numbers` sends objects.
    // Accept both rather than assuming, since neither shape is documented.
    const name = typeof f === "string"
      ? f
      : (f && typeof f === "object" ? (f as Record<string, unknown>).name : null);
    if (typeof name === "string" && name) out.add(name.toLowerCase());
  }
  return out;
}

interface CatalogRow {
  country_code: string;
  number_type: string;
  supports_voice: boolean;
  supports_sms: boolean;
  supports_mms: boolean;
  supports_emergency: boolean;
  supports_fax: boolean;
  reservable: boolean;
  quickship: boolean;
  coverage_raw: Record<string, unknown>;
  coverage_checked_at: string;
  country_name: string;
  last_checked_at: string;
}

Deno.serve(async (req) => {
  const pre = handleCors(req);
  if (pre) return pre;
  if (!cronOk(req)) return json({ error: "forbidden" }, { status: 403 });

  const startedAt = Date.now();
  const at = new Date().toISOString();
  const sb = admin();

  let priority = DEFAULT_PRIORITY;
  try {
    const body = await req.json().catch(() => ({}));
    if (Array.isArray(body?.priority)) {
      priority = body.priority
        .filter((c: unknown) => typeof c === "string")
        .map((c: string) => c.toUpperCase());
    }
  } catch { /* no body is the normal cron case */ }

  const faults: string[] = [];

  // ── 1. Coverage ──────────────────────────────────────────────────────────
  // ONE list call. `data` is an OBJECT keyed by full country NAME (247 entries,
  // measured 2026-08-26), each entry carrying `code` plus one block per number
  // type. An EMPTY block (`{}`) means that type does not exist there — we write
  // no row for it, because a row is a claim that something is buyable.
  let coverageFault: string | null = null;
  let coverageRows = 0;
  let coverageCountries = 0;

  const cov = await getCountryCoverage();
  if (faultOf(cov)) {
    coverageFault = `${cov.type} ${cov.status} ${cov.code ?? ""} ${cov.detail ?? ""}`.trim();
    faults.push(`coverage: ${coverageFault}`);
  } else {
    const rows: CatalogRow[] = [];
    for (const [name, rawEntry] of Object.entries(cov)) {
      if (!rawEntry || typeof rawEntry !== "object") continue;
      const entry = rawEntry as Record<string, unknown>;
      const code = typeof entry.code === "string" ? entry.code.toUpperCase() : null;
      // Without an ISO2 there is no primary key. The list carries `code` on
      // every entry measured; skip rather than inventing one from the name.
      if (!code || code.length !== 2) continue;
      coverageCountries++;

      for (const type of NUMBER_TYPES) {
        const rawBlock = entry[type];
        if (!rawBlock || typeof rawBlock !== "object") continue;
        const block = rawBlock as Record<string, unknown>;
        if (Object.keys(block).length === 0) continue; // type absent here

        // Within a PRESENT block, a feature missing from `features[]` is a
        // real false — that is the whole point of the block being present.
        const f = featureSet(block);
        rows.push({
          country_code: code,
          number_type: type,
          supports_voice: f.has("voice"),
          supports_sms: f.has("sms"),
          supports_mms: f.has("mms"),
          supports_emergency: f.has("emergency"),
          supports_fax: f.has("fax"),
          reservable: block.reservable === true,
          quickship: block.quickship === true,
          coverage_raw: block,
          coverage_checked_at: at,
          country_name: name,
          last_checked_at: at,
        });
      }
    }

    // Chunked so one oversized payload cannot fail the whole sweep. Only the
    // coverage columns are in the payload, so the regulatory and sample
    // columns of an existing row are left exactly as they were.
    for (let i = 0; i < rows.length; i += 200) {
      const chunk = rows.slice(i, i + 200);
      const { error } = await sb.from("line_country_catalog")
        .upsert(chunk, { onConflict: "country_code,number_type" });
      if (error) {
        faults.push(`coverage_upsert: ${error.message}`);
        console.error(`sync-line-countries: coverage upsert failed: ${error.message}`);
      } else {
        coverageRows += chunk.length;
      }
    }
  }

  // ── 2. Requirements, chunked ─────────────────────────────────────────────
  // Ordering is oldest-first over `requirements_checked_at` (NULLs first), so
  // the sweep is SELF-ADVANCING and cannot skip a row the way a positional
  // cursor into an unsorted list does (`sync-herosms` paid for that lesson).
  // `last_checked_at` is stamped on every row we touch — fault included — so a
  // country that keeps 429ing rotates to the back instead of monopolising
  // every run and starving the never-probed ones.
  const cutoff = new Date(Date.now() - REQUIREMENTS_MAX_AGE_DAYS * 86_400_000).toISOString();

  // Two selects rather than one, because the priority list must not depend on
  // where its rows happen to land in a 500-row rotation: on the bootstrap run
  // every row is equally stale, so "first N of the due list" is arbitrary.
  const dueQuery = (limit: number) =>
    sb.from("line_country_catalog")
      .select("country_code, number_type")
      .in("number_type", NUMBER_TYPES as unknown as string[])
      .or(`requirements_checked_at.is.null,requirements_checked_at.lt.${cutoff}`)
      .order("requirements_checked_at", { ascending: true, nullsFirst: true })
      .order("last_checked_at", { ascending: true })
      .limit(limit);

  // FIRST: every row we currently SELL whose probe is past half the gate's
  // max age. Three rows today; the whole product depends on them being fresh,
  // and the weekly rotation below has no idea the gate exists.
  const gate = await loadLineCatalogConfig(sb);
  const sellableCutoff = new Date(
    Date.now() - gate.maxAgeHours * SELLABLE_REPROBE_FRACTION * 3_600_000,
  ).toISOString();
  const { data: freshRows, error: freshErr } = await sb.from("line_country_catalog")
    .select("country_code, number_type")
    .in("number_type", NUMBER_TYPES as unknown as string[])
    .eq("sell_state", "sellable")
    .or(`requirements_checked_at.is.null,requirements_checked_at.lt.${sellableCutoff}`)
    .order("requirements_checked_at", { ascending: true, nullsFirst: true })
    .limit(REQ_PER_RUN);
  if (freshErr) faults.push(`requirements_select_sellable: ${freshErr.message}`);

  const { data: prioRows, error: prioErr } = priority.length
    ? await dueQuery(REQ_PER_RUN).in("country_code", priority)
    : { data: [], error: null };
  if (prioErr) faults.push(`requirements_select_priority: ${prioErr.message}`);

  const { data: restRows, error: dueErr } = await dueQuery(REQ_PER_RUN * 8);
  if (dueErr) faults.push(`requirements_select: ${dueErr.message}`);

  const key = (r: { country_code: string; number_type: string }) =>
    `${r.country_code}:${r.number_type}`;
  const taken = new Set<string>();
  const due: Array<{ country_code: string; number_type: string }> = [];
  for (const r of [...(freshRows ?? []), ...(prioRows ?? []), ...(restRows ?? [])]) {
    if (taken.has(key(r))) continue;
    taken.add(key(r));
    due.push(r);
  }
  const ordered = due.slice(0, REQ_PER_RUN);

  let reqOk = 0;
  let reqFaults = 0;
  let reqEmptyNow = 0;

  for (let i = 0; i < ordered.length; i++) {
    const row = ordered[i];
    if (i > 0) await sleep(REQ_SPACING_MS);

    const res = await getOrderingRequirements(row.country_code, row.number_type);

    if (faultOf(res)) {
      reqFaults++;
      // 🔴 NOTHING regulatory is written here. `requirements_empty` keeps
      // whatever it held — NULL (blocked) for a never-probed country.
      const { error } = await sb.from("line_country_catalog")
        .update({
          last_fault: `requirements ${res.type} ${res.status} ${res.code ?? ""}`.trim(),
          last_checked_at: new Date().toISOString(),
        })
        .eq("country_code", row.country_code)
        .eq("number_type", row.number_type);
      if (error) faults.push(`requirements_fault_write: ${error.message}`);
      continue;
    }

    // One row per requirement SET; the documents live in `requirement_types[]`.
    // `data.length` is NOT a document count — GB is 1 set holding 6 documents.
    const sets = res.length;
    const summary: Array<{ name: string; type: string | null }> = [];
    let documents = 0;
    for (const set of res) {
      const types = Array.isArray(set.requirement_types) ? set.requirement_types : [];
      documents += types.length;
      for (const t of types as Array<Record<string, unknown>>) {
        if (summary.length >= 40) break; // a compliance note, not an archive
        summary.push({
          name: String(t?.name ?? t?.id ?? "unknown"),
          type: t?.type == null ? null : String(t.type),
        });
      }
    }

    const { error } = await sb.from("line_country_catalog")
      .update({
        requirements_empty: sets === 0 || documents === 0,
        requirement_sets: sets,
        document_count: documents,
        requirement_summary: summary,
        requirements_checked_at: new Date().toISOString(),
        last_checked_at: new Date().toISOString(),
        last_fault: null,
      })
      .eq("country_code", row.country_code)
      .eq("number_type", row.number_type);
    if (error) {
      faults.push(`requirements_write: ${error.message}`);
    } else {
      reqOk++;
      if (sets === 0 || documents === 0) reqEmptyNow++;
    }
  }

  // Progress marker. Deliberately NOT a positional offset — the sweep orders
  // by age, so this exists for observability (how far round the rotation are
  // we) and never decides which rows are read.
  const { error: curErr } = await sb.from("app_config").upsert({
    key: "line_country_requirements_cursor",
    value: {
      at,
      probed: ordered.map((r) => `${r.country_code}:${r.number_type}`),
      due_remaining: Math.max(0, due.length - ordered.length),
      priority,
    },
  }, { onConflict: "key" });
  if (curErr) faults.push(`cursor_write: ${curErr.message}`);

  // ── 3. Wholesale samples for sellable rows ───────────────────────────────
  // Ops-only figures, and the input to the safety ceiling. Features come from
  // the CATALOG, never a literal — the hardcoded `sms+voice` pair is exactly
  // the false stockout this whole catalog exists to remove.
  const { data: sellRows, error: sellErr } = await sb
    .from("line_country_catalog")
    .select("country_code, number_type, supports_voice, supports_sms, sample_quoted_at")
    .eq("sell_state", "sellable")
    .order("sample_quoted_at", { ascending: true, nullsFirst: true })
    .limit(SAMPLES_PER_RUN);
  if (sellErr) faults.push(`samples_select: ${sellErr.message}`);

  let samplesOk = 0;
  let sampleFaults = 0;

  for (let i = 0; i < (sellRows ?? []).length; i++) {
    const row = (sellRows ?? [])[i];
    if (i > 0) await sleep(SAMPLE_SPACING_MS);

    const features: string[] = [];
    if (row.supports_voice) features.push("voice");
    if (row.supports_sms) features.push("sms");

    const res = await searchNumbers({
      country: row.country_code,
      numberType: row.number_type,
      features,
      limit: 1,
    });

    if (faultOf(res)) {
      sampleFaults++;
      const { error } = await sb.from("line_country_catalog")
        .update({
          last_fault: `sample ${res.type} ${res.status} ${res.code ?? ""}`.trim(),
          last_checked_at: new Date().toISOString(),
        })
        .eq("country_code", row.country_code)
        .eq("number_type", row.number_type);
      if (error) faults.push(`sample_fault_write: ${error.message}`);
      continue;
    }

    const first = res[0];
    const { error } = await sb.from("line_country_catalog")
      .update({
        // `stock_seen` is the honest half: an empty list is a real reading,
        // and it is NOT a fault. The cost columns stay as they were in that
        // case rather than being zeroed into a lie.
        stock_seen: res.length > 0,
        ...(first
          ? {
            sample_monthly_cents: first.monthlyCents,
            sample_upfront_cents: first.upfrontCents,
            // 🔴 `costKnown === false` means Telnyx quoted nothing and the
            // figures above are the NANP fallback constants. The ceiling and
            // the float guard must be able to tell a quote from a guess.
            sample_cost_known: first.costKnown,
            sample_currency: first.currency,
          }
          : {}),
        sample_quoted_at: new Date().toISOString(),
        last_checked_at: new Date().toISOString(),
      })
      .eq("country_code", row.country_code)
      .eq("number_type", row.number_type);
    if (error) faults.push(`sample_write: ${error.message}`);
    else samplesOk++;
  }

  // ── 4. Requirement groups ────────────────────────────────────────────────
  // An APPROVED group is the only thing that turns a documented country
  // sellable. On a fault we skip ENTIRELY: marking a group 'missing' because
  // the list call failed would silently un-sell a country.
  let groupsChecked: number | null = null;
  let groupsMissing = 0;
  const { data: groupRows, error: groupSelErr } = await sb
    .from("line_country_catalog")
    .select("country_code, number_type, requirement_group_id, requirement_group_status")
    .not("requirement_group_id", "is", null);
  if (groupSelErr) faults.push(`groups_select: ${groupSelErr.message}`);

  if ((groupRows ?? []).length > 0) {
    const live = await listRequirementGroups();
    if (faultOf(live)) {
      faults.push(`groups: ${live.type} ${live.status}`);
    } else {
      const status = new Map<string, string>();
      for (const g of live) {
        const id = g?.id == null ? null : String(g.id);
        if (id) status.set(id, String(g.status ?? "unknown"));
      }
      groupsChecked = 0;
      for (const row of groupRows ?? []) {
        const next = status.get(String(row.requirement_group_id)) ?? "missing";
        if (next === "missing") groupsMissing++;
        if (next === row.requirement_group_status) continue;
        const { error } = await sb.from("line_country_catalog")
          .update({ requirement_group_status: next })
          .eq("country_code", row.country_code)
          .eq("number_type", row.number_type);
        if (error) faults.push(`group_write: ${error.message}`);
        else groupsChecked++;
      }
    }
  }

  // ── 5. Sellability ───────────────────────────────────────────────────────
  const { data: changed, error: refreshErr } = await sb
    .rpc("refresh_line_country_sellability");
  if (refreshErr) {
    faults.push(`refresh: ${refreshErr.message}`);
    console.error(`sync-line-countries: refresh failed: ${refreshErr.message}`);
  }

  // ── 6. Heartbeat ─────────────────────────────────────────────────────────
  // `checked_at` is what the watchdog reads. Written LAST, so a run that died
  // half way does not claim freshness it did not earn.
  const { count: total } = await sb.from("line_country_catalog")
    .select("country_code", { count: "exact", head: true });
  const { count: sellable } = await sb.from("line_country_catalog")
    .select("country_code", { count: "exact", head: true })
    .eq("sell_state", "sellable");

  const { error: hbErr } = await sb.from("app_config").upsert({
    key: "line_country_sync",
    value: {
      checked_at: new Date().toISOString(),
      countries: total ?? 0,
      sellable: sellable ?? 0,
      requirement_faults: reqFaults,
      coverage_fault: coverageFault != null,
    },
  }, { onConflict: "key" });
  if (hbErr) console.error(`sync-line-countries: heartbeat failed: ${hbErr.message}`);

  return json({
    ok: true,
    elapsed_ms: Date.now() - startedAt,
    coverage: {
      fault: coverageFault,
      countries_seen: coverageCountries,
      rows_upserted: coverageRows,
    },
    requirements: {
      probed: ordered.length,
      ok: reqOk,
      faults: reqFaults,
      empty_now: reqEmptyNow,
      due_remaining: Math.max(0, due.length - ordered.length),
      priority,
    },
    samples: { attempted: (sellRows ?? []).length, ok: samplesOk, faults: sampleFaults },
    groups: { updated: groupsChecked, missing: groupsMissing },
    sellability_rows_changed: changed ?? null,
    catalog: { rows: total ?? 0, sellable: sellable ?? 0 },
    faults: faults.slice(0, 20),
  });
});
