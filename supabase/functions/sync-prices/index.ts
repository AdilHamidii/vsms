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

// ─── SMSPVA serviceability guards (added 2026-08-08) ──────────────────────
//
// THE PROBLEM THESE SOLVE: `getAllPrices()` is a PRICE-ONLY feed. BulkPriceRow
// is {service, serviceDescription, country, price} — there is no stock field,
// and SMSPVA exposes no stock endpoint at all (see _shared/smspva.ts: every
// endpoint is price, balance, conversions or order lifecycle). So this sync
// marks a route `active` on the strength of a QUOTE, with no evidence anyone
// can actually buy it. That is the same phantom-price trap sync-herosms hit
// with `getPrices` — "advertises a price with ZERO stock behind it" — one
// provider over, except here we cannot even detect it per route.
//
// Measured 2026-08-08 over the trailing 7 days: SMSPVA took 46 orders,
// **41 never reserved a number and 0 delivered a code**. Reservation rate by
// tier was premium 0/26 and standard 5/20, and the 5 that did reserve all
// expired codeless. Meanwhile 5sim and HeroSMS sat at 100% reservation in
// every 7-day window across 30 days. SMSPVA ran at 95–100% itself until
// 2026-07-25 and then decayed 97% → 76% → 68% → 40.6% → 10.9%.
//
// Both guards below only ever move `status`, are recomputed from live data on
// every hourly run, and therefore UN-HIDE by themselves. Neither deletes a
// route, neither touches another provider's rows, and neither needs a redeploy
// to reverse.

/** Trailing window for the reservation-rate verdict. */
const RESERVE_LOOKBACK_DAYS = 7;
/** Minimum SMSPVA orders in the window before the rate means anything.
 *
 *  Reachability was checked rather than guessed, because this repo has already
 *  shipped a watchdog gate that could never fire: SMSPVA's LOWEST 7-day order
 *  count over the last 30 days was 10, so 8 is comfortably reachable whenever
 *  the provider is actually being sold.
 *
 *  It is also the ANTI-DEADLOCK term, and that is its more important job. Once
 *  the collapse verdict hides every SMSPVA route, no further SMSPVA orders can
 *  be placed, so the window drains; ~7 days later `n` falls under this floor,
 *  the verdict clears on its own, and the catalog is re-offered for a fresh
 *  trial. Since SMSPVA publishes no stock, OUR OWN ORDERS ARE THE ONLY
 *  INSTRUMENT WE HAVE — a permanent hide would be unfalsifiable. */
const RESERVE_MIN_ORDERS = 8;
/** Reservation rate under this (percent) is a collapse.
 *
 *  Derived from measurement, not taste. Over 30 days of rolling 7-day windows:
 *  5sim and HeroSMS never read below 100.0%, healthy SMSPVA never below 95.7%,
 *  and the lowest reading during its healthy era was 68.6%. The first firing
 *  window reads 40.6%. So 50 sits in a wide empty band — it cannot fire on a
 *  working provider and it fires decisively on this one. */
const RESERVE_MIN_PCT = 50;
/** Matches create-order's own staleness bound for a health reading. */
const HEALTH_FRESH_MS = 5 * 60 * 1000;

/** ⚠️ MIRRORS OF create-order CONSTANTS — CHANGE BOTH TOGETHER.
 *
 *  These four reproduce `maxCostUsd` from create-order/index.ts exactly (see
 *  the block around `const maxCostUsd = Math.min(...)`). They are duplicated
 *  rather than shared because `_shared/*` is bundled per function, so moving
 *  them would force a redeploy of the busiest money path in the product to
 *  change a catalog sync. Same trade this repo already makes for
 *  CREDIT_DIVISOR across the four syncs — and the same standing warning: a
 *  constant duplicated across files WILL drift. If create-order's ceiling
 *  changes and this does not, the only symptom is routes that stay visible
 *  while checkout refuses them, which is precisely the bug being fixed here. */
const NET_USD_PER_CREDIT = 0.40;
const SMSPVA_MIN_MARGIN = 8.0;      // MIN_MARGIN_BY_PROVIDER.smspva

/** 🔴 SMSPVA IS RETIRED FROM ROUTING (owner decision, 2026-08-17) and this
 *  sync MUST NOT put its routes back on the shelf.
 *
 *  `providerOrder()` no longer returns "smspva" for any route, so an
 *  smspva-owned row that is `active` is a route the catalog advertises and
 *  NOBODY CAN FILL — the router returns [] and the order dies.
 *
 *  That is not hypothetical, it happened the same day: migration
 *  20260817100000 hid 4,156 of these routes at 10:36, and the 21:17 run of
 *  THIS FUNCTION re-activated all 6,305 of them in one pass, because the
 *  serviceability block below is deliberately non-sticky ("the upsert flips
 *  status back to 'active' the moment the condition clears"). Measured
 *  immediately after: 5,955 of 15,293 active routes — 39% of the visible
 *  catalog — had no 5sim or HeroSMS fallback and were unfillable.
 *
 *  This is the exact hazard the provider-switch checklist warns about: the
 *  retired provider's sync is still scheduled, and it silently outvotes the
 *  migration every hour. The cron cannot simply be unscheduled — sync-prices
 *  also carries the catalog maintenance list (evidence refreshes, arrival
 *  timing, service visibility, ranking), which died once already when a
 *  provider's sync was switched off.
 *
 *  Rollback is this one constant, together with restoring the two branches in
 *  `providerOrder()`. Keep the two in lockstep: pricing a provider the router
 *  cannot select is what created the hole. */
const SMSPVA_RETIRED = true;
const CEILING_SLACK_MULTIPLE = 3.0;
const CEILING_HEADROOM_USD = 0.10;
const MAX_REVENUE_FRACTION = 0.5;

/** The order-time ceiling create-order will compute for an SMSPVA route at
 *  `credits`. If the live balance is below this, create-order refuses the order
 *  BEFORE charging and returns `provider_unreachable` — so the route is not
 *  buyable, however good its price looks. */
function orderCeilingUsd(credits: number): number {
  return Math.min(
    (credits * NET_USD_PER_CREDIT / SMSPVA_MIN_MARGIN) * CEILING_SLACK_MULTIPLE +
      CEILING_HEADROOM_USD,
    credits * NET_USD_PER_CREDIT * MAX_REVENUE_FRACTION,
  );
}

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

  // ── Guard 1: affordability ────────────────────────────────────────────
  // poll-active-orders writes {balance_usd, checked_at} every 60s. A route
  // whose own order ceiling exceeds that balance is refused pre-charge by
  // create-order, so listing it can only produce `provider_unreachable` —
  // copy which does NOT say "we are out of float" and reads to the user as
  // the app being broken.
  //
  // FAILS OPEN on a missing or stale reading, deliberately matching
  // create-order's identical guard. A hide driven by a monitoring blip would
  // take the catalog down for a reason that is not real, which is worse than
  // what it prevents.
  const { data: healthRow } = await sb
    .from("app_config").select("value").eq("key", "smspva_health").maybeSingle();
  const health = healthRow?.value as { balance_usd?: number; checked_at?: string } | null;
  const healthFresh = !!health?.checked_at &&
    Date.now() - new Date(health.checked_at).getTime() < HEALTH_FRESH_MS;
  const balanceUsd = healthFresh && typeof health?.balance_usd === "number"
    ? health.balance_usd
    : null;

  // ── Guard 2: reservation collapse ─────────────────────────────────────
  // The provider-wide verdict. Counted on `smspva_number is not null`, i.e.
  // did the provider hand us a number at all — NOT on delivery.
  //
  // That choice is the whole point. This repo has twice built a gate on
  // delivery and measured user impatience instead: 59% of numbered orders are
  // cancelled by the user, so a delivery-based rate says more about the
  // waiting screen than about the provider (see the HeroSMS rollback that was
  // nearly triggered on exactly this error, and the delivery-collapse watchdog
  // that fired at "ZERO codes" while real delivery was ~73%). A reservation
  // either happened or it did not, it is decided in about one second, and the
  // user cannot influence it. It is the one clean provider-side signal.
  //
  // FAILS OPEN if the read errors — a DB hiccup must never hide the catalog.
  let reserveOrders = 0;
  let reserveOk = 0;
  let reserveCollapsed = false;
  let reserveReadFailed = false;
  {
    const since = new Date(Date.now() - RESERVE_LOOKBACK_DAYS * 86_400_000).toISOString();
    const { data: recent, error: rErr } = await sb
      .from("orders")
      .select("smspva_number")
      .eq("provider", "smspva")
      .gte("created_at", since);
    if (rErr || !recent) {
      reserveReadFailed = true;
      console.error("sync-prices: smspva reservation read failed", rErr?.message);
    } else {
      reserveOrders = recent.length;
      reserveOk = recent.filter((o) => o.smspva_number != null).length;
      reserveCollapsed = reserveOrders >= RESERVE_MIN_ORDERS &&
        (100 * reserveOk / reserveOrders) < RESERVE_MIN_PCT;
      if (reserveCollapsed) {
        console.error(
          `sync-prices: SMSPVA reservation collapse — ${reserveOk}/${reserveOrders} ` +
            `(${(100 * reserveOk / reserveOrders).toFixed(1)}%) over ${RESERVE_LOOKBACK_DAYS}d, ` +
            `below ${RESERVE_MIN_PCT}%. Hiding every SMSPVA route until it recovers.`,
        );
      }
    }
  }

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
  let hiddenUnaffordable = 0;   // route ceiling above the live SMSPVA balance
  let hiddenCollapsed = 0;      // hidden by the provider-wide reservation verdict
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

      // Serviceability, on top of the existing price/blocklist hides. Both are
      // recomputed every run from live data, so both un-hide on their own: the
      // upsert below flips `status` back to 'active' the moment the condition
      // clears. Nothing here is sticky.
      //
      // `credits` is retail (the STANDARD tier). A premium order is priced off
      // `premium_credits`, which is never below retail, so its ceiling is never
      // lower — testing retail is the narrower hide, and we only remove a route
      // when even its cheapest tier is unaffordable.
      const unaffordable = balanceUsd != null && orderCeilingUsd(credits) > balanceUsd;
      if (unaffordable) hiddenUnaffordable++;
      if (reserveCollapsed) hiddenCollapsed++;
      // SMSPVA_RETIRED wins over every other condition, and it is FIRST so it
      // cannot be reasoned around: a route the router will not select must not
      // be sellable, whatever its price, stock or margin says.
      const hide = SMSPVA_RETIRED || blocked.has(key) ||
        cents > MAX_WHOLESALE_CENTS || reserveCollapsed || unaffordable;

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
      // MUST run before `evidence`: it writes the flag that the three refreshes
      // read. Default-landed orders are the app's own pre-selection — the user
      // never chose the service, so the number was never submitted anywhere and
      // no code was ever requested; counting them measures our steering rather
      // than delivery. 2.0+ clients stamp `orders.from_default` themselves, but
      // 2.0 is still in review, so every order arriving today comes from a 1.9
      // client and lands NULL. This is the bridge until that build ages out —
      // it is a permanent no-op on client-stamped rows, so it is safe to leave
      // running past adoption. See migration 20260808180000.
      ["defaultLanded", "stamp_default_landed"],
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
    // Why SMSPVA routes are (or are not) on the shelf this run. Reported rather
    // than logged because "the hide silently stopped applying" and "the hide is
    // working" are otherwise indistinguishable from the outside — the same
    // reason set_esim_paused() returns plans_changed/plans_active.
    smspvaServiceability: {
      balanceUsd,
      healthFresh,
      reserveLookbackDays: RESERVE_LOOKBACK_DAYS,
      reserveOrders,
      reserveOk,
      reservePct: reserveOrders > 0
        ? Math.round(1000 * reserveOk / reserveOrders) / 10
        : null,
      reserveMinOrders: RESERVE_MIN_ORDERS,
      reserveMinPct: RESERVE_MIN_PCT,
      reserveCollapsed,
      reserveReadFailed,
      hiddenUnaffordable,
      hiddenCollapsed,
      unhidesWhen: reserveCollapsed
        ? `reservation rate returns to >= ${RESERVE_MIN_PCT}%, or the ${RESERVE_LOOKBACK_DAYS}d window falls below ${RESERVE_MIN_ORDERS} orders (automatic re-probe)`
        : "n/a — not collapsed",
    },
    maintenance,
    servicesWithoutPricesCount: servicesWithoutPrices.length,
    servicesWithoutPrices: servicesWithoutPrices.slice(0, 40),
    unknownServiceCodes: [...unknownServiceCodes].slice(0, 40),
    formula: `credits = max(${MIN_CREDITS}, ceil(price / ${CREDIT_DIVISOR}))`,
  });
});
