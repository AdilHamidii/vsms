// Pulls live SMSPVA prices for the full service × country matrix in a single
// /activation/servicesprices call, then bulk-updates routes.retail_credits via
// the pricing formula below. Auth gates this on the cron secret, so it can
// either be invoked manually (one-shot from terminal) or scheduled via
// pg_cron alongside poll-active-orders.
//
// Pricing formula (6x markup):
//   credits = max(1, ceil(cost / 0.05))
//   So:    0.05 -> 1cr,  0.50 -> 10cr,  1.00 -> 20cr,
//          2.00 -> 40cr, 3.00 -> 60cr,  4.00 -> 80cr
// Tune CREDIT_DIVISOR below if margins need adjusting — and move
// create-order's MIN_MARGIN with it (see the lockstep note there).
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

// 6× retail markup: credits = ceil(cost / 0.05). Valued at the conservative
// NET_USD_PER_CREDIT ($0.30) used by create-order's order-time ceiling, this
// collects 6× wholesale. Keep in lockstep with sync-smspool,
// sync-smspva-operators and create-order's MIN_MARGIN — the order-time ceiling
// (credits * NET / MIN_MARGIN) must equal this divisor exactly, or honest
// routes get refused at checkout / margin leaks.
const CREDIT_DIVISOR = 0.05;
const MIN_CREDITS = 1;
const MAX_CREDITS = 999;

// Price smoothing: retail_credits is derived from an EWMA of wholesale cost, not
// the single latest quote, so a one-day SMSPVA spike/dip doesn't flip a route
// between price tiers. SMOOTH_ALPHA weights the new quote; the rest carries the
// prior smoothed value. 0.5 ≈ a 2-day half-life. First observation seeds it.
const SMOOTH_ALPHA = 0.5;

// Price ceiling: hide any route whose wholesale cost exceeds this, marking it
// 'hidden' (cost() -> nil -> "Unavailable") instead of listing it.
//
// Tied to the LARGEST credit pack, not an arbitrary round number: 150 credits
// × $0.05 = $7.50 of wholesale. The rule is therefore "hide only what a user
// literally cannot buy" — above this, no combination of packs affords a single
// order, so listing it can only produce a dead end.
//
// Was 400 (a flat $4) until 2026-07-27, which hid WhatsApp across nearly every
// Western market — 40 of its 69 routes, including the UK, France, Netherlands
// and Poland at $5–6 wholesale — even though those are comfortably purchasable
// at 100–120 credits. WhatsApp is the single most-requested service, so it read
// as the app being broken rather than as a deliberate price cap.
//
// This does NOT override `blocked_routes` (app_config), which is a manual
// kill-list and still wins at any price. ⚠️ That list was CLEARED to `[]` on
// 2026-08-04 (owner decision) — it previously held whatsapp|us, google|us,
// openai|us and twitter-x|us, hidden because those numbers do not work rather
// than because they cost too much. Their 0-of-8 record was on providers we
// have since retired, so it was re-opened for measurement under 5sim. If
// delivery there stays at zero, put them back.
/** Owner decision 2026-08-04: the wholesale ceiling is REMOVED.
 *
 *  This was `150 credits x this provider's divisor` — the largest credit pack —
 *  so the rule was "hide only what a user literally cannot buy in one purchase".
 *  It now sits far above any real price (observed maxima: $30 herosms, $20 5sim
 *  and smspva) and is retained ONLY as a glitch guard: a provider feed returning
 *  a nonsense price should not price a route at 30,000 credits. Lower this one
 *  number to restore the cap; the next sync re-hides.
 *
 *  ⚠️ Removing it surfaced 1,345 routes priced 151-1,200 credits. They are
 *  visible but NOT orderable until the provider balance is topped up:
 *  create-order refuses before charging when the balance is under the order's
 *  own maxCostUsd, which is ~$27 for a 300-credit route and ~$108 for the
 *  dearest. See "Why a service reads Unavailable" in CLAUDE.md. */
const MAX_WHOLESALE_CENTS = 100_000;

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

  // Combos owned by ANY provider other than SMSPVA — skip them here so this
  // SMSPVA sync never clobbers their price/success.
  //
  // Deliberately `neq('smspva')` rather than a hardcoded list of the others.
  // The list form silently failed open: a provider not named in it kept having
  // its `retail_credits` and `smoothed_cost_cents` overwritten hourly from
  // SMSPVA's price book, so retail stayed pegged to a provider we no longer
  // buy from and margin analysis over `smoothed_cost_cents` was permanently
  // wrong. Any future provider is now covered the moment it owns a row,
  // without anyone remembering to edit this line.
  const { data: ownedRoutes } = await sb
    .from("routes").select("service_id, country_id").neq("provider", "smspva");
  const foreignOwned = new Set((ownedRoutes ?? []).map((r) => `${r.service_id}|${r.country_id}`));

  // Prior smoothed cost per route, for the EWMA below.
  const { data: prevRows } = await sb
    .from("routes").select("service_id, country_id, smoothed_cost_cents");
  const prevSmoothed = new Map<string, number>();
  for (const r of prevRows ?? []) {
    if (r.smoothed_cost_cents != null) {
      prevSmoothed.set(`${r.service_id}|${r.country_id}`, r.smoothed_cost_cents as number);
    }
  }

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
    smoothed_cost_cents: number;
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
    const cents = Math.round((price as number) * 100);
    for (let i = 0; i < svcs.length; i++) {
      const key = `${svcs[i].id}|${cid}`;
      if (foreignOwned.has(key)) continue; // another provider owns this combo
      if (i > 0) fannedOut++;
      pricedServiceIds.add(svcs[i].id);

      // EWMA the wholesale cost, then derive credits from the smoothed value so a
      // single-day quote can't flip the route between price tiers. Seed on first
      // observation. The hide ceiling still uses the raw current cost — if today's
      // cost is genuinely absurd, don't sell it regardless of history.
      // RATCHET: cost RISES apply immediately, only falls are smoothed.
      // Symmetric EWMA underprices after any jump — pricing off a smoothed
      // value below the real cost breaks the 3x rule until it catches up. When
      // this sync had been unscheduled for days, the first run produced 4,384
      // routes priced under their own wholesale cost. Same rule sync-smspool
      // already uses; smoothing only ever protects the user from a spike, it
      // must never protect the price from reality.
      const prev = prevSmoothed.get(key);
      const smoothed = prev == null || cents > prev
        ? cents
        : Math.round(SMOOTH_ALPHA * cents + (1 - SMOOTH_ALPHA) * prev);
      const credits = priceToCredits(smoothed / 100);
      const hide = blocked.has(key) || cents > MAX_WHOLESALE_CENTS;

      updates.push({
        service_id:         svcs[i].id,
        country_id:         cid,
        retail_credits:     credits,
        last_cost_cents:    cents,
        smoothed_cost_cents: smoothed,
        last_checked_at:    nowIso,
        status:             hide ? "hidden" : "active",
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
      // 'hidden' (not 'inactive' — that violates routes_status_check). Sweep
      // ONLY smspva-owned routes: this function prices smspva combos, so any
      // other provider's routes always look "stale" to it — excluding just
      // virtualsms let the guard hide the entire smspool catalog (live
      // incident 2026-07-19: 6,317 smspool routes swept to hidden).
      .update({ status: "hidden" }, { count: "exact" })
      .eq("status", "active")
      .eq("provider", "smspva")
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

  // ── Catalog maintenance ────────────────────────────────────────────────
  // These four used to live in sync-smspool. They are not SMSPool-specific
  // work, but they died when relay-sync-smspool was unscheduled for the SMSPVA
  // move — silently, so the "self-correcting" catalog quietly stopped
  // correcting: services that recovered never became visible again, and
  // delivery evidence froze at the moment SMSPool was retired.
  //
  // They live here now because sync-prices owns the active provider's pricing
  // and runs hourly. The two provider-scoped ones resolve the provider from
  // the data (active_sms_provider()) rather than a hardcoded string, so the
  // next provider switch cannot break them the same way.
  //
  // Order matters: observed success first (it can hide a proven-dead route),
  // then visibility (which reads route status), then evidence, then ranking
  // (which reads the evidence). Each is wrapped so one failure cannot abort
  // the others or fail the whole price sync.
  const maintenance: Record<string, unknown> = {};
  for (
    const [name, fn] of [
      // Route + service + country evidence, for EVERY provider that owns
      // active routes — not just whichever one `active_sms_provider()` votes
      // for. That vote counts active ROUTES, and after the per-service split
      // SMSPVA held 7,757 against HeroSMS's 5,201, so it returned the provider
      // that had stopped serving the demand and HeroSMS routes could never
      // accumulate a measured rate: `rate_source='measured'` was 0 rows
      // catalog-wide. The wrapper also scopes evidence to the provider that
      // still OWNS each service, which drops retired providers (smspool,
      // virtualsms) out of the window by construction.
      ["evidence", "refresh_evidence_all_providers"],
      ["visibilityChanged", "sync_service_visibility"],
      ["reranked", "apply_measured_service_ranking"],
      // Measured arrival percentiles. Migration 20260724120000 documented
      // itself as "called from sync-prices' hourly maintenance list" but was
      // never actually added here — so the p50/p90 were written once by hand
      // and then froze. Staleness is worse than absence for this one: the
      // function wipes every row it owns before rewriting, so a stale run
      // degrades to "say nothing" rather than to numbers about a provider we
      // no longer use.
      ["arrivalTiming", "refresh_arrival_timing"],
      // Country-level delivery evidence. Steering falls back to a tie-break
      // whenever the exact route has no record — which is ~17,800 of 17,800
      // minus 7 — and that tie-break used to be PRICE, i.e. "always pick the
      // cheapest country in the catalog". This is the evidence that replaces
      // it. Must run AFTER the route/service refreshes for the same reason
      // they are ordered: it reads the same order rows they classify.
      // (country evidence now runs inside refresh_evidence_all_providers —
      // once, not per provider, because a country is not owned by one)
    ] as const
  ) {
    try {
      const { data, error } = await sb.rpc(fn);
      maintenance[name] = error ? `error: ${error.message}` : data ?? 0;
      if (error) console.error(`sync-prices: ${fn} failed`, error.message);
    } catch (e) {
      maintenance[name] = `threw: ${String(e)}`;
      console.error(`sync-prices: ${fn} threw`, e);
    }
  }

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
    maintenance,
    servicesWithoutPricesCount: servicesWithoutPrices.length,
    servicesWithoutPrices: servicesWithoutPrices.slice(0, 40),
    unknownServiceCodes: [...unknownServiceCodes].slice(0, 40),
    formula: `credits = max(${MIN_CREDITS}, ceil(price / ${CREDIT_DIVISOR}))`,
  });
});
