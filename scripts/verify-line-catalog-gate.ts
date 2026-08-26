#!/usr/bin/env -S deno run --allow-read
//
// Offline assertions for `_shared/lineCatalog.ts` — the single gate every
// rentable-line seller calls before touching Telnyx. Zero network: every
// Supabase call is served by a minimal in-memory stub that returns a canned
// {data, error} pair, so this proves the FAULT VOCABULARY the gate promises
// (`country_not_sellable` / `catalog_stale` / `catalog_unreadable`, plus
// `withinWholesaleCeiling`'s three refusal reasons) without a database.
//
//   deno run --allow-read scripts/verify-line-catalog-gate.ts
//
// This does not re-prove the sellability STATE MACHINE
// (`refresh_line_country_sellability()`) — that is
// `scripts/verify-line-country-catalog.sql`, which runs against real
// Postgres. This proves the TypeScript gate reads whatever `sell_state`/
// `sell_reason`/timestamps land in front of it correctly, independent of how
// they got there.

import {
  sellableCountry,
  withinWholesaleCeiling,
  localitiesFor,
  catalogFaultOf,
  type LineCatalogConfig,
} from "../supabase/functions/_shared/lineCatalog.ts";

let pass = 0, fail = 0;
function ok(name: string, cond: boolean, detail = "") {
  console.log(`${cond ? "PASS" : "*** FAIL ***"}  ${name}${detail ? "  " + detail : ""}`);
  cond ? pass++ : fail++;
}

// ── The stub client ──────────────────────────────────────────────────────
// `lineCatalog.ts` only ever does one shape of call per function:
//   sb.from(T).select(cols).eq(a,b).eq(c,d).maybeSingle()
//   sb.from(T).select(cols).eq(a,b).eq(c,d).eq(e,f).order(g,{...})
//   sb.from(T).select(cols).in(a,b)                          (loadLineCatalogConfig)
// Every test below passes an explicit `cfg` to sellableCountry, so the gate
// under test never reaches loadLineCatalogConfig's app_config read — the
// stub only ever needs to answer ONE query per call, which keeps each test
// case a single canned {data, error} pair rather than a per-table map.
class StubBuilder implements PromiseLike<{ data: unknown; error: unknown }> {
  constructor(private result: { data: unknown; error: unknown }) {}
  select(_cols?: unknown) { return this; }
  eq(_col?: unknown, _val?: unknown) { return this; }
  in(_col?: unknown, _vals?: unknown) { return Promise.resolve(this.result); }
  order(_col?: unknown, _opts?: unknown) { return Promise.resolve(this.result); }
  maybeSingle() { return Promise.resolve(this.result); }
  then<T1, T2>(
    onfulfilled?: ((v: { data: unknown; error: unknown }) => T1 | PromiseLike<T1>) | null,
    onrejected?: ((r: unknown) => T2 | PromiseLike<T2>) | null,
  ) {
    return Promise.resolve(this.result).then(onfulfilled, onrejected);
  }
}

function stubClient(result: { data: unknown; error: unknown }) {
  return { from: (_table: string) => new StubBuilder(result) } as unknown as
    Parameters<typeof sellableCountry>[0];
}

const CFG: LineCatalogConfig = {
  maxAgeHours: 48,
  ceilingMonthlyCents: 300,
  ceilingUpfrontCents: 500,
};

const FRESH = new Date().toISOString();
const STALE = new Date(Date.now() - 100 * 3_600_000).toISOString(); // 100h ago, > 48h max

function row(over: Record<string, unknown> = {}) {
  return {
    country_code: "US",
    number_type: "local",
    country_name: "United States",
    supports_voice: true,
    supports_sms: true,
    supports_mms: true,
    supports_emergency: true,
    reservable: true,
    requirements_empty: true,
    requirement_group_id: null,
    requirement_group_status: null,
    requirements_checked_at: FRESH,
    coverage_checked_at: FRESH,
    sell_state: "sellable",
    sell_reason: null,
    ...over,
  };
}

// ── 1. Query error ⇒ catalog_unreadable ─────────────────────────────────────
{
  const sb = stubClient({ data: null, error: { message: "connection reset" } });
  const r = await sellableCountry(sb, "US", "local", CFG);
  ok("query error -> catalogFault", catalogFaultOf(r));
  ok("query error -> reason catalog_unreadable",
    catalogFaultOf(r) && r.reason === "catalog_unreadable", JSON.stringify(r));
}

// ── 2. Missing row ⇒ country_not_sellable / never_probed ───────────────────
{
  const sb = stubClient({ data: null, error: null });
  const r = await sellableCountry(sb, "ZZ", "local", CFG);
  ok("missing row -> catalogFault", catalogFaultOf(r));
  ok("missing row -> reason country_not_sellable",
    catalogFaultOf(r) && r.reason === "country_not_sellable", JSON.stringify(r));
  ok("missing row -> detail never_probed",
    catalogFaultOf(r) && r.detail === "never_probed", JSON.stringify(r));
}

// ── 3. sell_state='blocked' ⇒ country_not_sellable, detail carries sell_reason
{
  const sb = stubClient({
    data: row({ sell_state: "blocked", sell_reason: "documents_required" }),
    error: null,
  });
  const r = await sellableCountry(sb, "GB", "local", CFG);
  ok("blocked row -> catalogFault", catalogFaultOf(r));
  ok("blocked row -> reason country_not_sellable",
    catalogFaultOf(r) && r.reason === "country_not_sellable", JSON.stringify(r));
  ok("blocked row -> detail is the catalog's own sell_reason",
    catalogFaultOf(r) && r.detail === "documents_required", JSON.stringify(r));
}

// ── 3b. sell_state='blocked' with no sell_reason -> detail falls back ──────
{
  const sb = stubClient({
    data: row({ sell_state: "blocked", sell_reason: null }),
    error: null,
  });
  const r = await sellableCountry(sb, "GB", "local", CFG);
  ok("blocked row with no sell_reason -> detail falls back to 'blocked'",
    catalogFaultOf(r) && r.detail === "blocked", JSON.stringify(r));
}

// ── 4. Stale coverage_checked_at ⇒ catalog_stale ────────────────────────────
{
  const sb = stubClient({
    data: row({ coverage_checked_at: STALE }),
    error: null,
  });
  const r = await sellableCountry(sb, "US", "local", CFG);
  ok("stale coverage -> catalogFault", catalogFaultOf(r));
  ok("stale coverage -> reason catalog_stale",
    catalogFaultOf(r) && r.reason === "catalog_stale", JSON.stringify(r));
}

// ── 4b. Stale requirements_checked_at (no approved group) ⇒ catalog_stale ──
{
  const sb = stubClient({
    data: row({ coverage_checked_at: FRESH, requirements_checked_at: STALE }),
    error: null,
  });
  const r = await sellableCountry(sb, "US", "local", CFG);
  ok("stale requirements probe (no approved group) -> catalog_stale",
    catalogFaultOf(r) && r.reason === "catalog_stale", JSON.stringify(r));
}

// ── 4c. Stale requirements_checked_at IS IGNORED when a group is APPROVED ──
// The group is the evidence; re-probing a pre-verified market must not close it.
{
  const sb = stubClient({
    data: row({
      coverage_checked_at: FRESH,
      requirements_checked_at: STALE,
      requirement_group_id: "RG-1",
      requirement_group_status: "approved",
    }),
    error: null,
  });
  const r = await sellableCountry(sb, "GB", "local", CFG);
  ok("stale requirements probe under an approved group -> still sellable",
    !catalogFaultOf(r), JSON.stringify(r));
}

// ── 5. Healthy sellable row -> success with the expected features array ────
{
  const sb = stubClient({ data: row(), error: null }); // supports_sms + supports_voice
  const r = await sellableCountry(sb, "us", "local", CFG);
  ok("healthy US row -> not a fault", !catalogFaultOf(r), JSON.stringify(r));
  if (!catalogFaultOf(r)) {
    ok("healthy US row -> features is [sms, voice]",
      JSON.stringify(r.features) === JSON.stringify(["sms", "voice"]),
      JSON.stringify(r.features));
    ok("country code is upper-cased", r.countryCode === "US", r.countryCode);
  }
}
{
  // voice-only country (e.g. FR local, per the providers.md probe): sms must
  // NEVER be sent on the strength of a null/false supports_sms — that is the
  // exact 400 `10015` this whole module exists to stop.
  const sb = stubClient({
    data: row({ supports_sms: false, supports_voice: true }),
    error: null,
  });
  const r = await sellableCountry(sb, "FR", "local", CFG);
  ok("voice-only row -> not a fault", !catalogFaultOf(r), JSON.stringify(r));
  if (!catalogFaultOf(r)) {
    ok("voice-only row -> features is exactly [voice]",
      JSON.stringify(r.features) === JSON.stringify(["voice"]), JSON.stringify(r.features));
  }
}

// ── 6. requirementGroupId: approved -> returned; pending -> null ───────────
{
  const sb = stubClient({
    data: row({ requirement_group_id: "RG-1", requirement_group_status: "approved" }),
    error: null,
  });
  const r = await sellableCountry(sb, "GB", "local", CFG);
  ok("approved group -> requirementGroupId returned",
    !catalogFaultOf(r) && r.requirementGroupId === "RG-1", JSON.stringify(r));
}
{
  const sb = stubClient({
    data: row({ requirement_group_id: "RG-2", requirement_group_status: "pending" }),
    error: null,
  });
  const r = await sellableCountry(sb, "GB", "local", CFG);
  // A pending group is not evidence, so it must also fall back to requiring a
  // fresh requirements probe: requirements_checked_at is FRESH here on purpose
  // so this isolates the approved-vs-pending branch, not the staleness one.
  ok("pending group -> requirementGroupId is null",
    !catalogFaultOf(r) && r.requirementGroupId === null, JSON.stringify(r));
}

// ── 7. localitiesFor ─────────────────────────────────────────────────────
{
  const sb = stubClient({
    data: [
      {
        id: "toronto", country_code: "CA", label: "Toronto", region_label: "Ontario",
        area_codes: ["437", "647", "416"], locality: null, admin_area: null,
        number_type: "local",
      },
    ],
    error: null,
  });
  const rows = await localitiesFor(sb, "ca", "local");
  ok("localitiesFor maps snake_case -> camelCase",
    rows.length === 1 && rows[0].regionLabel === "Ontario" &&
    JSON.stringify(rows[0].areaCodes) === JSON.stringify(["437", "647", "416"]),
    JSON.stringify(rows));
}
{
  const sb = stubClient({ data: null, error: { message: "boom" } });
  const rows = await localitiesFor(sb, "ca", "local");
  ok("localitiesFor fails closed to an empty array on error",
    Array.isArray(rows) && rows.length === 0, JSON.stringify(rows));
}

// ── 8. withinWholesaleCeiling ────────────────────────────────────────────
const ceilings = { ceilingMonthlyCents: CFG.ceilingMonthlyCents, ceilingUpfrontCents: CFG.ceilingUpfrontCents };

{
  const r = withinWholesaleCeiling(
    { monthlyCents: 4000, upfrontCents: 100, costKnown: true, currency: "USD" },
    ceilings, "CD",
  );
  ok("over-ceiling monthly -> refused",
    !r.ok && r.reason === "line_wholesale_ceiling", JSON.stringify(r));
}
{
  const r = withinWholesaleCeiling(
    { monthlyCents: 100, upfrontCents: 100, costKnown: true, currency: "EUR" },
    ceilings, "GB",
  );
  ok("non-USD currency -> refused, never converted",
    !r.ok && r.reason === "currency_not_usd", JSON.stringify(r));
}
{
  const r = withinWholesaleCeiling(
    { monthlyCents: 100, upfrontCents: 100, costKnown: false, currency: "USD" },
    ceilings, "GB",
  );
  ok("costKnown=false outside NANP -> refused",
    !r.ok && r.reason === "cost_unknown", JSON.stringify(r));
}
{
  const r = withinWholesaleCeiling(
    { monthlyCents: 100, upfrontCents: 100, costKnown: false, currency: "USD" },
    ceilings, "US",
  );
  ok("costKnown=false inside NANP -> allowed (measured $1 fallback)", r.ok, JSON.stringify(r));
}
{
  const r = withinWholesaleCeiling(
    { monthlyCents: 100, upfrontCents: 100, costKnown: true, currency: "USD" },
    ceilings, "US",
  );
  ok("healthy US offer -> ok", r.ok, JSON.stringify(r));
}
{
  // The upfront half of the ceiling, exercised independently of the monthly
  // one — a route could clear one and blow the other.
  const r = withinWholesaleCeiling(
    { monthlyCents: 100, upfrontCents: 5000, costKnown: true, currency: "USD" },
    ceilings, "US",
  );
  ok("over-ceiling upfront -> refused",
    !r.ok && r.reason === "line_wholesale_ceiling", JSON.stringify(r));
}
{
  // costKnown=false is refused even inside NANP once the (fallback) figures
  // themselves exceed the ceiling — "known NANP fallback" is not a blanket
  // pass, only a waiver on the missing-quote refusal.
  const r = withinWholesaleCeiling(
    { monthlyCents: 4000, upfrontCents: 100, costKnown: false, currency: "USD" },
    ceilings, "US",
  );
  ok("costKnown=false inside NANP still enforces the ceiling",
    !r.ok && r.reason === "line_wholesale_ceiling", JSON.stringify(r));
}

console.log(`\nPASS ${pass}/${pass + fail}`);
if (fail > 0) Deno.exit(1);
