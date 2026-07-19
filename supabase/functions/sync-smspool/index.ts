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
import { getPricingBulk, getPrice, listServices, listCountries } from "../_shared/smspool.ts";

const CREDIT_DIVISOR = 0.10;      // 10x markup; keep in lockstep with sync-prices
const MIN_CREDITS = 1;
const MAX_CREDITS = 999;
const MAX_WHOLESALE_CENTS = 400;  // hide absurdly-priced routes
const SMOOTH_ALPHA = 0.5;         // EWMA on wholesale cost
const UPDATE_FLOOR = 500;         // safety: don't revert stale routes on a thin run
const ENRICH_BATCH = 120;         // success_rate calls per run
const ENRICH_PACE_MS = 350;

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
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

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
  const spSvcByName = new Map<string, number>();
  for (const s of spServices) spSvcByName.set(norm(s.name), s.ID);
  const spCtyByName = new Map<string, number>();
  for (const c of spCountries) spCtyByName.set(norm(c.name), c.ID);

  const svcMapUpserts: { id: string; smspool_code: string }[] = [];
  for (const s of services) {
    if (s.smspool_code) continue;
    const id = SERVICE_OVERRIDES[s.id] ?? spSvcByName.get(norm(s.name ?? ""));
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

  // ── Phase A: bulk price/availability.
  const bulk = await getPricingBulk();
  if (!Array.isArray(bulk) || bulk.length === 0) {
    return json({ error: "pricing_bulk_failed", got: JSON.stringify(bulk).slice(0, 200) }, { status: 502 });
  }

  // Prior smoothed cost for EWMA.
  const { data: prevRows } = await sb.from("routes")
    .select("service_id, country_id, smoothed_cost_cents").eq("provider", "smspool");
  const prevSmoothed = new Map<string, number>();
  for (const r of prevRows ?? []) {
    if (r.smoothed_cost_cents != null) prevSmoothed.set(`${r.service_id}|${r.country_id}`, r.smoothed_cost_cents);
  }

  // SMSPool lists one bulk row PER POOL, so a (service, country) can appear
  // many times. Track the cheapest AND priciest pool per combo: the cheapest
  // decides whether the combo is fillable under our wholesale ceiling at all,
  // but the PRICE must cover the priciest pool we'd accept — a purchase fills
  // from any pool (the quote doesn't bind it), so pricing from the cheapest
  // pool sold 1-credit numbers that filled at $0.79 (live, 2026-07-19).
  const pools = new Map<string, { minCents: number; maxCents: number; svcId: string; cty: string }>();
  for (const row of bulk) {
    const ourSvcs = spToOurSvc.get(row.service);
    const ourCty = spToOurCty.get(row.country);
    if (!ourSvcs || !ourCty) continue;
    const price = parseFloat(row.price);
    if (!Number.isFinite(price) || price <= 0) continue;
    const cents = Math.round(price * 100);
    for (const svcId of ourSvcs) {
      const k = `${svcId}|${ourCty}`;
      const ex = pools.get(k);
      if (!ex) pools.set(k, { minCents: cents, maxCents: cents, svcId, cty: ourCty });
      else {
        ex.minCents = Math.min(ex.minCents, cents);
        ex.maxCents = Math.max(ex.maxCents, cents);
      }
    }
  }
  const updates = [...pools.values()].map(({ minCents, maxCents, svcId, cty }) => {
    // Cost basis = worst fill we'd allow (create-order's max_price cap blocks
    // anything above credits×10¢ ≥ basis, so ≥3× margin holds for every fill).
    const basis = Math.min(maxCents, MAX_WHOLESALE_CENTS);
    const prev = prevSmoothed.get(`${svcId}|${cty}`);
    // Ratchet: cost rises reprice immediately (margin-safe); falls smooth in.
    const smoothed = prev == null || basis > prev
      ? basis
      : Math.round(SMOOTH_ALPHA * basis + (1 - SMOOTH_ALPHA) * prev);
    return {
      service_id: svcId, country_id: cty,
      retail_credits: priceToCredits(smoothed / 100),
      last_cost_cents: basis, smoothed_cost_cents: smoothed,
      provider: "smspool",
      status: minCents > MAX_WHOLESALE_CENTS ? "hidden" : "active",
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

  // Hand stale smspool routes (out of stock this run) back to SMSPVA so its sync
  // re-owns/re-prices them; fulfilment also falls back to smspva at reserve time.
  let reverted = 0;
  if (routesUpdated >= UPDATE_FLOOR) {
    const { count } = await sb.from("routes").update({ provider: "smspva" }, { count: "exact" })
      .eq("provider", "smspool")
      .or(`last_checked_at.is.null,last_checked_at.lt."${runStart}"`);
    reverted = count ?? 0;
  }

  // ── Phase B: success_rate enrichment (bounded, resumable, popular-first).
  const { data: spRoutes } = await sb.from("routes")
    .select("service_id, country_id").eq("provider", "smspool").eq("status", "active");
  const prio = (sid: string) => (sid in SERVICE_OVERRIDES ? 0 : 1);
  const combos = (spRoutes ?? [])
    .map((r) => ({ s: r.service_id, c: r.country_id }))
    .sort((a, b) => prio(a.s) - prio(b.s));

  const { data: cur } = await sb.from("app_config").select("value").eq("key", "smspool_sync").maybeSingle();
  let cursor = (cur?.value as { cursor?: number })?.cursor ?? 0;
  if (cursor >= combos.length) cursor = 0;

  let enriched = 0;
  for (let n = 0; n < ENRICH_BATCH && combos.length > 0; n++) {
    const combo = combos[(cursor + n) % combos.length];
    const spS = ourSvcToSp.get(combo.s);
    const spC = ourCtyToSp.get(combo.c);
    if (spS == null || spC == null) continue;
    const p = await getPrice(spC, spS);
    if (p.ok && p.successRate != null) {
      await sb.from("routes").update({ success_rate: p.successRate }).eq("service_id", combo.s).eq("country_id", combo.c);
      enriched++;
    }
    await sleep(ENRICH_PACE_MS);
  }
  const nextCursor = combos.length ? (cursor + ENRICH_BATCH) % combos.length : 0;
  await sb.from("app_config").upsert(
    { key: "smspool_sync", value: { cursor: nextCursor, combos: combos.length, checked_at: runStart }, updated_at: runStart },
    { onConflict: "key" },
  );

  return json({
    routesUpdated, reverted, enriched,
    servicesMapped: svcMapUpserts.length, countriesMapped: ctyMapUpserts.length,
    bulkRows: bulk.length, enrichCursor: nextCursor,
  });
});
