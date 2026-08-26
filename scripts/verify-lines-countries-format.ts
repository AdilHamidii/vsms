// Rendering assertions for `/lines countries` (formatLineCountries).
//
//   deno run --allow-env scripts/verify-lines-countries-format.ts
//
// The command cannot be exercised through telegram-setup's `{"preview": …}`
// path: `/lines` carries `mutates` at COMMAND level (deliberately — the flag is
// per command, not per argument, so CRON_SECRET alone can never flip the
// product kill switch), and preview refuses the whole command. So this script
// is the only way to see the rendering without the owner's phone.
//
// It asserts the house style the formatter tests already enforce elsewhere:
// line 1 is the answer, no "undefined"/"NaN", no raw ISO timestamps, lists
// capped, and a Paris stamp on the last line.

import { formatLineCountries } from "../supabase/functions/_shared/opsFormat.ts";

let failed = 0;
function check(name: string, ok: boolean, extra = "") {
  console.log(`${ok ? "✅" : "❌"} ${name}${ok ? "" : ` — ${extra}`}`);
  if (!ok) failed++;
}

function country(over: Record<string, unknown> = {}) {
  return {
    code: "us", name: "United States", number_type: "local",
    sell_state: "sellable", sell_reason: null,
    supports_voice: true, supports_sms: true, supports_mms: true,
    supports_emergency: true, stock_seen: true,
    sample_monthly_cents: 100, sample_upfront_cents: 100,
    sample_currency: "USD", sample_cost_known: true,
    document_count: 0, requirement_group_status: null,
    requirements_checked_at: new Date().toISOString(),
    coverage_checked_at: new Date().toISOString(),
    last_fault: null, live_lines: 2,
    ...over,
  };
}

// ── 1. A realistic mixed catalog ────────────────────────────────────────────
const mixed = formatLineCountries({
  total: 4, sellable: 2, live_lines: 3,
  sync: { checked_at: new Date(Date.now() - 3_600_000).toISOString() },
  max_age_hours: 48,
  countries: [
    country(),
    country({
      code: "gb", name: "United Kingdom", supports_sms: false,
      supports_mms: false, supports_emergency: false,
      sample_cost_known: false, sample_monthly_cents: null,
      live_lines: 1, stock_seen: false,
    }),
    country({
      code: "fr", name: "France", sell_state: "blocked",
      sell_reason: "documents_required", document_count: 3,
      requirement_group_status: "pending", live_lines: 0,
      supports_sms: null, supports_mms: null, supports_emergency: null,
    }),
    country({
      code: "de", name: "Germany", sell_state: "blocked",
      sell_reason: "never_probed", document_count: null,
      supports_voice: null, supports_sms: null,
      requirement_group_status: null, live_lines: 0,
    }),
  ],
});
console.log("─".repeat(72));
console.log(mixed);
console.log("─".repeat(72));

check("headline is line 1 and counts come from the RPC",
  mixed.split("\n")[0].includes("2 sellable of 4 countries probed"),
  mixed.split("\n")[0]);
check("no 'undefined'", !mixed.includes("undefined"));
check("no 'NaN'", !mixed.includes("NaN"));
check("no raw ISO timestamp", !/\d{4}-\d{2}-\d{2}T\d{2}:/.test(mixed));
check("voice-only country shows 📞 and not 💬", mixed.includes("📞···"));
check("unknown cost prints 'no quote'", mixed.includes("no quote"));
check("known cost prints money", mixed.includes("$1.00/mo"));
check("blocked reason is printed", mixed.includes("documents_required"));
check("document count is printed for a blocked row", mixed.includes("3 documents"));
check("no-stock warning on a sellable row", mixed.includes("no stock seen"));
check("last line is the Paris stamp",
  /^🕒 .* Paris$/.test(mixed.trim().split("\n").pop()!));

// ── 2. Empty catalog — never a plausible-looking blank ──────────────────────
const empty = formatLineCountries({ total: 0, sellable: 0, countries: [] });
check("empty catalog says so explicitly", empty.includes("never written a row"));
check("empty catalog still stamped", empty.includes("Paris"));
check("empty: no undefined/NaN", !empty.includes("undefined") && !empty.includes("NaN"));

// ── 3. Caps — a silently truncated list reads as "that was everything" ──────
const many = formatLineCountries({
  total: 60, sellable: 40, sync: { checked_at: new Date().toISOString() },
  countries: [
    ...Array.from({ length: 40 }, (_, i) =>
      country({ code: `s${i}`, name: `Sellable ${i}` })),
    ...Array.from({ length: 20 }, (_, i) =>
      country({ code: `b${i}`, name: `Blocked ${i}`, sell_state: "blocked",
                sell_reason: "no_voice" })),
  ],
});
check("sellable list capped at 20 with an explicit remainder",
  many.includes("… and 20 more, not shown"));
check("blocked list capped at 15 with an explicit remainder",
  many.includes("… and 5 more, not shown"));
check("headline still reports the SQL totals, not the capped array",
  many.split("\n")[0].includes("40 sellable of 60 countries probed"));
check("capped render: no undefined/NaN",
  !many.includes("undefined") && !many.includes("NaN"));

// ── 4. Missing/garbage fields must not produce a broken line ────────────────
const sparse = formatLineCountries({
  total: 1, sellable: 0,
  countries: [{ code: "zz", sell_state: "blocked" }],
});
check("row with almost no fields renders", sparse.includes("ZZ"));
check("missing name falls back rather than printing undefined",
  !sparse.includes("undefined") && !sparse.includes("NaN"));
check("missing sell_reason is stated, not blank",
  sparse.includes("no reason recorded"));
check("missing heartbeat is stated",
  sparse.includes("never been refreshed"));

console.log(failed === 0 ? "\nAll assertions passed." : `\n${failed} FAILED`);
if (failed > 0) Deno.exit(1);
