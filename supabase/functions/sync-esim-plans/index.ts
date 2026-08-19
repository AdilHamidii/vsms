// eSIM Access catalog sync. TWO api calls — package/list {} returns the whole
// unpaginated catalog (~3,000 packages) and location/list names the regions —
// then upserts esim_plans priced at 4x wholesale, a SEPARATE routine from the
// OTP CREDIT_DIVISOR so the two markups never collide. Cron-gated.
//
// Provider switched from SMSPool on 2026-08-10. Old SMSPool rows (numeric ids)
// are KEPT hidden forever: esim_orders.plan_id FKs them and historical orders
// resolve their display name from the catalog. New ids are 'ea:<packageCode>'
// — collision-proof against the numeric SMSPool ids, which is the esim_plans
// PK landmine (a colliding id would repoint a live order at a different
// product, including the validity_days that drives expiry).

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import { dataMbFromBytes, listLocations, listPackages, type EaPackage } from "../_shared/esimaccess.ts";

const ESIM_MARGIN = 4;            // sell at 4x wholesale
const CREDIT_VALUE_USD = 0.48;    // blended pack $/credit

function retailCredits(usd: number): number {
  if (!Number.isFinite(usd) || usd <= 0) return 1;
  return Math.max(1, Math.ceil((usd * ESIM_MARGIN) / CREDIT_VALUE_USD));
}
function validateCronSecret(req: Request): boolean {
  const h = req.headers.get("x-cron-secret");
  const e = Deno.env.get("CRON_SECRET");
  return !!h && !!e && h === e;
}

/** "MX,US,CA," → ["MX","US","CA"] — the wire carries trailing commas. */
function locationCcs(location: string): string[] {
  return location.split(",").map((s) => s.trim()).filter(Boolean);
}

/** Synthetic country_code per multi-country region, keyed by the provider's
 *  region location code (= the slug prefix of every package in it).
 *
 *  🔴 THE VALUES MUST BE LETTER-FREE (numeric), with "EU" as the ONE deliberate
 *  exception. The shipped client's flagEmoji() keeps only A–Z scalars, so a
 *  provider code stored verbatim renders a REAL country's flag: "NA-3" → 🇳🇦
 *  Namibia for North America, "GL-139" → 🇬🇱 Greenland for Global, "ME-13" →
 *  🇲🇪 Montenegro, "AS-7" → 🇦🇸 American Samoa. Digits produce no regional-
 *  indicator scalars, so a numeric code falls through to the honest 🌐. "EU"
 *  renders the genuine 🇪🇺 and flagcdn serves eu.png, so Europe's flagship
 *  region keeps a real flag. Two-letter ISO codes are BANNED as values for the
 *  same reason ("CN" would merge a region into the real China group).
 *
 *  Values are opaque grouping keys (loosely M49-flavoured where one exists) —
 *  nothing interprets them; they only need to be unique, stable, and letter-
 *  free. A region absent from this map is SKIPPED by the sync and counted in
 *  `skipped_unmapped` — never guessed, because a wrong region row is a
 *  coverage claim the buyer acts on. Seeded from the live location/list
 *  2026-08-10 (36 regions). */
const REGION_CC: Record<string, string> = {
  "EU-42": "EU",  // Europe (40+ areas) — the one real flag
  "EU-43": "901", // Europe (40+ areas) & Morocco
  "EU-30": "902", "EU-31": "903", "EU-33": "904", "EU-35": "905",
  "EU-7": "906",  // Balkans
  "BI-2": "907",  // Ireland & UK
  "IESI-2": "908",
  "GL-139": "001", "GL-120": "909",
  "AS-7": "142", "AS-12": "910", "AS-20": "911", "AS-21": "912",
  "AS-5": "143",  // Central Asia
  "CA-4": "913",  // Central Asia (4 areas)
  "NA-3": "003", "USCA-2": "914",
  "SA-18": "005", "SA-6": "915",
  "CB-25": "029", // Caribbean
  "AF-29": "002",
  "ME-13": "145", "ME-12": "916", "ME-6": "917",
  "SAAEQAKWOMBH-6": "918", // GCC
  "CN-3": "919", "CNHK-2": "920", "CNJPKR-3": "921", "JPKR-2": "922",
  "SGMY-2": "923", "SGMYTH-3": "924", "SGMYVNTHID-5": "925",
  "AUNZ-2": "926", "AUKUS-3": "927",
};

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;
  if (!validateCronSecret(req)) return json({ error: "unauthorized" }, { status: 401 });

  const sb = admin();
  const runStart = new Date().toISOString();

  // The eSIM line can be paused from the backend (`select set_esim_paused(true)`
  // or /esim off). This run must NOT undo that: without the gate the daily cron
  // re-activates the whole catalog and the product silently comes back on sale.
  //
  // The sync deliberately keeps RUNNING while paused — it refreshes
  // `last_checked_at`, which is the signal `set_esim_paused(false)` uses to
  // decide what may be re-activated. If the provider is gone the sync fails,
  // nothing stays fresh, and resuming correctly re-activates nothing.
  const { data: pausedCfg } = await sb
    .from("app_config").select("value").eq("key", "esim_paused").maybeSingle();
  const paused = pausedCfg?.value === true;

  // ── Fetch BOTH provider reads before touching the table, and abort loudly on
  //    either failing. The SMSPool version of this sync could literally never
  //    fail — its adapter returned fault objects that an Array.isArray check
  //    silently swallowed, so a dead API key produced HTTP 200
  //    {plansUpserted: 0} forever, success-shaped. Same abort-without-writing
  //    rule as sync-5sim's `countries_ok === 0` guard: a fetch failure must
  //    never be readable as "the provider carries nothing".
  const pkgRes = await listPackages();
  if (!pkgRes.ok) {
    console.error(`sync-esim-plans: catalog fetch FAILED: ${pkgRes.error}`);
    return json({ error: "catalog_fetch_failed", detail: pkgRes.error }, { status: 500 });
  }
  if (pkgRes.packages.length === 0) {
    console.error("sync-esim-plans: catalog fetch returned ZERO packages — not writing");
    return json({ error: "catalog_empty" }, { status: 500 });
  }
  const locRes = await listLocations();
  if (!locRes.ok) {
    console.error(`sync-esim-plans: location list FAILED: ${locRes.error}`);
    return json({ error: "locations_fetch_failed", detail: locRes.error }, { status: 500 });
  }

  // Region identity for multi-country packages: their slug is prefixed with the
  // region's own location code ("EU-42_3_30" ↔ location {code:"EU-42", name:
  // "Europe (40+ areas)"}). Display name comes from location/list VERBATIM;
  // country_code comes from REGION_CC (see the flag-safety note on it).
  const regionName = new Map<string, string>();
  for (const l of locRes.locations) {
    if (l.type === 2 && typeof l.code === "string" && typeof l.name === "string") {
      regionName.set(l.code, l.name);
    }
  }

  // Country display names. esim_plans.name is the DESTINATION the shipped
  // client renders (store rows, map cards, checkout "Destination", the
  // "Covers: X only" fallback) — NEVER the provider's plan title.
  let displayNames: Intl.DisplayNames | null = null;
  try {
    displayNames = new Intl.DisplayNames(["en"], { type: "region" });
  } catch {
    displayNames = null; // counted per-row below as name_fallbacks
  }
  const countryName = (cc: string, p: EaPackage): { name: string; fallback: boolean } => {
    try {
      const n = displayNames?.of(cc);
      // Intl returns the code itself for unknown-but-valid subtags; that is a
      // fallback, not a name.
      if (typeof n === "string" && n && n !== cc) return { name: n, fallback: false };
    } catch { /* invalid subtag */ }
    const net = p.locationNetworkList?.[0]?.locationName;
    if (typeof net === "string" && net.trim()) return { name: net.trim(), fallback: true };
    return { name: cc, fallback: true };
  };

  const { data: prev } = await sb.from("esim_plans").select("id, smoothed_cost_cents");
  const prevSmoothed = new Map<string, number>();
  for (const p of prev ?? []) if (p.smoothed_cost_cents != null) prevSmoothed.set(p.id, p.smoothed_cost_cents);

  // ── Scope + row mapping. v1 sells fixed-data packages only (dataType 1);
  //    day-pass variants (2/3/4) need periodNum at order time and are excluded.
  //    Every exclusion is COUNTED into the response — a scope decision must be
  //    visible, never silent.
  const updates: Record<string, unknown>[] = [];
  let skippedDaypass = 0, skippedUnmapped = 0, skippedBad = 0, nameFallbacks = 0;

  for (const p of pkgRes.packages) {
    if (p.dataType !== 1) { skippedDaypass++; continue; }
    if (
      typeof p.packageCode !== "string" || !p.packageCode ||
      typeof p.price !== "number" || p.price <= 0 ||
      typeof p.volume !== "number" || p.volume <= 0 ||
      typeof p.duration !== "number" || p.duration <= 0 ||
      p.durationUnit !== "DAY"
    ) { skippedBad++; continue; }

    const ccs = locationCcs(String(p.location ?? ""));
    if (ccs.length === 0) { skippedBad++; continue; }

    let countryCode: string, name: string, region: string;
    if (ccs.length === 1) {
      countryCode = ccs[0].toUpperCase();
      const n = countryName(countryCode, p);
      if (n.fallback) nameFallbacks++;
      name = n.name;
      // "Japan" alone reads like a destination label and a buyer can still
      // assume it roams; "Japan only" is the fact they need before paying.
      region = `${n.name} only`;
    } else {
      const prefix = String(p.slug ?? "").split("_")[0];
      const rn = prefix ? regionName.get(prefix) : undefined;
      const cc = prefix ? REGION_CC[prefix] : undefined;
      // No region match in EITHER source → SKIP, never invent a group. A
      // guessed region row would be a coverage claim the user acts on.
      if (!rn || !cc) { skippedUnmapped++; continue; }
      countryCode = cc;
      name = rn;
      region = `${ccs.length} countries`;
    }

    const cents = Math.round(p.price / 100); // ×10,000 → cents, exact
    const id = `ea:${p.packageCode}`;
    const prevS = prevSmoothed.get(id);
    // RATCHET, not a symmetric EWMA. A cost RISE must apply immediately; only
    // falls are smoothed. Averaging a rise against yesterday's cheaper price
    // sets retail below what we are about to pay — that exact bug put 4,384
    // SMS routes under wholesale on 2026-07-21. The price echo in
    // create-esim-order's orderEsim call is the second line of defence.
    const smoothed = prevS == null || cents > prevS
      ? cents
      : Math.round(0.5 * cents + 0.5 * prevS);

    updates.push({
      id,
      name,
      country_code: countryCode,
      // Raw coverage list, kept for diagnostics/a future parser — the client
      // never selects this column.
      network: String(p.location ?? "") || null,
      region,
      data_mb: dataMbFromBytes(p.volume),
      validity_days: p.duration,
      speed: typeof p.speed === "string" && p.speed ? p.speed : null,
      extendable: p.supportTopUpType === 2 || p.supportTopUpType === 3,
      retail_credits: retailCredits(smoothed / 100),
      last_cost_cents: cents,
      smoothed_cost_cents: smoothed,
      status: paused ? "hidden" : "active",
      last_checked_at: runStart,
      sort_order: 0, // assigned after the sort below
    });
  }

  // Stable browse order: by destination, cheapest first.
  updates.sort((a, b) =>
    String(a.country_code).localeCompare(String(b.country_code)) ||
    (a.last_cost_cents as number) - (b.last_cost_cents as number));
  updates.forEach((u, i) => { u.sort_order = i; });

  let upserted = 0;
  const CHUNK = 500;
  for (let i = 0; i < updates.length; i += CHUNK) {
    const { error } = await sb.from("esim_plans").upsert(updates.slice(i, i + CHUNK), { onConflict: "id" });
    if (error) return json({ error: "upsert_failed", detail: error.message, partial: upserted }, { status: 500 });
    upserted += Math.min(CHUNK, updates.length - i);
  }

  // Hide plans not refreshed this run (delisted by the provider). The floor is
  // insurance against a truncated-but-parseable response hiding the catalog on
  // a 200 — 500 is ~30% of the expected ~1,660 in-scope rows (the old 50 was
  // tuned for SMSPool's 1,081 and would have let a 97%-truncated response
  // through). With a single-response fetch a partial run is otherwise
  // impossible, so the fail-loud abort above is the real guard.
  let hidden = 0;
  if (upserted >= 500) {
    const { count, error: hideErr } = await sb.from("esim_plans")
      .update({ status: "hidden" }, { count: "exact" })
      .eq("status", "active").or(`last_checked_at.is.null,last_checked_at.lt."${runStart}"`);
    // 🔴 DESTRUCTURING ONLY `{ count }` MADE FAILURE LOOK LIKE SUCCESS.
    // supabase-js RETURNS errors, so on failure `count` is null, `hidden`
    // renders 0, and the response is byte-identical to a healthy run where
    // nothing needed hiding — while every plan the provider delisted stays ON
    // SALE. Fail loud, the way the upsert loop above already does: a sync that
    // could not retire delisted inventory has not succeeded.
    if (hideErr) {
      return json({
        error: "hide_failed", detail: hideErr.message,
        plansUpserted: upserted, hidden: 0,
      }, { status: 500 });
    }
    hidden = count ?? 0;
  }

  return json({
    packages_total: pkgRes.packages.length,
    in_scope: updates.length,
    plansUpserted: upserted,
    hidden,
    paused,
    name_fallbacks: nameFallbacks,
    skipped_daypass: skippedDaypass,
    skipped_unmapped: skippedUnmapped,
    skipped_bad: skippedBad,
  });
});
