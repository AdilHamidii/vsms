// Live availability for the rentable-line picker.
//
// Read-only and JWT-gated: it buys nothing and charges nothing, so it is safe
// to call on every keystroke of the picker. It quotes LIVE and never caches —
// stock is per (country, area code) and genuinely runs dry, the same rule
// `email-domains` follows for HeroSMS domains.
//
// ── Why CITIES and not area codes ──────────────────────────────────────────
// Measured 2026-08-05: Canada's prestige codes are EXHAUSTED — 416 and 647
// (Toronto), 514 (Montreal), 613 (Ottawa) and 403 (Calgary) all return zero —
// while their overlays are full: 437, 438, 343, 587, 905, 289. That is not a
// Telnyx quirk, it is how North American numbering works, and it is how real
// Canadians get numbers today.
//
// So a raw area-code picker would show a user "416 — Toronto" and then fail.
// Offering a CITY and trying its codes in order hides an exhausted prefix
// behind a working one, and the user still gets a Toronto number.
//
// ⚠️ Do NOT reach for `filter[best_effort]=true` to paper over this. Measured:
// best_effort on 416 silently returns 437 numbers. It substitutes a DIFFERENT
// area code without saying so, which is fine only because we chose the
// fallback ourselves — as a blanket flag it would let the UI promise one city
// and deliver another.

import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import { searchNumbers, faultOf, type AvailableNumber } from "../_shared/telnyx.ts";

/** Codes are ordered MOST-LIKELY-TO-HAVE-STOCK FIRST, which is generally the
 *  overlay rather than the original. Verified against live inventory. */
const CITIES: Record<string, { country: string; label: string; codes: string[] }> = {
  toronto:   { country: "CA", label: "Toronto",   codes: ["437", "647", "416", "905", "289"] },
  montreal:  { country: "CA", label: "Montreal",  codes: ["438", "514"] },
  vancouver: { country: "CA", label: "Vancouver", codes: ["604", "778", "236"] },
  calgary:   { country: "CA", label: "Calgary",   codes: ["587", "403", "825"] },
  ottawa:    { country: "CA", label: "Ottawa",    codes: ["343", "613"] },
  halifax:   { country: "CA", label: "Halifax",   codes: ["902", "782"] },
  winnipeg:  { country: "CA", label: "Winnipeg",  codes: ["204", "431"] },
};

const DEFAULT_CITY = "toronto";

async function isPaused(sb: ReturnType<typeof admin>): Promise<boolean> {
  const { data, error } = await sb.from("app_config").select("value")
    .eq("key", "lines_paused").maybeSingle();
  // Fail CLOSED on a read error: a flag we cannot read must not be treated as
  // "not paused". The eSIM pause is the precedent — a cached client must never
  // be able to buy from a line the owner has taken off sale.
  if (error) return true;
  return (data?.value as boolean | null) !== false;
}

Deno.serve(async (req) => {
  const pre = handleCors(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, { status: 405 });

  const userId = await callerUserId(req);
  if (!userId) return json({ error: "unauthorized" }, { status: 401 });

  let body: { city?: string } = {};
  try {
    body = await req.json();
  } catch {
    body = {};
  }

  const sb = admin();
  if (await isPaused(sb)) {
    return json({ error: "lines_paused" }, { status: 409 });
  }

  const key = (body.city ?? DEFAULT_CITY).toLowerCase();
  const city = CITIES[key];
  if (!city) return json({ error: "unknown_city" }, { status: 400 });

  // Try each code in turn and stop at the first with stock. A city is only
  // reported unavailable once EVERY one of its codes is dry.
  let numbers: AvailableNumber[] = [];
  let usedCode: string | null = null;
  let lastFault: string | null = null;

  for (const code of city.codes) {
    const r = await searchNumbers({ country: city.country, areaCode: code, limit: 8 });
    if (faultOf(r)) {
      // OUT_OF_STOCK on one code is ordinary; keep walking. Anything else is a
      // real fault worth surfacing if no code works.
      lastFault = r.type;
      // Walking the remaining codes cannot help when the ACCOUNT is the
      // problem. It just multiplies the same failure by seven.
      if (r.type !== "OUT_OF_STOCK") break;
      continue;
    }
    if (r.length > 0) {
      numbers = r;
      usedCode = code;
      break;
    }
  }

  if (numbers.length === 0) {
    // 🔴 ONLY a genuine stockout may read as "no numbers available".
    //
    // `classifyTelnyxFault` returns BALANCE_ERROR for a 402 and TRANSPORT_ERROR
    // for anything it does not recognise, and both used to fall through to
    // `no_numbers_available` — so a dead API key, an empty Telnyx account or a
    // network outage told the user every Canadian city was sold out. There is
    // no other country to shop to on this line, so that reads as the product
    // simply not working, and it is the exact failure `classifyTelnyxFault`'s
    // own comment warns about one layer down.
    const outage = lastFault != null && lastFault !== "OUT_OF_STOCK";
    if (outage) {
      console.error(JSON.stringify({
        alert: "line_search_provider_fault", city: key, fault: lastFault,
      }));
    }
    return json({
      error: outage ? "provider_unreachable" : "no_numbers_available",
      city: key,
      cities: Object.entries(CITIES).map(([k, c]) => ({ id: k, label: c.label })),
    }, { status: outage ? 502 : 409 });
  }

  return json({
    city: key,
    label: city.label,
    area_code: usedCode,
    cities: Object.entries(CITIES).map(([k, c]) => ({ id: k, label: c.label })),
    // `monthly_cents` is what TELNYX charges us. It is returned so the caller
    // can stamp it onto phone_lines at purchase — NOTHING reports the cost
    // again afterwards, so this quote is the only chance to record it. It is
    // never rendered: the user sees the subscription price, not our wholesale.
    numbers: numbers.map((n) => ({
      phone_number: n.phoneNumber,
      region: n.region,
      monthly_cents: n.monthlyCents,
      upfront_cents: n.upfrontCents,
    })),
  });
});
