// Hourly 5sim catalog sync: price every mapped route from THE POOL WE WILL BUY
// FROM, and record that pool's published delivery rate.
//
// The whole reason 5sim is the SMS provider is that its public price feed
// publishes a per-POOL delivery rate — no provider we have used has exposed
// that by API. So this sync does not just price: it CHOOSES, per route, the
// pool create-order will pin, and stores the choice and its rate as one tuple.
//
// ⚠️ THE COST AND THE POOL MUST BE WRITTEN TOGETHER, ALWAYS.
// Gating margin against pool A and then buying from pool B is exactly the
// apple/Turkey `getPrices.cost` bug: we stored a $0.30 default while the only
// stock in existence cost $0.4177, priced the route 1.8 cents under the floor,
// and charged-and-refunded a paying customer eight times until they left.
// `fivesim_cost_cents` is the cost OF `pool_operator[0]`. Never of anything else.
//
// Fetching is PER COUNTRY (61 requests), not the single all-countries form.
// That response is 9.1 MB; per-country is 0.1-0.6 MB, which keeps peak memory
// bounded inside the edge runtime and lets a partial run still write what it
// got. 5sim allows 100 req/s by IP, so 61 sequential requests is nothing.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import { getPricesForCountry, type FivePool } from "../_shared/fivesim.ts";

// LOCKSTEP with create-order's MIN_MARGIN_BY_PROVIDER["5sim"] = 10.0.
// 0.30 / 10 = 0.03. Owner decision 2026-08-03 (10x markup).
const CREDIT_DIVISOR = 0.03;
const MIN_CREDITS = 1;
const MAX_CREDITS = 999;

// Hide only what a user literally cannot buy: the largest credit pack is 150,
// so 150 * 0.03 = $4.50. Same rule as the other syncs, recomputed for OUR
// divisor — this constant is NOT shared, and copying HeroSMS's 375 would hide
// routes that are perfectly affordable at this markup.
const MAX_WHOLESALE_CENTS = 450;

// A rate with no denominator is only meaningful if the pool can actually serve.
// 5sim publishes no order count behind `rate720` and shows rates on pools
// holding a single number — leboncoin/Portugal reads 79% on 209 numbers. Below
// this floor we ignore the rate rather than advertise it.
const MIN_POOL_STOCK = 100;

// Only falls are damped. A RISE applies immediately, because averaging a rise
// against yesterday's cheaper price sets retail BELOW what we are about to pay
// — that shipped once and put 4,384 routes under wholesale in a single run.
const SMOOTH_ALPHA = 0.5;

const CHUNK = 500;

// ⚠️ 5sim's DOCUMENTED rate limit is wrong for this endpoint.
// The docs claim "100 requests per second by IP address". Measured 2026-08-03:
// unspaced sequential calls to guest/prices return 200 six times and then
// HTTP 429 for every subsequent request — the first live run of this sync got
// 10 countries through and lost 51 in 2.4 seconds. 600ms was measured clean at
// 12/12; 61 countries then costs ~55s, well inside the ~150s edge budget.
//
// Do not lower this casually: 5sim bans the key for 10 minutes after the limit
// is tripped 5 times within 10 minutes, and that key also has to buy numbers.
const CALL_SPACING_MS = 600;
const RETRY_PAUSE_MS = 2_500;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function priceToCredits(usd: number): number {
  if (!Number.isFinite(usd) || usd <= 0) return MIN_CREDITS;
  return Math.min(MAX_CREDITS, Math.max(MIN_CREDITS, Math.ceil(usd / CREDIT_DIVISOR)));
}

interface Chosen {
  chain: string[];      // ordered pool slugs, best first
  costUsd: number;      // cost of chain[0] — the pool we will actually buy
  stock: number;
  ratePct: number | null;
}

/** Pick the pool create-order should pin.
 *
 *  Rated pools win outright, best rate first. Only when NO pool clears the
 *  stock floor with a published rate do we fall back to the most-stocked pool
 *  and record `ratePct = null` — which means "unrated", never "0%". Those
 *  routes are still sold and simply rank last (owner decision 2026-08-03).
 */
function choosePool(pools: Record<string, FivePool>): Chosen | null {
  const inStock = Object.entries(pools)
    .filter(([, v]) => Number.isFinite(v.cost) && v.cost > 0 && (v.count ?? 0) > 0);
  if (!inStock.length) return null;

  const rated = inStock
    .filter(([, v]) => (v.count ?? 0) >= MIN_POOL_STOCK && typeof v.rate720 === "number")
    .sort((a, b) => (b[1].rate720 as number) - (a[1].rate720 as number));

  if (rated.length) {
    const [op, v] = rated[0];
    return {
      chain: rated.slice(0, 3).map(([o]) => o),
      costUsd: v.cost,
      stock: v.count ?? 0,
      ratePct: Math.round(v.rate720 as number),
    };
  }
  const byStock = inStock.sort((a, b) => (b[1].count ?? 0) - (a[1].count ?? 0));
  const [op, v] = byStock[0];
  return {
    chain: byStock.slice(0, 3).map(([o]) => o),
    costUsd: v.cost,
    stock: v.count ?? 0,
    ratePct: null,
  };
}

Deno.serve(async (req) => {
  const cors = handleCors(req);
  if (cors) return cors;
  const secret = req.headers.get("x-cron-secret");
  if (!secret || secret !== Deno.env.get("CRON_SECRET")) {
    return json({ error: "unauthorized" }, { status: 403 });
  }

  const sb = admin();
  const startedAt = Date.now();

  const { data: services, error: svcErr } = await sb
    .from("services").select("id, fivesim_product").not("fivesim_product", "is", null);
  if (svcErr) return json({ error: "services_read_failed", detail: svcErr.message }, { status: 500 });

  const { data: countries, error: cErr } = await sb
    .from("countries").select("id, fivesim_country").not("fivesim_country", "is", null);
  if (cErr) return json({ error: "countries_read_failed", detail: cErr.message }, { status: 500 });
  if (!countries?.length) return json({ error: "no_mapped_countries" }, { status: 500 });

  // Existing rows. Every (service, country) pair already HAS a route row, so
  // this sync only ever updates — it never inserts, and never deletes.
  const { data: routes, error: rErr } = await sb
    .from("routes")
    .select("service_id, country_id, status, provider, retail_credits, fivesim_smoothed_cost_cents");
  if (rErr) return json({ error: "routes_read_failed", detail: rErr.message }, { status: 500 });
  if (!routes?.length) return json({ error: "no_routes" }, { status: 500 });

  const { data: cfg } = await sb
    .from("app_config").select("key, value")
    .in("key", ["blocked_routes", "fivesim_live"]);
  const blocked = new Set<string>(
    (cfg?.find((r) => r.key === "blocked_routes")?.value as string[] | undefined) ?? [],
  );
  // Fails CLOSED: absent config means shadow mode. In shadow we write the
  // fivesim_* and pool_* columns but touch neither `provider` nor `status` nor
  // `retail_credits`, so the live catalog is untouched and the run's counters
  // can be read BEFORE anything is sold. HeroSMS's first live run hid 4,849
  // routes, "~3x more than estimated" — that surprise is what this prevents.
  const live = cfg?.find((r) => r.key === "fivesim_live")?.value === true;

  const svcByProduct = new Map<string, string[]>();
  for (const s of services ?? []) {
    const p = s.fivesim_product as string;
    (svcByProduct.get(p) ?? svcByProduct.set(p, []).get(p)!).push(s.id as string);
  }

  const chosen = new Map<string, Chosen>();  // "service|country" -> pool choice
  let countriesOk = 0, countriesFailed = 0;
  const failedCountries: string[] = [];

  for (const [i, c] of countries.entries()) {
    const slug = c.fivesim_country as string;
    if (i > 0) await sleep(CALL_SPACING_MS);
    let payload = await getPricesForCountry(slug);
    if (!payload) {
      // One retry after a longer pause. The dominant failure here is a 429,
      // and a country dropped from a run is inventory that silently reads as
      // "5sim does not serve it" for the next hour.
      await sleep(RETRY_PAUSE_MS);
      payload = await getPricesForCountry(slug);
    }
    if (!payload) { countriesFailed++; failedCountries.push(slug); continue; }
    countriesOk++;
    const products = payload[slug] ?? {};
    for (const [product, pools] of Object.entries(products)) {
      const ourServices = svcByProduct.get(product);
      if (!ourServices) continue;
      const pick = choosePool(pools as Record<string, FivePool>);
      if (!pick) continue;
      for (const sid of ourServices) chosen.set(`${sid}|${c.id}`, pick);
    }
  }

  // TOTAL-WIPEOUT GUARD. If every country failed we know nothing, and writing
  // would hide the catalog behind a network blip.
  if (countriesOk === 0) {
    return json({ error: "all_price_fetches_failed", countries: countries.length }, { status: 502 });
  }

  const nowIso = new Date().toISOString();
  const updates: Record<string, unknown>[] = [];
  let sellable = 0, hiddenNoStock = 0, hiddenBlocked = 0, hiddenTooDear = 0;
  let rated = 0, unrated = 0, skippedFailedCountry = 0;

  const failedSet = new Set(failedCountries);
  const ctyBySlug = new Map((countries).map((c) => [c.id as string, c.fivesim_country as string]));

  for (const r of routes) {
    const key = `${r.service_id}|${r.country_id}`;
    const pick = chosen.get(key);
    const slug = ctyBySlug.get(r.country_id as string);

    // A country whose fetch failed THIS RUN tells us nothing. Reading that as
    // "5sim does not serve it" would hide real inventory on a transient error.
    if (!pick && slug && failedSet.has(slug)) { skippedFailedCountry++; continue; }
    // Not mapped at all (no 5sim product/country) — leave the row entirely
    // alone; it keeps its current provider. This is NOT a stockout and must not
    // be counted as one: on 5sim a bad country and an empty pool return the
    // identical `no free phones`, so conflating them here would make a mapping
    // regression invisible.
    if (!pick && !slug) continue;

    const costCents = pick ? Math.round(pick.costUsd * 100) : null;
    const prev = r.fivesim_smoothed_cost_cents as number | null;
    const smoothed = costCents == null
      ? prev
      : prev == null || costCents > prev
      ? costCents
      : Math.round(SMOOTH_ALPHA * costCents + (1 - SMOOTH_ALPHA) * prev);

    let status: string;
    if (!pick) { status = "hidden"; hiddenNoStock++; }
    else if (blocked.has(key)) { status = "hidden"; hiddenBlocked++; }
    // Ceiling is checked against the RAW cost, pricing against the smoothed one.
    else if (costCents != null && costCents > MAX_WHOLESALE_CENTS) { status = "hidden"; hiddenTooDear++; }
    else { status = "active"; sellable++; if (pick.ratePct != null) rated++; else unrated++; }

    const row: Record<string, unknown> = {
      service_id: r.service_id,
      country_id: r.country_id,
      fivesim_cost_cents: costCents,
      fivesim_smoothed_cost_cents: smoothed,
      fivesim_stock: pick?.stock ?? null,
      fivesim_checked_at: nowIso,
      pool_operator: pick ? pick.chain.join(",") : null,
      pool_rate_pct: pick?.ratePct ?? null,
      pool_rate_window: pick?.ratePct != null ? "720h" : null,
      pool_rate_checked_at: pick?.ratePct != null ? nowIso : null,
    };
    if (live) {
      row.provider = "5sim";
      row.status = status;
      row.retail_credits = smoothed != null ? priceToCredits(smoothed / 100) : r.retail_credits;
      // 5sim has no Real SIM tier: it sells virtual pools and names no carrier.
      // The shipped app renders the tier chips off premium_credits and
      // create-order 409s a premium request without a pin, so it MUST be NULL
      // or the tier becomes a visible dead end.
      row.premium_credits = null;
      row.real_sim_only = false;
    }
    updates.push(row);
  }

  let written = 0;
  for (let i = 0; i < updates.length; i += CHUNK) {
    const slice = updates.slice(i, i + CHUNK);
    const { error } = await sb.from("routes").upsert(slice, { onConflict: "service_id,country_id" });
    if (error) {
      return json({ error: "write_failed", detail: error.message, written }, { status: 500 });
    }
    written += slice.length;
  }

  const out = {
    live, written, countries_ok: countriesOk, countries_failed: countriesFailed,
    failed_countries: failedCountries.slice(0, 10),
    priced_pairs: chosen.size,
    sellable, rated, unrated,
    hidden_no_stock: hiddenNoStock, hidden_blocked: hiddenBlocked, hidden_too_dear: hiddenTooDear,
    skipped_failed_country: skippedFailedCountry,
    ms: Date.now() - startedAt,
  };
  console.log("sync-5sim", JSON.stringify(out));
  return json(out);
});
