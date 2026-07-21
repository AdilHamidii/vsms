// Discovers, per SMSPVA route, the real-SIM operator the premium tier should
// pin — and prices that tier from the operator's own per-operator price.
//
// SMSPVA's operator lists split into REAL carriers (KPN_NL, Vodafone_UK,
// EE_UK, ATT_US, ...) and anonymized donor pools (DonorAlpha_*, DonorEcho_*,
// ... — NATO-phonetic pseudo-operators; probed live 2026-07-21). Donor
// numbers are what strict-risk services (Meta et al) reject. The premium tier
// sells a pin to a real carrier; this job decides which one and at what price.
//
// One API call per country (GET /activation/serviceprice/{CC} returns every
// service with a `po` operator→price map — 273/273 rows carried one when
// probed). SMSPVA asks for 4-5s between calls, so each run handles a bounded
// batch of countries and resumes from an app_config cursor; the hourly cron
// completes a full pass over ~70 countries in ~6 runs, then keeps cycling.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import { getCountryPrices, isOk } from "../_shared/smspva.ts";

// Keep in lockstep with sync-prices: same divisor, same wholesale ceiling.
const CREDIT_DIVISOR = 0.10;
const MIN_CREDITS = 1;
const MAX_CREDITS = 999;
const MAX_WHOLESALE_CENTS = 400;

const COUNTRIES_PER_RUN = 12;   // ~12 × 4.5s ≈ 55s per run
const CALL_SPACING_MS = 4500;   // SMSPVA: "interval of 4 to 5 seconds"
const CURSOR_KEY = "smspva_operator_sync";

// Anything that is not an anonymized pool or an aggregate row is a carrier.
// Total_XX is the base-price aggregate SMSPVA includes in every po map;
// Other_XX / MVNO_XX are grab-bag buckets with no carrier identity.
function isRealCarrier(op: string): boolean {
  return !/^(donor|other_|mvno_|total_)/i.test(op);
}

function toCredits(cents: number): number {
  const raw = Math.ceil(cents / 100 / CREDIT_DIVISOR);
  return Math.max(MIN_CREDITS, Math.min(MAX_CREDITS, raw));
}

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
    .from("services").select("id, smspva_code");
  if (sErr || !services) {
    return json({ error: "services_load_failed", detail: sErr?.message }, { status: 500 });
  }
  const { data: countries, error: cErr } = await sb
    .from("countries").select("id, smspva_code")
    .not("smspva_code", "is", null)
    .order("id");
  if (cErr || !countries) {
    return json({ error: "countries_load_failed", detail: cErr?.message }, { status: 500 });
  }

  // Only routes that already exist get annotated — sync-prices owns creation.
  const { data: routeRows, error: rErr } = await sb
    .from("routes").select("service_id, country_id, retail_credits")
    .eq("provider", "smspva");
  if (rErr || !routeRows) {
    return json({ error: "routes_load_failed", detail: rErr?.message }, { status: 500 });
  }
  const routeRetail = new Map<string, number | null>();
  for (const r of routeRows) {
    routeRetail.set(`${r.service_id}|${r.country_id}`, r.retail_credits as number | null);
  }

  // One smspva_code can map to multiple catalog services (see sync-prices).
  const svcByCode = new Map<string, string[]>();
  for (const s of services) {
    if (!s.smspva_code) continue;
    const list = svcByCode.get(s.smspva_code);
    if (list) list.push(s.id);
    else svcByCode.set(s.smspva_code, [s.id]);
  }

  // Resume after the cursor country; wrap to the start when past the end.
  const { data: curRow } = await sb
    .from("app_config").select("value").eq("key", CURSOR_KEY).maybeSingle();
  const cursor = (curRow?.value as { cursor?: string } | null)?.cursor ?? null;
  let start = cursor ? countries.findIndex((c) => c.id === cursor) + 1 : 0;
  if (start >= countries.length || start < 0) start = 0;
  const batch = countries.slice(start, start + COUNTRIES_PER_RUN);

  let pinned = 0;
  let cleared = 0;
  let fetchErrors = 0;
  const processed: string[] = [];

  for (const [i, country] of batch.entries()) {
    if (i > 0) await sleep(CALL_SPACING_MS);

    const resp = await getCountryPrices(country.smspva_code as string);
    if (!isOk(resp) || !Array.isArray(resp.data)) {
      // A failed fetch must not clear existing pins — skip the country whole.
      fetchErrors++;
      console.warn(`sync-smspva-operators: fetch failed for ${country.id}:`,
        (resp as { error?: { type?: string } }).error?.type ?? "bad shape");
      continue;
    }

    const picks: {
      service_id: string;
      country_id: string;
      smspva_operator: string;
      smspva_operator_cents: number;
      premium_credits: number;
    }[] = [];

    for (const row of resp.data) {
      const svcIds = svcByCode.get(row.s);
      if (!svcIds || !row.po) continue;

      // Cheapest real carrier under the wholesale ceiling. Price is NOT a
      // quality signal among carriers (mostly flat; where it spreads, SMSPVA
      // prices demand) — the win premium buys is carrier-vs-donor, so take
      // the margin-friendly carrier and let per-operator order outcomes
      // (orders.smspool_pool) steer upgrades later.
      let bestOp: string | null = null;
      let bestCents = Infinity;
      for (const [op, priceStr] of Object.entries(row.po)) {
        if (!isRealCarrier(op)) continue;
        const usd = parseFloat(priceStr);
        if (!Number.isFinite(usd) || usd <= 0) continue;
        const cents = Math.round(usd * 100);
        if (cents > MAX_WHOLESALE_CENTS) continue;
        if (cents < bestCents) { bestCents = cents; bestOp = op; }
      }
      if (!bestOp) continue;

      for (const svcId of svcIds) {
        const key = `${svcId}|${country.id}`;
        if (!routeRetail.has(key)) continue;
        // Premium is never cheaper than standard: equal wholesale still buys
        // the real-SIM pin + fail-fast guarantee.
        const floor = routeRetail.get(key) ?? MIN_CREDITS;
        picks.push({
          service_id: svcId,
          country_id: country.id,
          smspva_operator: bestOp,
          smspva_operator_cents: bestCents,
          premium_credits: Math.max(floor, toCredits(bestCents)),
        });
      }
    }

    // Clear-then-set: stale pins from carriers that vanished must not linger.
    // The seconds-wide window where a route has no pin is covered by
    // create-order's premium_unavailable re-check.
    const { count: clearCount, error: clearErr } = await sb
      .from("routes")
      .update(
        { smspva_operator: null, smspva_operator_cents: null, premium_credits: null },
        { count: "exact" },
      )
      .eq("country_id", country.id)
      .eq("provider", "smspva")
      .not("smspva_operator", "is", null);
    if (clearErr) {
      return json({ error: "clear_failed", detail: clearErr.message, country: country.id }, { status: 500 });
    }
    cleared += clearCount ?? 0;

    const CHUNK = 500;
    for (let j = 0; j < picks.length; j += CHUNK) {
      const { error: upErr } = await sb
        .from("routes")
        .upsert(picks.slice(j, j + CHUNK), { onConflict: "service_id,country_id" });
      if (upErr) {
        return json({ error: "upsert_failed", detail: upErr.message, country: country.id }, { status: 500 });
      }
    }
    pinned += picks.length;
    processed.push(country.id);
  }

  // Advance the cursor to the last country we attempted (even on fetch
  // errors — a broken country must not wedge the rotation).
  const last = batch.length > 0 ? batch[batch.length - 1].id : null;
  if (last) {
    const { error: curErr } = await sb
      .from("app_config")
      .upsert({ key: CURSOR_KEY, value: { cursor: last } }, { onConflict: "key" });
    if (curErr) console.error("sync-smspva-operators: cursor write failed", curErr.message);
  }

  return json({
    countriesProcessed: processed.length,
    countries: processed,
    routesPinned: pinned,
    routesCleared: cleared,
    fetchErrors,
    cursor: last,
    wrapped: start === 0 && cursor != null,
  });
});
