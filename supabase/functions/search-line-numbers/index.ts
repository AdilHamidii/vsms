// Live availability for the rentable-line picker.
//
// Read-only and JWT-gated: it buys nothing and charges nothing, so it is safe
// to call on every keystroke of the picker. It quotes LIVE and never caches —
// stock is per (country, area code) and genuinely runs dry, the same rule
// `email-domains` follows for HeroSMS domains.
//
// ── Why LOCALITIES and not area codes ──────────────────────────────────────
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
//
// ── Where the cities went ──────────────────────────────────────────────────
// The hardcoded `CITIES` map that used to live here (and, byte-for-byte twice
// more, in `reserve-line-number` and `rent-line-credits`) is GONE. It is now
// `public.line_localities`, seeded identically. Three copies of one constant is
// the shape this repo has already watched drift — and outside NANP there are no
// area codes to hardcode at all: Telnyx filters on `locality` /
// `administrative_area` instead, which a map of Canadian prefixes cannot hold.
//
// ── Why a country can be refused ───────────────────────────────────────────
// `sellableCountry` fails CLOSED, and a refusal is `country_not_sellable` (409)
// — never `no_numbers_available`. The two send a user to completely different
// places: "try another city" versus "this country is not on sale". Telling
// somebody a country is out of stock when the truth is that it needs six
// regulatory documents is a wall they will walk into forever.

import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import { searchNumbers, faultOf, type AvailableNumber } from "../_shared/telnyx.ts";
import {
  sellableCountry, localitiesFor, catalogFaultOf, type LineLocality,
} from "../_shared/lineCatalog.ts";
import { NANP } from "../_shared/phone.ts";

/** ⚠️ The default applies to BOTH null and absent. Shipped 2.3 sends `{city}`
 *  only, and `body.country ?? DEFAULT` covers absent; a client that sends
 *  `{"country": null}` explicitly must land in the same place, which is what
 *  the `?? DEFAULT` on an already-nullable field buys. Never make `country`
 *  required — that breaks every build in the field. */
const DEFAULT_COUNTRY = "CA";

async function isPaused(sb: ReturnType<typeof admin>): Promise<boolean> {
  const { data, error } = await sb.from("app_config").select("value")
    .eq("key", "lines_paused").maybeSingle();
  // Fail CLOSED on a read error: a flag we cannot read must not be treated as
  // "not paused". The eSIM pause is the precedent — a cached client must never
  // be able to buy from a line the owner has taken off sale.
  if (error) return true;
  return (data?.value as boolean | null) !== false;
}

/** Legacy shape, unchanged: shipped 2.3 decodes `cities` as `{id,label}`.
 *  Kept alongside the richer `localities` for the whole overlap. */
const legacyCities = (rows: LineLocality[]) =>
  rows.map((l) => ({ id: l.id, label: l.label }));

const localityList = (rows: LineLocality[]) =>
  rows.map((l) => ({ id: l.id, label: l.label, region_label: l.regionLabel }));

Deno.serve(async (req) => {
  const pre = handleCors(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, { status: 405 });

  const userId = await callerUserId(req);
  if (!userId) return json({ error: "unauthorized" }, { status: 401 });

  let body: { city?: string | null; country?: string | null; number_type?: string | null } = {};
  try {
    body = await req.json();
  } catch {
    body = {};
  }

  const sb = admin();
  if (await isPaused(sb)) {
    return json({ error: "lines_paused" }, { status: 409 });
  }

  const country = (body.country ?? DEFAULT_COUNTRY).toUpperCase();
  const numberType = body.number_type ?? "local";

  // ── The gate ─────────────────────────────────────────────────────────────
  const sellable = await sellableCountry(sb, country, numberType);
  if (catalogFaultOf(sellable)) {
    // The client has a recovery path for this and needs somewhere to go, so the
    // 409 carries the (empty) place lists in the shapes it already decodes —
    // there are no localities for a country we will not sell, and an absent key
    // would decode as "the server did not answer that question".
    return json({
      error: "country_not_sellable",
      reason: sellable.reason === "country_not_sellable"
        ? (sellable.detail ?? "blocked")
        : sellable.reason,
      country,
      cities: [],
      localities: [],
    }, { status: 409 });
  }

  const localities = await localitiesFor(sb, country, numberType);

  // A named city must exist; an absent one takes the first curated locality,
  // which for CA is Toronto exactly as `DEFAULT_CITY` used to be (sort_order
  // 10). A country with NO curated localities searches country-wide rather
  // than refusing — that is the normal state outside Canada.
  const wantedKey = (body.city ?? "").toLowerCase();
  let place: LineLocality | null = null;
  if (wantedKey) {
    place = localities.find((l) => l.id === wantedKey) ?? null;
    if (!place) return json({ error: "unknown_city" }, { status: 400 });
  } else {
    place = localities[0] ?? null;
  }

  // ── The search ───────────────────────────────────────────────────────────
  // NANP walks area codes in order and stops at the first with stock — a city
  // is only reported unavailable once EVERY one of its codes is dry. Outside
  // NANP there are no area codes: Telnyx takes `locality` /
  // `administrative_area`, and one search answers.
  let numbers: AvailableNumber[] = [];
  let usedCode: string | null = null;
  let lastFault: string | null = null;

  const attempt = async (opts: { areaCode?: string; locality?: string; administrativeArea?: string }) =>
    await searchNumbers({
      country, numberType, limit: 8,
      // 🔴 FROM THE CATALOG, NEVER A LITERAL. The hardcoded `["sms","voice"]`
      // that used to live inside `searchNumbers` returns 400 `10015` on every
      // voice-only country and read as a provider outage.
      features: sellable.features,
      ...opts,
    });

  const codes = NANP.has(country) ? (place?.areaCodes ?? []) : [];

  if (codes.length > 0) {
    for (const code of codes) {
      const r = await attempt({ areaCode: code });
      if (faultOf(r)) {
        // OUT_OF_STOCK on one code is ordinary; keep walking. Anything else is
        // a real fault worth surfacing if no code works.
        lastFault = r.type;
        // Walking the remaining codes cannot help when the ACCOUNT is the
        // problem. It just multiplies the same failure by seven.
        if (r.type !== "OUT_OF_STOCK") break;
        continue;
      }
      if (r.length > 0) { numbers = r; usedCode = code; break; }
    }
  } else {
    const r = await attempt({
      locality: place?.locality ?? undefined,
      administrativeArea: place?.adminArea ?? undefined,
    });
    if (faultOf(r)) lastFault = r.type;
    else numbers = r;
  }

  const capabilities = {
    country: sellable.countryCode,
    country_name: sellable.countryName,
    supports_voice: sellable.supportsVoice,
    supports_sms: sellable.supportsSms,
    supports_mms: sellable.supportsMms,
    supports_emergency: sellable.supportsEmergency,
    number_type: sellable.numberType,
  };

  if (numbers.length === 0) {
    // 🔴 ONLY a genuine stockout may read as "no numbers available".
    //
    // `classifyTelnyxFault` returns BALANCE_ERROR for a 402 and TRANSPORT_ERROR
    // for anything it does not recognise, and both used to fall through to
    // `no_numbers_available` — so a dead API key, an empty Telnyx account or a
    // network outage told the user every city was sold out. That reads as the
    // product simply not working, and it is the exact failure
    // `classifyTelnyxFault`'s own comment warns about one layer down.
    const outage = lastFault != null && lastFault !== "OUT_OF_STOCK";
    if (outage) {
      console.error(JSON.stringify({
        alert: "line_search_provider_fault", country, city: place?.id ?? null,
        fault: lastFault,
      }));
    }
    return json({
      error: outage ? "provider_unreachable" : "no_numbers_available",
      city: place?.id ?? null,
      cities: legacyCities(localities),
      localities: localityList(localities),
      ...capabilities,
    }, { status: outage ? 502 : 409 });
  }

  return json({
    // ⚠️ NEVER null. `LineAvailability.city` is a non-optional `String` in the
    // shipped client, so a null here fails the whole decode and the picker
    // shows a network error. A country-wide search (no curated localities)
    // reports the empty string, which every consumer treats as "no city
    // chosen" — including `reserve-line-number`, which defaults it back.
    city: place?.id ?? "",
    label: place?.label ?? null,
    area_code: usedCode,
    cities: legacyCities(localities),
    localities: localityList(localities),
    ...capabilities,
    // `monthly_cents` is what TELNYX charges us. It is returned so the caller
    // can stamp it onto phone_lines at purchase — NOTHING reports the cost
    // again afterwards, so this quote is the only chance to record it. It is
    // never rendered: the user sees the subscription price, not our wholesale.
    numbers: numbers.map((n) => ({
      phone_number: n.phoneNumber,
      region: n.region,
      monthly_cents: n.monthlyCents,
      upfront_cents: n.upfrontCents,
      // Additive per-number capabilities. `features` is what the checkout
      // screen prefers over the country roll-up, because it describes the
      // specific number about to be bought.
      country_code: n.countryCode ?? sellable.countryCode,
      features: n.features,
      number_type: n.type,
      currency: n.currency,
    })),
  });
});
