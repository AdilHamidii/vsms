// Weekly resumable virtualsms price sync (cron: relay-virtualsms-sync).
// Overlay model: one route row per (service, country). For each mapped combo we
// ask virtualsms /price; if it sells the combo we take ownership (provider=
// virtualsms, 5× its price). If it no longer does, we hand the combo back to
// SMSPVA (provider=smspva) so the daily sync-prices reprices it. sync-prices
// skips virtualsms-owned combos so the two never clobber each other.
//
// Paced under the 60/min rate limit and chunked (~50 combos/run) so each
// invocation finishes inside the edge-function wall-clock; the every-minute
// Sunday cron advances the cursor until the matrix is done, then it no-ops.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import { price } from "../_shared/virtualsms.ts";

const DIVISOR = 0.10;   // 5× retail markup (keep in lockstep with sync-prices)
const BATCH = 50;       // combos per invocation (~50s at 60/min → under 60s cron)
const PACE_MS = 1000;   // 60 requests/minute
const MIN_CREDITS = 1, MAX_CREDITS = 999;
const MAX_WHOLESALE_CENTS = 400; // hide routes pricier than this (see sync-prices)

const credits = (usd: number) =>
  Math.max(MIN_CREDITS, Math.min(MAX_CREDITS, Math.ceil(usd / DIVISOR)));
const today = () => new Date().toISOString().slice(0, 10);

function validateCron(req: Request): boolean {
  const h = req.headers.get("x-cron-secret");
  const e = Deno.env.get("CRON_SECRET");
  return !!h && !!e && h === e;
}

async function setConfig(sb: ReturnType<typeof admin>, key: string, value: unknown) {
  await sb.from("app_config").upsert(
    { key, value, updated_at: new Date().toISOString() },
    { onConflict: "key" },
  );
}

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;
  if (!validateCron(req)) return json({ error: "unauthorized" }, { status: 401 });

  const sb = admin();

  // Build the deterministic combo list: our services × countries that carry a
  // virtualsms code.
  const { data: svcs } = await sb.from("services").select("id, virtualsms_code").not("virtualsms_code", "is", null);
  const { data: ctys } = await sb.from("countries").select("id, virtualsms_code").not("virtualsms_code", "is", null);
  const combos: { sid: string; vs: string; cid: string; vc: string }[] = [];
  for (const s of (svcs ?? [])) {
    for (const c of (ctys ?? [])) {
      combos.push({ sid: s.id, vs: s.virtualsms_code as string, cid: c.id, vc: c.virtualsms_code as string });
    }
  }
  combos.sort((a, b) => (a.sid + a.cid).localeCompare(b.sid + b.cid));
  const total = combos.length;

  // Cursor.
  const { data: cfg } = await sb.from("app_config").select("value").eq("key", "virtualsms_sync").maybeSingle();
  let cur = (cfg?.value ?? { index: 0, running: false }) as
    { index: number; running: boolean; last_completed?: string };

  if (!cur.running) {
    if (cur.last_completed === today()) {
      return json({ status: "already_completed_today", total });
    }
    // Fresh start. Intentionally NO maintenance banner: a routine price refresh
    // must not block ordering (that frustrates new users at their activation
    // moment). Orders during the sync just use whatever price is current, which
    // is harmless. The maintenance flag stays available for real emergencies.
    cur = { index: 0, running: true, last_completed: cur.last_completed };
  }

  const start = cur.index;
  const end = Math.min(start + BATCH, total);
  let priced = 0, reverted = 0, skipped = 0;
  const nowIso = new Date().toISOString();

  for (let i = start; i < end; i++) {
    const cb = combos[i];
    try {
      const r = await price(cb.vs, cb.vc);
      if (r.ok && r.priceUsd != null && r.priceUsd > 0) {
        const cents = Math.round(r.priceUsd * 100);
        await sb.from("routes").upsert({
          service_id: cb.sid, country_id: cb.cid, provider: "virtualsms",
          retail_credits: credits(r.priceUsd), last_cost_cents: cents,
          last_checked_at: nowIso, status: cents > MAX_WHOLESALE_CENTS ? "hidden" : "active",
        }, { onConflict: "service_id,country_id" });
        priced++;
      } else {
        // virtualsms no longer sells it — hand any existing overlay back to
        // SMSPVA so the daily sync reprices it. Don't touch SMSPVA-owned routes.
        const { data: upd } = await sb.from("routes")
          .update({ provider: "smspva" })
          .eq("service_id", cb.sid).eq("country_id", cb.cid).eq("provider", "virtualsms")
          .select("service_id");
        if (upd && upd.length) reverted++; else skipped++;
      }
    } catch (_e) {
      skipped++;
    }
    await new Promise((res) => setTimeout(res, PACE_MS));
  }

  const done = end >= total;
  await setConfig(sb, "virtualsms_sync", done
    ? { index: 0, running: false, last_completed: today() }
    : { index: end, running: true, last_completed: cur.last_completed });

  return json({ processed: end - start, priced, reverted, skipped, cursor: done ? 0 : end, total, done });
});
