// SMSPool eSIM catalog sync. Iterates our countries, pulls each country's data
// plan tiers (/esim/plans?country=CC), and upserts esim_plans priced at 3x
// wholesale — a SEPARATE routine from the OTP CREDIT_DIVISOR so the two markups
// never collide. Cron-gated.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import { esimPlans } from "../_shared/smspool.ts";

const ESIM_MARGIN = 3;            // sell at 3x wholesale
const CREDIT_VALUE_USD = 0.48;    // blended pack $/credit
const PACE_MS = 250;

// Our country ids are ISO-ish lowercase; /esim/plans wants the 2-letter code.
const CC_ALIAS: Record<string, string> = { uk: "GB" };

function retailCredits(usd: number): number {
  if (!Number.isFinite(usd) || usd <= 0) return 1;
  return Math.max(1, Math.ceil((usd * ESIM_MARGIN) / CREDIT_VALUE_USD));
}
function validateCronSecret(req: Request): boolean {
  const h = req.headers.get("x-cron-secret");
  const e = Deno.env.get("CRON_SECRET");
  return !!h && !!e && h === e;
}
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;
  if (!validateCronSecret(req)) return json({ error: "unauthorized" }, { status: 401 });

  const sb = admin();
  const runStart = new Date().toISOString();

  const { data: countries } = await sb.from("countries").select("id, name");
  if (!countries) return json({ error: "countries_load_failed" }, { status: 500 });

  const { data: prev } = await sb.from("esim_plans").select("id, smoothed_cost_cents");
  const prevSmoothed = new Map<string, number>();
  for (const p of prev ?? []) if (p.smoothed_cost_cents != null) prevSmoothed.set(p.id, p.smoothed_cost_cents);

  const updates: Record<string, unknown>[] = [];
  let countriesWithPlans = 0, apiCalls = 0, sortSeed = 0;

  for (const c of countries) {
    const cc = CC_ALIAS[c.id] ?? c.id.toUpperCase();
    let rows;
    try { rows = await esimPlans(cc); apiCalls++; }
    catch { await sleep(PACE_MS); continue; }
    if (!Array.isArray(rows) || rows.length === 0) { await sleep(PACE_MS); continue; }
    countriesWithPlans++;
    for (const p of rows) {
      const usd = parseFloat(p.price);
      if (!Number.isFinite(usd) || usd <= 0) continue;
      const cents = Math.round(usd * 100);
      const id = String(p.ID);
      const prevS = prevSmoothed.get(id);
      const smoothed = prevS == null ? cents : Math.round(0.5 * cents + 0.5 * prevS);
      updates.push({
        id,
        name: c.name,
        country_code: cc,
        region: null,
        data_mb: Math.round((p.dataInGb ?? 0) * 1000),
        validity_days: p.duration ?? null,
        speed: p.speed ?? null,
        extendable: (p.extendable ?? 0) > 0,
        retail_credits: retailCredits(smoothed / 100),
        last_cost_cents: cents,
        smoothed_cost_cents: smoothed,
        status: "active",
        last_checked_at: runStart,
        sort_order: sortSeed++,
      });
    }
    await sleep(PACE_MS);
  }

  let upserted = 0;
  const CHUNK = 500;
  for (let i = 0; i < updates.length; i += CHUNK) {
    const { error } = await sb.from("esim_plans").upsert(updates.slice(i, i + CHUNK), { onConflict: "id" });
    if (error) return json({ error: "upsert_failed", detail: error.message, partial: upserted }, { status: 500 });
    upserted += Math.min(CHUNK, updates.length - i);
  }

  // Hide plans not refreshed this run (pulled from catalog).
  let hidden = 0;
  if (upserted >= 50) {
    const { count } = await sb.from("esim_plans").update({ status: "hidden" }, { count: "exact" })
      .eq("status", "active").or(`last_checked_at.is.null,last_checked_at.lt."${runStart}"`);
    hidden = count ?? 0;
  }

  return json({ apiCalls, countriesWithPlans, plansUpserted: upserted, hidden });
});
