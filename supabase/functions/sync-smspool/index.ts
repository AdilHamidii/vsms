// SMSPool catalog sync (primary provider). Two phases per run:
//   A) Bulk price/availability — ONE /request/pricing call covers the whole
//      in-stock matrix; we upsert every combo that maps to our catalog as
//      provider='smspool'. Fast + complete every run.
//   B) success_rate enrichment — /request/pricing has no success_rate, so we
//      walk our smspool routes (popular services first) a bounded batch at a
//      time, calling /request/price, and store success_rate. Resumable via an
//      app_config cursor; fills in progressively.
//
// Cron-gated (x-cron-secret). Mirrors sync-prices' formula/EWMA/stale-guard.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import { allStock, listServices, listCountries } from "../_shared/smspool.ts";

const CREDIT_DIVISOR = 0.10;      // 10x markup; keep in lockstep with sync-prices
const MIN_CREDITS = 1;
const MAX_CREDITS = 999;
const MAX_WHOLESALE_CENTS = 400;  // hide absurdly-priced routes
const SMOOTH_ALPHA = 0.5;         // EWMA on wholesale cost
const UPDATE_FLOOR = 500;         // safety: don't revert stale routes on a thin run

// Priority services enriched first (by our service id). Known SMSPool ids.
const SERVICE_OVERRIDES: Record<string, number> = {
  leboncoin: 1363, instagram: 457, facebook: 329, whatsapp: 1012,
  google: 395, telegram: 907, "twitter-x": 41, tiktok: 104,
};

function priceToCredits(usd: number): number {
  if (!Number.isFinite(usd) || usd <= 0) return MIN_CREDITS;
  return Math.max(MIN_CREDITS, Math.min(MAX_CREDITS, Math.ceil(usd / CREDIT_DIVISOR)));
}
function validateCronSecret(req: Request): boolean {
  const h = req.headers.get("x-cron-secret");
  const e = Deno.env.get("CRON_SECRET");
  return !!h && !!e && h === e;
}

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;
  if (!validateCronSecret(req)) return json({ error: "unauthorized" }, { status: 401 });

  const sb = admin();
  const runStart = new Date().toISOString();

  // ── Our catalog
  const { data: services } = await sb.from("services").select("id, name, smspool_code");
  const { data: countries } = await sb.from("countries").select("id, name, smspool_code");
  if (!services || !countries) return json({ error: "catalog_load_failed" }, { status: 500 });

  // ── Bootstrap smspool_code mappings (idempotent).
  //    Countries: by lowercased name (robust across UK/GB etc.).
  //    Services: override map first, then exact lowercased name match.
  // Normalize names (lowercase + strip punctuation/spaces) so "Proton Mail" ==
  // "ProtonMail", "Mail.ru" == "MailRu", "Tencent QQ" == "Tencent / QQ", etc.
  const norm = (x: string) => x.toLowerCase().replace(/[^a-z0-9]/g, "");
  const [spServices, spCountries] = await Promise.all([listServices(), listCountries()]);
  // SMSPool bundles aliases into one name ("Uber / Postmates", "Amazon /
  // Amazon Web Services", "Battle.net / Blizzard"), so an exact-name match
  // silently missed them — 'uber' and 'amazon' sat unmapped for months and
  // vanished from the app the moment SMSPVA was retired. Index every alias
  // segment, keeping the first (canonical) claim on each key.
  const spSvcByName = new Map<string, number>();
  for (const s of spServices) {
    for (const part of [s.name, ...s.name.split(/[/(),]/)]) {
      const k = norm(part);
      if (k && !spSvcByName.has(k)) spSvcByName.set(k, s.ID);
    }
  }
  const spCtyByName = new Map<string, number>();
  for (const c of spCountries) spCtyByName.set(norm(c.name), c.ID);

  const svcMapUpserts: { id: string; smspool_code: string }[] = [];
  for (const s of services) {
    if (s.smspool_code) continue;
    // Try the override, then the service's display name, then its slug.
    const id = SERVICE_OVERRIDES[s.id]
      ?? spSvcByName.get(norm(s.name ?? ""))
      ?? spSvcByName.get(norm(s.id));
    if (id != null) svcMapUpserts.push({ id: s.id, smspool_code: String(id) });
  }
  const ctyMapUpserts: { id: string; smspool_code: string }[] = [];
  for (const c of countries) {
    if (c.smspool_code) continue;
    const id = spCtyByName.get(norm(c.name ?? ""));
    if (id != null) ctyMapUpserts.push({ id: c.id, smspool_code: String(id) });
  }
  for (const u of svcMapUpserts) await sb.from("services").update({ smspool_code: u.smspool_code }).eq("id", u.id);
  for (const u of ctyMapUpserts) await sb.from("countries").update({ smspool_code: u.smspool_code }).eq("id", u.id);

  // Refresh mappings after bootstrap. ourSvcToSp/ourCtyToSp go one way (for
  // per-combo /request/price); spToOurSvc/spToOurCty go the other (for the bulk
  // rows, which are keyed by SMSPool numeric id).
  const ourSvcToSp = new Map<string, number>();
  const spToOurSvc = new Map<number, string[]>();
  for (const s of services) {
    const code = s.smspool_code ?? svcMapUpserts.find((u) => u.id === s.id)?.smspool_code;
    if (!code) continue;
    const n = Number(code);
    ourSvcToSp.set(s.id, n);
    const arr = spToOurSvc.get(n);
    if (arr) arr.push(s.id); else spToOurSvc.set(n, [s.id]);
  }
  const ourCtyToSp = new Map<string, number>();
  const spToOurCty = new Map<number, string>();
  for (const c of countries) {
    const code = c.smspool_code ?? ctyMapUpserts.find((u) => u.id === c.id)?.smspool_code;
    if (!code) continue;
    const n = Number(code);
    ourCtyToSp.set(c.id, n);
    spToOurCty.set(n, c.id);
  }

  // ── Phase A: bulk price + AVAILABILITY.
  // /sms/all_stock is a strict superset of /request/pricing — the same
  // per-pool price matrix plus the inventory count. Without stock we were
  // listing routes SMSPool could not fill and only discovering it after
  // charging the user: those are the "no number available" failures, which
  // are ~54% of all paid attempts.
  const bulk = await allStock();
  if (bulk.length === 0) {
    return json({ error: "all_stock_failed" }, { status: 502 });
  }

  // Prior smoothed cost for EWMA.
  const { data: prevRows } = await sb.from("routes")
    .select("service_id, country_id, smoothed_cost_cents").eq("provider", "smspool");
  const prevSmoothed = new Map<string, number>();
  for (const r of prevRows ?? []) {
    if (r.smoothed_cost_cents != null) prevSmoothed.set(`${r.service_id}|${r.country_id}`, r.smoothed_cost_cents);
  }

  // Manually blocked combos (app_config 'blocked_routes' = ["service|country"]).
  // sync-prices honoured these but is no longer scheduled, so nothing enforced
  // them and every blocked route drifted back to 'active' — whatsapp|us was
  // live at 25 credits with 0 deliveries in 4 orders. Editable without a
  // redeploy; create-order should enforce this too as defence in depth.
  const { data: blkRow } = await sb
    .from("app_config").select("value").eq("key", "blocked_routes").maybeSingle();
  const blocked = new Set<string>(Array.isArray(blkRow?.value) ? (blkRow!.value as string[]) : []);

  // SMSPool lists one bulk row PER POOL, so a (service, country) can appear
  // many times. Track the cheapest AND priciest pool per combo: the cheapest
  // decides whether the combo is fillable under our wholesale ceiling at all,
  // but the PRICE must cover the priciest pool we'd accept — a purchase fills
  // from any pool (the quote doesn't bind it), so pricing from the cheapest
  // pool sold 1-credit numbers that filled at $0.79 (live, 2026-07-19).
  // Per combo, track the cheapest pool (fillability under the ceiling) and the
  // BEST AFFORDABLE pool — the priciest one ≤ MAX_WHOLESALE_CENTS. We price
  // from and purchase-pin to that pool: pool price tiers are quality tiers,
  // and the 3× sticker already pays for the good one.
  const pools = new Map<string, {
    minCents: number; bestCents: number; bestPool: string | null;
    stock: number; svcId: string; cty: string;
  }>();
  for (const row of bulk) {
    const ourSvcs = spToOurSvc.get(row.service);
    const ourCty = spToOurCty.get(row.country);
    if (!ourSvcs || !ourCty) continue;
    const price = parseFloat(row.price);
    if (!Number.isFinite(price) || price <= 0) continue;
    const cents = Math.round(price * 100);
    const affordable = cents <= MAX_WHOLESALE_CENTS;
    const poolId = row.pool != null ? String(row.pool) : null;
    // Only stock in pools we could actually buy from counts as availability —
    // inventory above our price ceiling can never fill our order.
    const usableStock = affordable && Number.isFinite(row.stock) ? Math.max(0, row.stock) : 0;
    for (const svcId of ourSvcs) {
      const k = `${svcId}|${ourCty}`;
      const ex = pools.get(k);
      if (!ex) {
        pools.set(k, {
          minCents: cents,
          bestCents: affordable ? cents : 0,
          bestPool: affordable ? poolId : null,
          stock: usableStock,
          svcId, cty: ourCty,
        });
      } else {
        ex.minCents = Math.min(ex.minCents, cents);
        ex.stock += usableStock;
        if (affordable && cents > ex.bestCents) { ex.bestCents = cents; ex.bestPool = poolId; }
      }
    }
  }
  let outOfStock = 0;
  const updates = [...pools.values()].map(({ minCents, bestCents, bestPool, stock, svcId, cty }) => {
    // Cost basis = the pool we will actually buy from. If no pool is under the
    // ceiling the combo is unfillable → hidden (record the cheapest for ops).
    const fillable = bestCents > 0 && stock > 0;
    if (bestCents > 0 && stock === 0) outOfStock++;
    const basis = fillable ? bestCents : minCents;
    const prev = prevSmoothed.get(`${svcId}|${cty}`);
    // Ratchet: cost rises reprice immediately (margin-safe); falls smooth in.
    const smoothed = prev == null || basis > prev
      ? basis
      : Math.round(SMOOTH_ALPHA * basis + (1 - SMOOTH_ALPHA) * prev);
    return {
      service_id: svcId, country_id: cty,
      retail_credits: priceToCredits(smoothed / 100),
      last_cost_cents: basis, smoothed_cost_cents: smoothed,
      smspool_pool: fillable ? bestPool : null,
      stock,
      provider: "smspool",
      status: fillable && !blocked.has(`${svcId}|${cty}`) ? "active" : "hidden",
      last_checked_at: runStart,
    };
  });

  let routesUpdated = 0;
  const CHUNK = 500;
  for (let i = 0; i < updates.length; i += CHUNK) {
    const { error } = await sb.from("routes").upsert(updates.slice(i, i + CHUNK), { onConflict: "service_id,country_id" });
    if (error) return json({ error: "upsert_failed", detail: error.message, partial: routesUpdated }, { status: 500 });
    routesUpdated += Math.min(CHUNK, updates.length - i);
  }

  // SMSPool-only (2026-07-20): stale smspool routes (out of stock this run)
  // are hidden, not handed back to SMSPVA — there is no fallback provider.
  let reverted = 0;
  if (routesUpdated >= UPDATE_FLOOR) {
    const { count } = await sb.from("routes").update({ status: "hidden" }, { count: "exact" })
      .eq("provider", "smspool")
      .eq("status", "active")
      .or(`last_checked_at.is.null,last_checked_at.lt."${runStart}"`);
    reverted = count ?? 0;
  }

  // ── Phase B REMOVED (2026-07-21).
  // This walked the catalog 120 combos/run calling /request/price to store
  // SMSPool's self-reported success_rate. It was pure waste, twice over:
  //   1. Phase C's first statement nulls success_rate for every smspool route,
  //      so every value Phase B wrote was deleted minutes later. The cursor had
  //      walked 3,720 combos and exactly 0 of them retained a rate.
  //   2. The number was meaningless anyway. SMSPool documents no definition,
  //      window or sample size for success_rate, and /request/price returns a
  //      PER-POOL figure only when passed a `pool` — which this never did, so
  //      the value described an unspecified pool. It reported 100% for
  //      facebook/ch while that route went 0-for-9 on real orders.
  // Net: ~2,880 API calls and ~42s of deliberate sleeping per day, for data we
  // delete and would not display. Observed rates (Phase C) are the only ones
  // we trust or show.
  // ── Phase C: override SMSPool's self-reported success_rate with what
  // actually happened on OUR orders, and auto-hide any route with proven
  // total failure. Runs LAST so it wins over phase A's stock-based status.
  // See migration 20260720003000 for the full rationale (live incident:
  // facebook/ch showed "100% success" while 9/9 real attempts failed).
  const { data: observedHidden } = await sb.rpc("refresh_smspool_observed_success");

  // ── Phase D: keep service visibility in step with real coverage. A service
  // is shown iff it has at least one bookable route. Without this, anything
  // hidden during the SMSPool-only cutover stayed hidden forever even after
  // its routes came back (how 'uber' disappeared once it was re-mapped).
  const { data: visibilityChanged } = await sb.rpc("sync_service_visibility");

  return json({
    routesUpdated, reverted, outOfStock,
    servicesMapped: svcMapUpserts.length, countriesMapped: ctyMapUpserts.length,
    bulkRows: bulk.length,
    observedHidden: observedHidden ?? 0,
    visibilityChanged: visibilityChanged ?? 0,
  });
});
