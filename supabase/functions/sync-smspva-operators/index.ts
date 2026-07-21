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
// probed). Runs as a DAILY full pass (cron 04:30 UTC) behind the app's
// maintenance screen: ~69 countries at 4s spacing ≈ 5 minutes.
//
// The pass runs as a BACKGROUND task (EdgeRuntime.waitUntil) and the request
// returns immediately. This is load-bearing, not a style choice: the edge
// runtime kills any request that hasn't started responding within 150s
// (IDLE_TIMEOUT, hit live on the first single-request attempt), while
// background tasks may run to the 400s worker ceiling. The cron never reads
// the response anyway; progress lands in the DB (cursor, pins) and logs.
// Crash safety is layered: the maintenance flag always carries an `until`
// bound (the client ignores active flags past it), and the per-country
// cursor makes the next run resume where a dead one stopped.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import { getCountryPrices, isOk } from "../_shared/smspva.ts";

// Keep in lockstep with sync-prices: same divisor, same wholesale ceiling.
const CREDIT_DIVISOR = 0.10;
const MIN_CREDITS = 1;
const MAX_CREDITS = 999;
const MAX_WHOLESALE_CENTS = 400;

const CALL_SPACING_MS = 4000;   // SMSPVA: "interval of 4 to 5 seconds"
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

async function runPass(): Promise<void> {
  const sb = admin();

  const { data: services, error: sErr } = await sb
    .from("services").select("id, smspva_code");
  if (sErr || !services) throw new Error(`services_load_failed: ${sErr?.message}`);

  const { data: countries, error: cErr } = await sb
    .from("countries").select("id, smspva_code")
    .not("smspva_code", "is", null)
    .order("id");
  if (cErr || !countries) throw new Error(`countries_load_failed: ${cErr?.message}`);

  // Only routes that already exist get annotated — sync-prices owns creation.
  const { data: routeRows, error: rErr } = await sb
    .from("routes").select("service_id, country_id, retail_credits")
    .eq("provider", "smspva");
  if (rErr || !routeRows) throw new Error(`routes_load_failed: ${rErr?.message}`);

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

  // Full pass, rotated to start after the cursor: a healthy run covers every
  // country regardless of where it starts, and a crashed run left the cursor
  // at its last completed country so the retry finishes the remainder first.
  const { data: curRow } = await sb
    .from("app_config").select("value").eq("key", CURSOR_KEY).maybeSingle();
  const cursor = (curRow?.value as { cursor?: string } | null)?.cursor ?? null;
  let start = cursor ? countries.findIndex((c) => c.id === cursor) + 1 : 0;
  if (start >= countries.length || start < 0) start = 0;
  const rotation = [...countries.slice(start), ...countries.slice(0, start)];

  // Maintenance up while pins are rewritten, so the clear-then-set window is
  // never user-visible. `until` bounds the blockage even if this run dies.
  const estMs = rotation.length * (CALL_SPACING_MS + 500) + 60_000;
  const setMaintenance = (value: Record<string, unknown>) =>
    sb.from("app_config").upsert({ key: "maintenance", value }, { onConflict: "key" });
  {
    const { error: mErr } = await setMaintenance({
      active: true,
      until: new Date(Date.now() + estMs).toISOString(),
      message: "Refreshing the number catalog — back in a few minutes.",
    });
    if (mErr) console.error("sync-smspva-operators: maintenance raise failed", mErr.message);
  }

  let pinned = 0;
  let cleared = 0;
  let fetchErrors = 0;
  let processed = 0;

  try {
    for (const [i, country] of rotation.entries()) {
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

      // Clear-then-set: stale pins from carriers that vanished must not
      // linger. Invisible to users — the maintenance screen is up.
      const { count: clearCount, error: clearErr } = await sb
        .from("routes")
        .update(
          { smspva_operator: null, smspva_operator_cents: null, premium_credits: null },
          { count: "exact" },
        )
        .eq("country_id", country.id)
        .eq("provider", "smspva")
        .not("smspva_operator", "is", null);
      if (clearErr) throw new Error(`clear_failed for ${country.id}: ${clearErr.message}`);
      cleared += clearCount ?? 0;

      const CHUNK = 500;
      for (let j = 0; j < picks.length; j += CHUNK) {
        const { error: upErr } = await sb
          .from("routes")
          .upsert(picks.slice(j, j + CHUNK), { onConflict: "service_id,country_id" });
        if (upErr) throw new Error(`upsert_failed for ${country.id}: ${upErr.message}`);
      }
      pinned += picks.length;
      processed++;

      // Cursor after every country, so a mid-pass crash resumes here.
      const { error: curErr } = await sb
        .from("app_config")
        .upsert({ key: CURSOR_KEY, value: { cursor: country.id } }, { onConflict: "key" });
      if (curErr) console.error("sync-smspva-operators: cursor write failed", curErr.message);
    }
  } finally {
    // Thrown errors above still lower the screen; a hard worker death is
    // covered by `until`.
    const { error: mErr } = await setMaintenance({ active: false });
    if (mErr) console.error("sync-smspva-operators: maintenance clear failed", mErr.message);
  }

  console.log(`sync-smspva-operators: pass complete — countries=${processed}/${rotation.length} pinned=${pinned} cleared=${cleared} fetchErrors=${fetchErrors}`);
}

Deno.serve((req) => {
  const cors = handleCors(req); if (cors) return cors;
  if (!validateCronSecret(req)) {
    return json({ error: "unauthorized" }, { status: 401 });
  }

  const work = runPass().catch((e) => {
    console.error("sync-smspva-operators: pass failed", String(e));
  });

  const rt = (globalThis as {
    EdgeRuntime?: { waitUntil: (p: Promise<unknown>) => void };
  }).EdgeRuntime;
  if (rt?.waitUntil) {
    rt.waitUntil(work);
    return json({ accepted: true });
  }
  // Local dev (no EdgeRuntime): degrade to synchronous.
  return work.then(() => json({ accepted: true, ranInline: true }));
});
