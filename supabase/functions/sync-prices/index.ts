// Pulls live SMSPVA prices for every country in our catalog and bulk-updates
// routes.retail_credits via the pricing formula below. Auth gates this on
// the cron secret, so it can either be invoked manually (one-shot from
// terminal) or scheduled via pg_cron alongside poll-active-orders.
//
// Pricing formula (per the user spec — 15 EUR -> 100 cr anchor):
//   credits = max(1, ceil(cost / 0.15))
//   So:    0.05 -> 1cr,  0.50 -> 4cr,  1.00 -> 7cr,
//          5.00 -> 34cr, 10.00 -> 67cr, 15.00 -> 100cr
// Tune CREDIT_DIVISOR below if margins need adjusting.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import { getCountryPrices, isOk } from "../_shared/smspva.ts";

const CREDIT_DIVISOR = 0.15;
const MIN_CREDITS = 1;
const MAX_CREDITS = 999;

function priceToCredits(price: number): number {
  if (!Number.isFinite(price) || price <= 0) return MIN_CREDITS;
  const raw = Math.ceil(price / CREDIT_DIVISOR);
  return Math.max(MIN_CREDITS, Math.min(MAX_CREDITS, raw));
}

function validateCronSecret(req: Request): boolean {
  const header = req.headers.get("x-cron-secret");
  const expected = Deno.env.get("CRON_SECRET");
  if (!header || !expected) return false;
  return header === expected;
}

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;
  if (!validateCronSecret(req)) {
    return json({ error: "unauthorized" }, { status: 401 });
  }

  const sb = admin();

  const { data: services, error: sErr } = await sb
    .from("services").select("id, smspva_code, cost");
  if (sErr || !services) {
    return json({ error: "services_load_failed", detail: sErr?.message }, { status: 500 });
  }
  const { data: countries, error: cErr } = await sb
    .from("countries").select("id, smspva_code");
  if (cErr || !countries) {
    return json({ error: "countries_load_failed", detail: cErr?.message }, { status: 500 });
  }

  const svcByCode = new Map<string, { id: string; cost: number }>();
  for (const s of services) svcByCode.set(s.smspva_code, { id: s.id, cost: s.cost });

  let countriesProcessed = 0;
  let routesUpdated = 0;
  let unknownServices = 0;
  let smsPvaFailures: string[] = [];

  for (const country of countries) {
    const resp = await getCountryPrices(country.smspva_code);
    if (!isOk(resp)) {
      smsPvaFailures.push(`${country.id}: ${(resp as { error?: { type?: string } }).error?.type ?? "unknown"}`);
      continue;
    }
    countriesProcessed++;

    const updates: {
      service_id: string;
      country_id: string;
      retail_credits: number;
      last_cost_cents: number;
      last_checked_at: string;
      status: string;
    }[] = [];

    for (const row of resp.data) {
      const svc = svcByCode.get(row.s);
      if (!svc) { unknownServices++; continue; }

      const priceNum = parseFloat(row.p);
      const credits  = priceToCredits(priceNum);

      updates.push({
        service_id:      svc.id,
        country_id:      country.id,
        retail_credits:  credits,
        last_cost_cents: Math.round(priceNum * 100),
        last_checked_at: new Date().toISOString(),
        status:          "active",
      });
    }

    if (updates.length === 0) continue;

    // Upsert in chunks — Postgres has a parameter limit per statement.
    const CHUNK = 500;
    for (let i = 0; i < updates.length; i += CHUNK) {
      const batch = updates.slice(i, i + CHUNK);
      const { error } = await sb
        .from("routes")
        .upsert(batch, { onConflict: "service_id,country_id" });
      if (error) {
        return json({
          error: "upsert_failed",
          country: country.id,
          detail: error.message,
          partial: { countriesProcessed, routesUpdated },
        }, { status: 500 });
      }
      routesUpdated += batch.length;
    }
  }

  return json({
    countriesProcessed,
    routesUpdated,
    unknownServices,
    smsPvaFailures,
    formula: `credits = max(${MIN_CREDITS}, ceil(price / ${CREDIT_DIVISOR}))`,
  });
});
