// Pulls live SMSPVA prices for the full service × country matrix in a single
// /activation/servicesprices call, then bulk-updates routes.retail_credits via
// the pricing formula below. Auth gates this on the cron secret, so it can
// either be invoked manually (one-shot from terminal) or scheduled via
// pg_cron alongside poll-active-orders.
//
// Pricing formula (per the user spec — 15 EUR -> 100 cr anchor):
//   credits = max(1, ceil(cost / 0.15))
//   So:    0.05 -> 1cr,  0.50 -> 4cr,  1.00 -> 7cr,
//          5.00 -> 34cr, 10.00 -> 67cr, 15.00 -> 100cr
// Tune CREDIT_DIVISOR below if margins need adjusting.
//
// IMPORTANT (money-critical): multiple catalog services can legitimately share
// one smspva_code (e.g. apple-id + apple-music both map to SMSPVA's "Apple"
// opt131). Earlier this function keyed services by code in a plain Map, so only
// ONE service per code ever received a price — every other service sharing that
// code was silently frozen at its seed price and sold blind. We now fan a price
// row out to ALL services sharing the code, and any active route NOT refreshed
// in a healthy run is deactivated so nothing is ever sold on an unverified price.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import { getAllPrices, isOk } from "../_shared/smspva.ts";

// 5× retail markup: credits = ceil(cost / 0.10). A credit sells for ~$0.50
// (blended pack), so this collects ~5× wholesale → ~65% net after Apple's 15%
// Small-Business fee. Keep in lockstep with sync-virtualsms.
const CREDIT_DIVISOR = 0.10;
const MIN_CREDITS = 1;
const MAX_CREDITS = 999;

// Price ceiling: hide any route whose wholesale cost exceeds this. 5× on a
// $6–150 SMSPVA WhatsApp price is absurd ($30–750 retail); above the ceiling we
// mark the route 'hidden' (cost() -> nil -> "Unavailable") instead of listing
// it. ~96% of the catalog is <= $4, so this only trims the blocked-heavy tail.
const MAX_WHOLESALE_CENTS = 400;

// Stale-guard safety floor. Only deactivate unrefreshed routes when this run
// successfully priced at least this many — otherwise a transient SMSPVA failure
// (empty/partial response) would wrongly inactivate the whole catalog.
const DEACTIVATE_FLOOR = 5000;

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

  // Combos the weekly virtualsms overlay owns — skip them here so we never
  // clobber the real-SIM price/provider with an SMSPVA one.
  const { data: vsRoutes } = await sb
    .from("routes").select("service_id, country_id").eq("provider", "virtualsms");
  const vsOwned = new Set((vsRoutes ?? []).map((r) => `${r.service_id}|${r.country_id}`));

  // Manually blocked combos (app_config 'blocked_routes' = ["service|country"]).
  // Used to hide combos that structurally never deliver on VoIP — e.g. US
  // WhatsApp/Google/OpenAI/Twitter, which SMSPVA can't fulfil and virtualsms
  // has no US supply for. Editable without a redeploy.
  const { data: blkRow } = await sb
    .from("app_config").select("value").eq("key", "blocked_routes").maybeSingle();
  const blocked = new Set<string>(Array.isArray(blkRow?.value) ? (blkRow!.value as string[]) : []);

  // A single smspva_code may map to MULTIPLE catalog services — fan a price row
  // out to every one of them, never just the last.
  const svcByCode = new Map<string, { id: string }[]>();
  for (const s of services) {
    const list = svcByCode.get(s.smspva_code);
    if (list) list.push({ id: s.id });
    else svcByCode.set(s.smspva_code, [{ id: s.id }]);
  }
  const ctyByCode = new Map<string, string>();
  for (const c of countries) ctyByCode.set(c.smspva_code, c.id);

  // One bulk call returns the full service × country matrix. SMSPVA's actual
  // runtime shape varies — we tolerate either BulkPriceRow[][] (nested by
  // country) or a flat BulkPriceRow[].
  const resp = await getAllPrices();
  if (!isOk(resp)) {
    const errType = (resp as { error?: { type?: string } }).error?.type ?? "unknown";
    return json({ error: "smspva_bulk_failed", detail: errType }, { status: 502 });
  }

  // Normalize: flatten arrays-of-arrays, accept already-flat arrays.
  const flat: unknown[] = [];
  if (Array.isArray(resp.data)) {
    for (const item of resp.data) {
      if (Array.isArray(item)) {
        for (const row of item) flat.push(row);
      } else {
        flat.push(item);
      }
    }
  }

  if (flat.length === 0) {
    return json({
      error: "smspva_empty_response",
      shape: typeof resp.data,
      sample: JSON.stringify(resp.data).slice(0, 400),
    }, { status: 502 });
  }

  // Detect short-key vs long-key form. Per-country endpoint uses {s,c,p}
  // (string p); the bulk endpoint historically uses {service,country,price}
  // (numeric price). Support both.
  function extract(row: unknown): { service?: string; country?: string; price?: number } {
    if (!row || typeof row !== "object") return {};
    const r = row as Record<string, unknown>;
    const service = (r.service ?? r.s) as string | undefined;
    const country = (r.country ?? r.c) as string | undefined;
    const rawPrice = r.price ?? r.p;
    const price = typeof rawPrice === "number"
      ? rawPrice
      : typeof rawPrice === "string" ? parseFloat(rawPrice) : NaN;
    return { service, country, price };
  }

  const nowIso = new Date().toISOString();
  const updates: {
    service_id: string;
    country_id: string;
    retail_credits: number;
    last_cost_cents: number;
    last_checked_at: string;
    status: string;
  }[] = [];

  let unknownServices = 0;
  let unknownCountries = 0;
  let badRows = 0;              // unparseable OR non-positive price (treat as unavailable)
  let fannedOut = 0;            // extra updates produced by shared-code fan-out
  const seenCountries = new Set<string>();
  const pricedServiceIds = new Set<string>();
  const unknownServiceCodes = new Set<string>();

  for (const raw of flat) {
    const { service, country, price } = extract(raw);
    // A price of 0 / negative is SMSPVA's "unavailable" sentinel — never sell it
    // at the 1-credit floor; leave the route to be deactivated by the guard.
    if (!service || !country || !Number.isFinite(price) || (price as number) <= 0) {
      badRows++; continue;
    }
    const svcs = svcByCode.get(service);
    const cid = ctyByCode.get(country);
    if (!svcs) { unknownServices++; unknownServiceCodes.add(service); continue; }
    if (!cid) { unknownCountries++; continue; }

    seenCountries.add(cid);
    const credits = priceToCredits(price as number);
    const cents = Math.round((price as number) * 100);
    for (let i = 0; i < svcs.length; i++) {
      const key = `${svcs[i].id}|${cid}`;
      if (vsOwned.has(key)) continue; // virtualsms owns this combo
      if (i > 0) fannedOut++;
      pricedServiceIds.add(svcs[i].id);
      const hide = blocked.has(key) || cents > MAX_WHOLESALE_CENTS;
      updates.push({
        service_id:      svcs[i].id,
        country_id:      cid,
        retail_credits:  credits,
        last_cost_cents: cents,
        last_checked_at: nowIso,
        status:          hide ? "hidden" : "active",
      });
    }
  }

  if (updates.length === 0) {
    return json({
      error: "no_valid_rows",
      flatRows: flat.length,
      badRows,
      unknownServices,
      unknownCountries,
      sample: JSON.stringify(flat[0]).slice(0, 200),
    }, { status: 502 });
  }

  // Chunked upsert — Postgres has a parameter limit per statement.
  let routesUpdated = 0;
  const CHUNK = 500;
  for (let i = 0; i < updates.length; i += CHUNK) {
    const batch = updates.slice(i, i + CHUNK);
    const { error } = await sb
      .from("routes")
      .upsert(batch, { onConflict: "service_id,country_id" });
    if (error) {
      return json({
        error: "upsert_failed",
        detail: error.message,
        partial: { routesUpdated },
      }, { status: 500 });
    }
    routesUpdated += batch.length;
  }

  // Stale-guard: any route still 'active' but NOT refreshed in this run (older
  // or null last_checked_at) couldn't be priced from live data — deactivate it
  // so create-order refuses it instead of selling on a stale/unverified price.
  // A later run re-activates it via upsert when the price reappears. Gated on
  // DEACTIVATE_FLOOR so a partial API response can't wipe the catalog.
  let deactivated = 0;
  let deactivateSkipped = false;
  if (routesUpdated >= DEACTIVATE_FLOOR) {
    const { error: deErr, count } = await sb
      .from("routes")
      // 'hidden' (not 'inactive' — that violates routes_status_check). Never
      // touch virtualsms-owned routes; the weekly overlay manages those.
      .update({ status: "hidden" }, { count: "exact" })
      .eq("status", "active")
      .neq("provider", "virtualsms")
      .or(`last_checked_at.is.null,last_checked_at.lt."${nowIso}"`);
    if (deErr) {
      return json({
        error: "deactivate_failed",
        detail: deErr.message,
        partial: { routesUpdated },
      }, { status: 500 });
    }
    deactivated = count ?? 0;
  } else {
    deactivateSkipped = true;
  }

  // Catalog services that received NO price this run — the monitoring hook that
  // would have caught the duplicate-code freeze. Surface a sample in the result.
  const servicesWithoutPrices = services
    .filter((s) => !pricedServiceIds.has(s.id))
    .map((s) => s.id);

  return json({
    countriesProcessed: seenCountries.size,
    routesUpdated,
    fannedOut,
    deactivated,
    deactivateSkipped,
    unknownServices,
    unknownCountries,
    badRows,
    flatRows: flat.length,
    servicesWithoutPricesCount: servicesWithoutPrices.length,
    servicesWithoutPrices: servicesWithoutPrices.slice(0, 40),
    unknownServiceCodes: [...unknownServiceCodes].slice(0, 40),
    formula: `credits = max(${MIN_CREDITS}, ceil(price / ${CREDIT_DIVISOR}))`,
  });
});
