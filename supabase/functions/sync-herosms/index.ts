// Sync HeroSMS wholesale cost + real-SIM stock onto the routes it serves, and
// make availability honest.
//
// WHAT THIS DELIBERATELY DOES NOT DO: touch `retail_credits`. Repricing is a
// separate, owner-gated decision. This function exists to stop us SELLING WHAT
// WE CANNOT DELIVER, which is a correctness bug, not a pricing one.
//
// The bug: after the 2026-07-30 cutover, HeroSMS routes still carry SMSPVA's
// frozen `last_cost_cents` (sync-prices skips non-SMSPVA rows by design). For
// the ~16% of HeroSMS routes HeroSMS cannot serve at all, `livePriceUsd`
// returns null, create-order's graceful degrade falls back to that stale SMSPVA
// cost, the margin gate PASSES, the reservation then fails NO_NUMBERS — and the
// user is charged, refunded, and told to "try another country or service".
//
// Deploy with --no-verify-jwt (cron calls it with x-cron-secret, no Authorization
// header). Schedule alongside sync-prices.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import { getPricesForService, type HeroPrice } from "../_shared/herosms.ts";

/** Same ceiling as sync-prices: above this the route is not worth selling at
 *  any credit price we offer. Kept in lockstep with MAX_WHOLESALE_CENTS there. */
const MAX_WHOLESALE_CENTS = 750;

/** Pace between provider calls. There is NO documented per-second limit (25/25
 *  rapid calls returned 200 on 2026-07-30), but the account has a
 *  CHANNELS_LIMIT and we have no reason to hammer a vendor we just met. */
const CALL_SPACING_MS = 150;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

Deno.serve(async (req) => {
  const pre = handleCors(req);
  if (pre) return pre;

  const secret = Deno.env.get("CRON_SECRET");
  if (!secret || req.headers.get("x-cron-secret") !== secret) {
    return json({ error: "forbidden" }, { status: 403 });
  }

  const sb = admin();
  const startedAt = Date.now();

  // ── Load the HeroSMS-owned catalog ────────────────────────────────────────
  const { data: services, error: svcErr } = await sb
    .from("services").select("id, herosms_code").not("herosms_code", "is", null);
  if (svcErr) return json({ error: "services_read_failed", detail: svcErr.message }, { status: 500 });

  const { data: countries, error: ctyErr } = await sb
    .from("countries").select("id, herosms_id").not("herosms_id", "is", null);
  if (ctyErr) return json({ error: "countries_read_failed", detail: ctyErr.message }, { status: 500 });

  // Destructure EVERY read error. A silently-empty routes list here would make
  // the stale-guard below hide the entire HeroSMS catalog.
  const { data: routes, error: rtErr } = await sb
    .from("routes").select("service_id, country_id, status")
    .eq("provider", "herosms");
  if (rtErr) return json({ error: "routes_read_failed", detail: rtErr.message }, { status: 500 });
  if (!routes?.length) return json({ error: "no_herosms_routes" }, { status: 500 });

  const { data: cfg } = await sb
    .from("app_config").select("value").eq("key", "blocked_routes").maybeSingle();
  const blocked = new Set<string>(
    Array.isArray(cfg?.value) ? (cfg.value as string[]) : [],
  );

  // Services that reject VoIP numbers (Meta's properties). Same shape and role
  // as `blocked_routes`: a hand-maintained list, editable without a deploy.
  // Empty it to roll the VoIP rule back — the next run re-activates everything.
  const { data: voipCfg } = await sb
    .from("app_config").select("value").eq("key", "voip_strict_services").maybeSingle();
  const voipStrict = new Set<string>(
    Array.isArray(voipCfg?.value) ? (voipCfg.value as string[]) : [],
  );

  // HeroSMS numeric country id -> our country id. Several of our countries can
  // never collide here: the mapping is 1:1 and was built from HeroSMS's own
  // getCountries.
  const countryByHeroId = new Map<string, string>();
  for (const c of countries ?? []) countryByHeroId.set(String(c.herosms_id), c.id as string);

  // One provider call per DISTINCT code — three codes (wx, hb, zh) are shared
  // by two of our services each, so keying by code and fanning out afterwards
  // avoids paying for the same fetch twice.
  const servicesByCode = new Map<string, string[]>();
  for (const s of services ?? []) {
    const code = s.herosms_code as string;
    (servicesByCode.get(code) ?? servicesByCode.set(code, []).get(code)!).push(s.id as string);
  }

  // ── Fetch ────────────────────────────────────────────────────────────────
  /** `${service_id}|${country_id}` -> price row */
  const priced = new Map<string, HeroPrice>();
  let codesOk = 0, codesFailed = 0;
  const failedCodes: string[] = [];

  for (const [code, serviceIds] of servicesByCode) {
    let byCountry: Record<string, HeroPrice> = {};
    try {
      byCountry = await getPricesForService(code);
    } catch (_e) { /* treated as failure below */ }

    if (Object.keys(byCountry).length === 0) {
      codesFailed++; failedCodes.push(code);
      await sleep(CALL_SPACING_MS);
      continue;
    }
    codesOk++;
    for (const [heroCountryId, row] of Object.entries(byCountry)) {
      const ourCountry = countryByHeroId.get(heroCountryId);
      if (!ourCountry) continue;
      for (const sid of serviceIds) priced.set(`${sid}|${ourCountry}`, row);
    }
    await sleep(CALL_SPACING_MS);
  }

  // A total wipeout means the provider or the key is broken. Writing nothing is
  // right; hiding the catalog on the back of it would be catastrophic.
  if (codesOk === 0) {
    console.error(`sync-herosms: every one of ${codesFailed} codes failed — aborting without writes`);
    return json({ error: "all_price_fetches_failed", codes: codesFailed }, { status: 502 });
  }

  // ── Decide each route's cost + availability ──────────────────────────────
  const nowIso = new Date().toISOString();
  type Row = {
    service_id: string; country_id: string;
    herosms_cost_cents: number | null; herosms_physical_count: number | null;
    herosms_total_count: number | null; herosms_checked_at: string; status: string;
  };
  const updates: Row[] = [];
  let unfulfillable = 0, tooExpensive = 0, blockedCount = 0, sellable = 0, physical = 0;
  let voipOnly = 0;

  for (const r of routes) {
    const key = `${r.service_id}|${r.country_id}`;
    const hit = priced.get(key);

    // Only judge routes whose CODE we actually fetched this run. A failed fetch
    // must not be read as "HeroSMS does not serve this".
    const code = (services ?? []).find((s) => s.id === r.service_id)?.herosms_code as string | undefined;
    if (!hit && code && failedCodes.includes(code)) continue;

    let status: string;
    if (!hit || hit.count <= 0) { status = "hidden"; unfulfillable++; }
    else if (blocked.has(key)) { status = "hidden"; blockedCount++; }
    // Services that reject VoIP ranges cannot be delivered on a route with no
    // real SIMs, whatever the stock number says. Measured 2026-07-30: facebook
    // 16.3% and instagram 8.3% over 30 days — together ~50% of all order volume
    // — while 20 of facebook's 69 routes and 21 of instagram's have zero
    // physical stock. This is "we cannot deliver this", the same category as
    // `blocked_routes`, NOT a judgement on measured performance — so it does
    // not contradict the standing "label, don't hide" rule, which governs
    // delivery outcomes we have actually observed.
    //
    // `hit` is non-null here (the first branch caught that), so a zero is a
    // real reading and not a missing one. Routes whose service failed to price
    // this run were skipped above and never reach this ladder.
    else if (voipStrict.has(r.service_id as string) && hit.physicalCount <= 0) {
      status = "hidden"; voipOnly++;
    }
    else if (Math.round(hit.cost * 100) > MAX_WHOLESALE_CENTS) { status = "hidden"; tooExpensive++; }
    else { status = "active"; sellable++; if (hit.physicalCount > 0) physical++; }

    updates.push({
      service_id: r.service_id as string,
      country_id: r.country_id as string,
      herosms_cost_cents: hit ? Math.round(hit.cost * 100) : null,
      herosms_physical_count: hit?.physicalCount ?? null,
      herosms_total_count: hit?.count ?? null,
      herosms_checked_at: nowIso,
      status,
    });
  }

  // ── Write, chunked ───────────────────────────────────────────────────────
  let written = 0;
  const CHUNK = 500;
  for (let i = 0; i < updates.length; i += CHUNK) {
    const slice = updates.slice(i, i + CHUNK);
    const { error } = await sb.from("routes").upsert(slice, { onConflict: "service_id,country_id" });
    if (error) {
      console.error(`sync-herosms: chunk ${i} write failed: ${error.message}`);
      return json({
        error: "write_failed", detail: error.message, written,
        codes_ok: codesOk, codes_failed: codesFailed,
      }, { status: 500 });
    }
    written += slice.length;
  }

  const result = {
    ok: true,
    elapsed_ms: Date.now() - startedAt,
    codes_ok: codesOk,
    codes_failed: codesFailed,
    failed_codes: failedCodes.slice(0, 20),
    routes_seen: routes.length,
    routes_written: written,
    sellable,
    with_physical_sims: physical,
    hidden_unfulfillable: unfulfillable,
    hidden_over_ceiling: tooExpensive,
    hidden_blocked: blockedCount,
    // Counted separately so the VoIP rule's blast radius is visible per run —
    // a sudden jump means either the strict list grew or HeroSMS lost real-SIM
    // stock, and those need very different responses.
    hidden_voip_only: voipOnly,
    voip_strict_services: [...voipStrict],
  };
  console.log(`sync-herosms ${JSON.stringify(result)}`);
  return json(result);
});
