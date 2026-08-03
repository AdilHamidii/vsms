// Seeds routes.success_rate from SMSPVA's own per-country conversion grades.
//
// GET /activation/conversions/{service} returns a coarse 0-3 quality score
// per country — SMSPVA's measurement of how often that combo actually
// converts. We map positive grades onto success_rate as a PRIOR (3→90, 2→70,
// 1→40, rate_source='seeded'); grade 0 is ignored — it is ambiguous between
// "never converts" and "no data", and we never condemn a route on it.
// Measured evidence (rate_source='measured', written hourly by
// refresh_route_observed_success from real orders) always overrules seeds:
// every write here is guarded on rate_source being null or 'seeded'.
//
// One API call per DISTINCT smspva service code, 12 codes per run at 4s
// spacing (SMSPVA rate rules; each run ~50s, under the 150s worker kill —
// see sync-smspva-operators for that discovery). A cursor in app_config
// rotates the full ~260-code catalog roughly daily. Hourly cron :49.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import { getConversions, isOk } from "../_shared/smspva.ts";

const CODES_PER_RUN = 12;
const CALL_SPACING_MS = 4000;
const CURSOR_KEY = "smspva_conversions_sync";

const GRADE_TO_RATE: Record<number, number> = { 3: 90, 2: 70, 1: 40 };

function validateCronSecret(req: Request): boolean {
  const header = req.headers.get("x-cron-secret");
  const expected = Deno.env.get("CRON_SECRET");
  if (!header || !expected) return false;
  return header === expected;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;
  if (!validateCronSecret(req)) {
    return json({ error: "unauthorized" }, { status: 401 });
  }

  const sb = admin();

  const { data: services, error: sErr } = await sb
    .from("services").select("id, smspva_code").not("smspva_code", "is", null);
  if (sErr || !services) {
    return json({ error: "services_load_failed", detail: sErr?.message }, { status: 500 });
  }
  const { data: countries, error: cErr } = await sb
    .from("countries").select("id, smspva_code").not("smspva_code", "is", null);
  if (cErr || !countries) {
    return json({ error: "countries_load_failed", detail: cErr?.message }, { status: 500 });
  }
  const ctyByCode = new Map<string, string>();
  for (const c of countries) ctyByCode.set(c.smspva_code as string, c.id);

  // One code can serve several catalog services — call the API once per code,
  // apply to all of them (same fan-out rule as sync-prices).
  const svcByCode = new Map<string, string[]>();
  for (const s of services) {
    const list = svcByCode.get(s.smspva_code as string);
    if (list) list.push(s.id);
    else svcByCode.set(s.smspva_code as string, [s.id]);
  }
  const codes = [...svcByCode.keys()].sort();

  const { data: curRow } = await sb
    .from("app_config").select("value").eq("key", CURSOR_KEY).maybeSingle();
  const cursor = (curRow?.value as { cursor?: string } | null)?.cursor ?? null;
  let start = cursor ? codes.indexOf(cursor) + 1 : 0;
  if (start >= codes.length || start < 0) start = 0;
  const batch = codes.slice(start, start + CODES_PER_RUN);

  let servicesSeeded = 0;
  let routesSeeded = 0;
  let fetchErrors = 0;

  // A seeded rate may only exist on the provider that seeded it.
  //
  // Every statement below is scoped `.eq("provider","smspva")`, which is right
  // — but it leaves a hole this function is the only one able to close: when a
  // route is RE-HOMED to another provider it leaves that scope carrying the
  // grade with it, and the clearing pass can never reach it again. Measured
  // 2026-08-03, after the HeroSMS cutover: 285 active HeroSMS routes still held
  // an SMSPVA seeded rate, 176 of them reading 70%+, while the only HeroSMS
  // routes with real MEASURED evidence all read 0%.
  //
  // Runs once per invocation, not per service code — it is a single indexed
  // UPDATE that normally matches nothing, and scoping it to this run's batch
  // would leave rows for services the cursor has not reached in weeks.
  // Deliberately NOT fatal: this is hygiene, and failing the whole seeding run
  // over it would trade live data for dead data.
  const { error: foreignErr, count: foreignCleared } = await sb
    .from("routes")
    .update({ success_rate: null, rate_source: null }, { count: "exact" })
    .eq("rate_source", "seeded")
    .neq("provider", "smspva");
  if (foreignErr) {
    console.error("sync-smspva-conversions: foreign-seed cleanup failed (ignored):", foreignErr.message);
  } else if ((foreignCleared ?? 0) > 0) {
    console.warn(`sync-smspva-conversions: cleared ${foreignCleared} seeded rates stranded on non-SMSPVA routes`);
  }

  for (const [i, code] of batch.entries()) {
    if (i > 0) await sleep(CALL_SPACING_MS);

    const resp = await getConversions(code);
    if (!isOk(resp) || typeof resp.data?.conversions !== "object") {
      // A failed fetch must not clear existing seeds — skip the code whole.
      fetchErrors++;
      console.warn(`sync-smspva-conversions: fetch failed for ${code}:`,
        (resp as { error?: { type?: string } }).error?.type ?? "bad shape");
      continue;
    }

    // country ids per mapped rate, e.g. { 90: ["es"], 70: ["uk","fr"] }
    const byRate = new Map<number, string[]>();
    for (const [cc, grade] of Object.entries(resp.data.conversions ?? {})) {
      const rate = GRADE_TO_RATE[grade as number];
      const cid = ctyByCode.get(cc);
      if (rate == null || cid == null) continue;
      const list = byRate.get(rate);
      if (list) list.push(cid);
      else byRate.set(rate, [cid]);
    }

    for (const svcId of svcByCode.get(code) ?? []) {
      // Clear-then-set, seeds only: measured rows are never touched, and a
      // grade that dropped to 0 since last pass stops asserting anything.
      const { error: clearErr } = await sb
        .from("routes")
        .update({ success_rate: null, rate_source: null })
        .eq("service_id", svcId)
        .eq("provider", "smspva")
        .eq("rate_source", "seeded");
      if (clearErr) {
        return json({ error: "clear_failed", detail: clearErr.message, code }, { status: 500 });
      }

      for (const [rate, cids] of byRate) {
        const { count, error: upErr } = await sb
          .from("routes")
          .update({ success_rate: rate, rate_source: "seeded" }, { count: "exact" })
          .eq("service_id", svcId)
          .eq("provider", "smspva")
          .in("country_id", cids)
          .or("rate_source.is.null,rate_source.eq.seeded");
        if (upErr) {
          return json({ error: "seed_failed", detail: upErr.message, code }, { status: 500 });
        }
        routesSeeded += count ?? 0;
      }
      servicesSeeded++;
    }

    const { error: curErr } = await sb
      .from("app_config")
      .upsert({ key: CURSOR_KEY, value: { cursor: code } }, { onConflict: "key" });
    if (curErr) console.error("sync-smspva-conversions: cursor write failed", curErr.message);
  }

  // Fail LOUD when every fetch in a non-empty batch failed (see
  // sync-smspva-operators for why 200-on-total-failure is dangerous).
  const body = {
    codesProcessed: batch.length - fetchErrors,
    servicesSeeded,
    routesSeeded,
    fetchErrors,
    cursor: batch.length > 0 ? batch[batch.length - 1] : null,
    wrapped: start === 0 && cursor != null,
  };
  if (batch.length > 0 && fetchErrors === batch.length) {
    return json({ error: "all_fetches_failed", ...body }, { status: 502 });
  }
  return json(body);
});
