// Sync HeroSMS wholesale cost + real-SIM stock onto the routes it serves, and
// make availability honest.
//
// AS OF 2026-07-31 THIS FUNCTION ALSO SETS `retail_credits`, at a HeroSMS-only
// divisor of 0.025 (12x). It is therefore a retail-setting sync and carries the
// ratchet, like sync-prices and sync-esim-plans. sync-prices still skips
// non-SMSPVA rows, so the two never write the same route's price.
//
// Until that change every HeroSMS route was SOLD at the price SMSPVA's
// wholesale implied while being BOUGHT at HeroSMS's — a mean realised margin of
// 97x, a median retail of 15 credits against a policy price of 6, and the
// single biggest reason a new user with the 3-credit signup grant could reach
// only 506 of 12,564 active routes.
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
import { getPricesForService, getOffers, type HeroPrice, getNumbersStatus, getOperators } from "../_shared/herosms.ts";

// ── Pricing (added 2026-07-31; this function now SETS retail) ───────────────
//
// HeroSMS is priced at 12×, SMSPVA stays at 6×. That asymmetry is deliberate
// and was measured, not assumed. Applying 0.025 globally — the original plan —
// also doubles every SMSPVA route: SMSPVA is 7,757 of the 12,564 active routes
// and currently the BETTER-delivering provider (34% vs HeroSMS 21% on orders
// that got a number), and doubling it takes its 3-credit reach from 729 routes
// to 16. That is the same shape as the 2026-07-25 divisor change, which cut
// 1-credit reach from 971 routes to 24 and produced a 24h funnel of 11 signups
// → 2 orders → 0 codes → 0 purchases. Modelled over the live catalog:
//
//   option                        reach @3cr   routes in the 2-8cr band
//   hero 12x / smspva 6x  (this)   1,235→2,259    3,692→4,999
//   uniform 12x                    1,235→1,546    3,692→3,848
//   status quo                         1,235          3,692
//
// (2-8cr is where measured delivery is 46-59%; 9+cr is 19%, 1cr is 18%.)
//
// LOCKSTEP, and it is the whole ballgame: create-order's ceiling is
// `credits * NET_USD_PER_CREDIT / MIN_MARGIN`, which must equal this divisor
// EXACTLY. 0.30/12 = 0.025. create-order therefore resolves MIN_MARGIN per
// provider — see marginFor() there. Change one without the other and you either
// refuse honest routes at checkout (ceiling too low) or leak margin.
const CREDIT_DIVISOR = 0.025;
const MIN_CREDITS = 1;
const MAX_CREDITS = 999;

/** Weight on the new quote when the cost FALLS. Matches sync-prices. */
const SMOOTH_ALPHA = 0.5;

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

/** cents → credits at the HeroSMS divisor. Mirrors sync-prices' priceToCredits
 *  exactly, including the clamps, so the two providers round identically. */
function priceToCredits(priceUsd: number): number {
  if (!Number.isFinite(priceUsd) || priceUsd <= 0) return MIN_CREDITS;
  const raw = Math.ceil(priceUsd / CREDIT_DIVISOR);
  return Math.max(MIN_CREDITS, Math.min(MAX_CREDITS, raw));
}

/** Pace between provider calls. There is NO documented per-second limit (25/25
 *  rapid calls returned 200 on 2026-07-30), but the account has a
 *  CHANNELS_LIMIT and we have no reason to hammer a vendor we just met. */
const CALL_SPACING_MS = 150;
/** Service codes per /activations/offers request. 10 codes returned 1,554
 *  (service,country) pairs, so 40 is comfortably inside a sane response size
 *  while cutting ~148 sequential calls to ~4. */
const OFFERS_CHUNK = 40;
/** Longer than the handler_api default: one offers call does the work of forty. */
const OFFERS_TIMEOUT_MS = 30_000;

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
    // Keep this a single string LITERAL — supabase-js parses it with template
    // literal types, so splitting it across a `+` concatenation collapses the
    // row type to GenericStringError and every field access below fails to
    // type-check.
    .from("routes").select("service_id, country_id, status, retail_credits, herosms_real_operator, herosms_real_operators, herosms_real_count, herosms_smoothed_cost_cents")
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

  // ── Real-carrier resolution, chunked across runs ─────────────────────────
  //
  // Candidates come from `getOperators` (no api key needed) minus a VoIP
  // denylist, rather than a hand-written list per country — there are 69 of
  // them. Probing is ~8 operators per country at CALL_SPACING_MS, so all 69 in
  // one run would blow the ~150s edge budget; a cursor walks a slice per hourly
  // run and the catalog converges over a few hours. Same shape as
  // sync-smspva-operators, which paginates 12 countries per run.
  const COUNTRIES_PER_RUN = 8;

  const { data: voipCfgRow } = await sb
    .from("app_config").select("value").eq("key", "voip_operators").maybeSingle();
  const voipOperators = new Set<string>(
    (Array.isArray(voipCfgRow?.value) ? voipCfgRow.value as string[] : []).map((x) => x.toLowerCase()),
  );

  const { data: curRow } = await sb
    .from("app_config").select("value").eq("key", "herosms_operator_cursor").maybeSingle();
  const cursor = Number(curRow?.value ?? 0) || 0;

  // ⚠️ SORTED, because the cursor is POSITIONAL. The query above has no
  // `order by`, so Postgres may return these rows in a different order on any
  // run — and a positional cursor into a list that reorders skips some
  // countries permanently while re-probing others, so those routes never get a
  // `herosms_real_count` and are silently sold as VoIP-only forever.
  // `sync-smspva-operators` gets this right by ordering on id; this did not.
  const heroCountries = (countries ?? [])
    .filter((c) => c.herosms_id != null)
    .sort((a, b) => String(a.id).localeCompare(String(b.id)));
  const slice = heroCountries.slice(cursor, cursor + COUNTRIES_PER_RUN);
  const nextCursor = cursor + COUNTRIES_PER_RUN >= heroCountries.length
    ? 0 : cursor + COUNTRIES_PER_RUN;

  // heroServiceCode -> every real carrier WITH STOCK, most stock first, per
  // country id. Absent country = not probed THIS run; stored values untouched.
  //
  // All of them, not just the maximum. The probe already measures each one;
  // keeping only the best meant create-order pinned a single carrier and, when
  // it was dry, fell back to the UNPINNED pool — which is overwhelmingly VoIP
  // (badoo/us: verizon 14,224 real against textnow 458,985 VoIP). getNumberV2's
  // `operator` param takes a comma-separated list, so naming all of them draws
  // on the union of real stock instead, which is better on quality AND on
  // availability than either the single pin or the fallback.
  const realOperator = new Map<string, Map<string, { op: string; n: number }[]>>();
  let operatorProbes = 0;
  for (const c of slice) {
    const ops = (await getOperators(c.herosms_id as number))
      .filter((o) => !voipOperators.has(o.toLowerCase()));
    await sleep(CALL_SPACING_MS);
    if (!ops.length) continue;              // could not ask, or genuinely none
    const best = new Map<string, { op: string; n: number }[]>();
    let anyOk = false;
    for (const op of ops) {
      const st = await getNumbersStatus(c.herosms_id as number, op);
      operatorProbes++;
      await sleep(CALL_SPACING_MS);
      if (!st) continue;                    // this operator failed; others may answer
      anyOk = true;
      for (const [code, n] of Object.entries(st)) {
        if (n <= 0) continue;               // absent/zero = no stock on that carrier
        (best.get(code) ?? best.set(code, []).get(code)!).push({ op, n });
      }
    }
    // Most stock first, so the head of the list is still the single best
    // carrier — `herosms_real_operator` keeps its exact previous meaning and
    // the strict premium pin is unchanged.
    for (const list of best.values()) list.sort((a, b) => b.n - a.n);
    if (anyOk) realOperator.set(c.id as string, best);
  }

  // Whether a Real-SIM-ONLY route may be SOLD yet. Client-first, exactly like
  // the two deferred column revokes.
  //
  // The released build (1.5 / build 18) has no `real_sim_only` in its Route
  // model, so it renders the Standard chip AND preselects it (`checkoutPremium`
  // defaults to false; `defaultPremium` ships in build 19). create-order then
  // refuses with `real_sim_required` — a code that build has no case for — so
  // the user reads the generic 409 copy, "Not available right now. Try a
  // different option.", on facebook/instagram/whatsapp, i.e. ~50% of order
  // volume. Worse, that copy steers them to another COUNTRY, which is likely
  // another real-SIM-only route, while the Real SIM chip that would have
  // worked sits unexplained on the same screen. No money is lost (the refusal
  // precedes begin_order) — it is purely a dead-ended funnel.
  //
  // So until build 19 is adopted these stay hidden, which is exactly the state
  // they were in before the tier existed and which was deliberate. Flip this to
  // true then; it is a config write, not a deploy. Absent key => false, so it
  // fails to the safe side.
  const { data: rsoCfg } = await sb
    .from("app_config").select("value").eq("key", "real_sim_only_sellable").maybeSingle();
  const realSimOnlySellable = rsoCfg?.value === true;

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

  // Prefer /activations/offers: it reports the price stock ACTUALLY exists at,
  // where getPrices reports a default price that on 4% of routes nothing can be
  // bought at (and that is dearer than the real cheapest on 71%). See getOffers'
  // header for the apple/Turkey case that made this urgent.
  //
  // It is also many fewer calls — one request covered 1,554 (service,country)
  // pairs for 10 services — which matters because ~148 sequential getPrices
  // fetches on a key shared with the minutely poller is most of our rate-limit
  // exposure, and this IP has been Cloudflare-blocked once already.
  //
  // Chunked rather than one giant request: the URL grows with every code, and a
  // single failure should cost one chunk, not the catalog.
  let viaOffers = 0, viaGetPrices = 0, offersTruncated = 0;
  const offered = new Map<string, Record<string, HeroPrice>>();
  const allCodes = [...servicesByCode.keys()];
  for (let i = 0; i < allCodes.length; i += OFFERS_CHUNK) {
    const chunk = allCodes.slice(i, i + OFFERS_CHUNK);
    const res = await getOffers(chunk, OFFERS_TIMEOUT_MS);
    await sleep(CALL_SPACING_MS);
    if (res == null) continue; // fall through to getPrices for this chunk
    if (res.truncated) {
      // hasMore with no documented way to ask for page 2. Treat the whole chunk
      // as unanswered rather than acting on a partial page — a missing code here
      // would otherwise be indistinguishable from "HeroSMS does not serve it".
      offersTruncated += chunk.length;
      console.warn(`sync-herosms: offers reported hasMore for ${chunk.length} codes — falling back per service`);
      continue;
    }
    for (const [code, byCountry] of Object.entries(res.byCode)) {
      if (Object.keys(byCountry).length > 0) offered.set(code, byCountry);
    }
  }

  for (const [code, serviceIds] of servicesByCode) {
    let byCountry = offered.get(code) ?? null;
    if (byCountry) {
      viaOffers++;
    } else {
      // Fallback, unchanged: the older, coarser price view. Still correct for
      // routes whose default price does have stock, which is most of them.
      try {
        byCountry = await getPricesForService(code);
      } catch (_e) { byCountry = null; }
      if (byCountry && Object.keys(byCountry).length > 0) viaGetPrices++;
      await sleep(CALL_SPACING_MS);
    }

    if (!byCountry || Object.keys(byCountry).length === 0) {
      codesFailed++; failedCodes.push(code);
      continue;
    }
    codesOk++;
    for (const [heroCountryId, row] of Object.entries(byCountry)) {
      const ourCountry = countryByHeroId.get(heroCountryId);
      if (!ourCountry) continue;
      for (const sid of serviceIds) priced.set(`${sid}|${ourCountry}`, row);
    }
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
    herosms_real_operator: string | null; herosms_real_operators: string | null;
    herosms_real_count: number | null;
    premium_credits: number | null; real_sim_only: boolean;
    herosms_smoothed_cost_cents: number | null; retail_credits: number | null;
  };
  const updates: Row[] = [];
  let unfulfillable = 0, tooExpensive = 0, blockedCount = 0, sellable = 0, physical = 0;
  let voipOnly = 0, realOnly = 0, withRealTier = 0, realOnlyGated = 0, repriced = 0;

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
    else if (Math.round(hit.cost * 100) > MAX_WHOLESALE_CENTS) { status = "hidden"; tooExpensive++; }
    else { status = "active"; sellable++; if (hit.physicalCount > 0) physical++; }

    // Real-carrier resolution is chunked, so a country not probed THIS run must
    // keep whatever it already had rather than being reset to null.
    const probed = realOperator.has(r.country_id as string);
    const realList = probed ? realOperator.get(r.country_id as string)!.get(code ?? "") : undefined;
    const realHit = realList?.[0];
    const realOp = probed ? (realHit?.op ?? null) : (r.herosms_real_operator as string | null);
    // Comma-joined, no spaces — the exact wire form getNumberV2's `operator`
    // param documents ("tele2,beeline"), so create-order can pass it straight
    // through with no reformatting.
    const realOps = probed
      ? (realList && realList.length ? realList.map((x) => x.op).join(",") : null)
      : (r.herosms_real_operators as string | null);
    // 0, not null, when probed and nothing found: `herosms_real_count is null`
    // is what distinguishes "never looked" from "looked, none there".
    const realN  = probed ? (realHit?.n ?? 0) : (r.herosms_real_count as number | null);

    // Services that reject VoIP are sold ONLY as Real SIM. They used to be
    // hidden outright when they had no real stock, which rendered 62 routes as
    // "Unavailable" for inventory we can in fact serve on a named carrier.
    const strict = voipStrict.has(r.service_id as string);
    const realOnlyHere = strict && realOp != null;
    if (realOnlyHere) realOnly++;
    // A VoIP-rejecting service with no real carrier genuinely cannot be served,
    // so it stays hidden — but ONLY once we have actually looked. Carrier
    // resolution is chunked across ~9 hourly runs, and hiding on "not probed
    // yet" briefly took facebook/instagram/whatsapp from 62 hidden routes to
    // 185, i.e. it punished the highest-volume services for our own backlog.
    const carrierKnown = realN != null;
    if (strict && realOp == null && carrierKnown && status === "active") {
      status = "hidden"; voipOnly++;
    }
    // Sellable only once a client exists that can express "Standard is not an
    // option here" — see realSimOnlySellable above. `real_sim_only` is still
    // written either way, so flipping the flag alone brings them live.
    if (realOnlyHere && !realSimOnlySellable && status === "active") {
      status = "hidden"; realOnlyGated++;
    }

    // ── Price it ───────────────────────────────────────────────────────────
    // Until 2026-07-31 this function deliberately left `retail_credits` alone,
    // so every HeroSMS route still carried the price SMSPVA's wholesale implied
    // while being BOUGHT at HeroSMS's. Measured across 4,807 active routes that
    // was a mean realised margin of 97× and a median retail of 15 credits for
    // inventory whose policy price is 6 — which is the single biggest reason a
    // new user with the 3-credit grant could reach only 506 routes.
    //
    // RATCHET, not a symmetric EWMA: a RISE applies immediately and only FALLS
    // are damped. Averaging a rise against yesterday's cheaper price sets retail
    // below what we are about to pay — that shipped once on sync-prices and put
    // 4,384 routes under wholesale in one run.
    const prevSmoothed = r.herosms_smoothed_cost_cents as number | null;
    const rawCents = hit ? Math.round(hit.cost * 100) : null;
    const smoothedCents = rawCents == null
      ? prevSmoothed
      : prevSmoothed == null || rawCents > prevSmoothed
        ? rawCents
        : Math.round(SMOOTH_ALPHA * rawCents + (1 - SMOOTH_ALPHA) * prevSmoothed);

    // Keep the existing price when this run could not quote the route: a
    // transient fetch failure must never reprice the catalog to a guess. Routes
    // whose code failed were already `continue`d above; this covers a code that
    // fetched fine but returned no row for this country.
    const retail = smoothedCents != null
      ? priceToCredits(smoothedCents / 100)
      : (r.retail_credits as number | null);
    if (smoothedCents != null && retail !== (r.retail_credits as number | null)) repriced++;

    // +20% uplift, floored at the standard price so the tier can never be the
    // cheaper of the two. Null when there is no carrier to pin: `create-order`
    // and the checkout chips both key off this being non-null.
    //
    // Derived from the retail computed just above, NOT from the stored one —
    // otherwise a repriced route would keep a premium price anchored to the old
    // standard, and the "+20%" chip would read as 3x on screen.
    const premium = realOp != null && retail != null
      ? Math.max(retail, Math.ceil(retail * 1.2))
      : null;
    if (premium != null) withRealTier++;

    updates.push({
      service_id: r.service_id as string,
      country_id: r.country_id as string,
      herosms_cost_cents: hit ? Math.round(hit.cost * 100) : null,
      herosms_physical_count: hit?.physicalCount ?? null,
      herosms_total_count: hit?.count ?? null,
      herosms_checked_at: nowIso,
      status,
      herosms_real_operator: realOp,
      herosms_real_operators: realOps,
      herosms_real_count: realN,
      premium_credits: premium,
      real_sim_only: realOnlyHere,
      herosms_smoothed_cost_cents: smoothedCents,
      retail_credits: retail,
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

  // Advance only after the writes landed, so a failed run re-probes the same
  // slice next hour instead of skipping it.
  const { error: curErr } = await sb.from("app_config")
    .upsert({ key: "herosms_operator_cursor", value: nextCursor }, { onConflict: "key" });
  if (curErr) console.error(`sync-herosms: cursor write failed: ${curErr.message}`);

  const result = {
    ok: true,
    elapsed_ms: Date.now() - startedAt,
    codes_ok: codesOk,
    codes_failed: codesFailed,
    failed_codes: failedCodes.slice(0, 20),
    // How each code got priced. `via_getprices` climbing towards codes_ok means
    // the offers endpoint is degrading and we are silently back on the phantom
    // default price — worth noticing before it costs another paying customer.
    via_offers: viaOffers,
    via_getprices: viaGetPrices,
    offers_truncated_codes: offersTruncated,
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
    real_sim_only_routes: realOnly,
    // Held back because the released client cannot express the constraint.
    // Should fall to 0 the moment `real_sim_only_sellable` is flipped true.
    hidden_real_sim_only_gated: realOnlyGated,
    real_sim_only_sellable: realSimOnlySellable,
    routes_with_real_tier: withRealTier,
    // Routes whose retail_credits CHANGED this run. Expect a large first number
    // (the whole HeroSMS catalog moving off SMSPVA-derived prices) and near-zero
    // afterwards — a persistently high count means the ratchet is oscillating.
    repriced,
    credit_divisor: CREDIT_DIVISOR,
    operator_probes: operatorProbes,
    countries_probed: slice.map((c) => c.id),
    cursor_next: nextCursor,
    voip_strict_services: [...voipStrict],
  };
  console.log(`sync-herosms ${JSON.stringify(result)}`);
  return json(result);
});
