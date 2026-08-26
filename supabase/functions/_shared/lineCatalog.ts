// The single gate every rentable-line seller calls before touching Telnyx.
//
// 🔴 IT FAILS CLOSED ON EVERY AMBIGUITY, AND THAT IS THE WHOLE POINT.
//
// The failure this exists to prevent is not abstract: a GB number was bought
// on the strength of `regulatory_requirements: null` in a search response,
// arrived `requirement-info-pending` with six outstanding documents, could
// never be used, and cost $3.83. Multiply that by an Apple subscription and
// the user has paid $9.99 for a number that will never ring, on a money path
// we cannot refund from our side.
//
// So a country sells only when a LIVE PROBE says so, recorded in
// `line_country_catalog`. Missing row, stale probe, unreadable table — all
// three refuse. There is no `force_sell` override anywhere in this system by
// design (see the migration's own comment): no opinion may overrule a probe
// that says end-user documents are required.
//
// ── The other half: what to SEARCH with ───────────────────────────────────
//
// `searchNumbers` used to hardcode `features=[sms,voice]`, which returns
// **400 `10015`** on every voice-only country (GB, DE, FR, NL, PL, AU local —
// measured 2026-08-26) and therefore read as a provider outage. The features
// a search may filter on are a fact about the country, so they come from the
// catalog row and never from a literal.

// ⚠️ The SAME specifier `supabaseAdmin.ts` builds its client from. `_shared/
// lines.ts` imports this type from `jsr:@supabase/supabase-js@2` instead, and
// the two resolve to DIFFERENT declarations — so every call site passing
// `admin()` into it fails `deno check` with a `_getSessionToken is missing`
// mismatch. Deploy does not type-check, so that has been invisible in
// production; it is still noise that hides a real error, so do not copy it.
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import { NANP } from "./phone.ts";
import type { AvailableNumber } from "./telnyx.ts";

/** Why a country cannot be sold right now. Distinct values on purpose: "we
 *  have never probed this country", "our probe is stale" and "the database is
 *  unreadable" are three different operational problems, and collapsing them
 *  into one message is how the last one hides for a week. */
export type CatalogRefusal =
  | "country_not_sellable"
  | "catalog_stale"
  | "catalog_unreadable";

export interface CatalogFault {
  catalogFault: true;
  reason: CatalogRefusal;
  /** The catalog's own `sell_reason` when it has one (`documents_required`,
   *  `never_probed`, `no_voice`, `order_rejected`, `owner_blocked`), so the
   *  client and the ops log can say WHICH wall this is. */
  detail: string | null;
}

export function catalogFaultOf<T>(v: T | CatalogFault): v is CatalogFault {
  return typeof v === "object" && v !== null &&
    (v as CatalogFault).catalogFault === true;
}

export interface SellableCountry {
  countryCode: string;
  numberType: string;
  /** Exactly what to pass `searchNumbers({features})`. Built from the catalog's
   *  capability columns; never a literal. */
  features: string[];
  /** Only ever set when the group is APPROVED. A pending or rejected group is
   *  no better than none, and passing one would attach an unusable bundle to a
   *  real purchase. */
  requirementGroupId: string | null;
  supportsSms: boolean;
  supportsVoice: boolean;
  supportsMms: boolean;
  supportsEmergency: boolean;
  countryName: string | null;
}

export interface LineLocality {
  id: string;
  countryCode: string;
  label: string;
  regionLabel: string | null;
  /** Ordered most-stock-first. NANP walks these; outside NANP they are empty
   *  and `locality`/`adminArea` are the Telnyx filters instead. */
  areaCodes: string[];
  locality: string | null;
  adminArea: string | null;
  numberType: string;
}

export interface LineCatalogConfig {
  maxAgeHours: number;
  ceilingMonthlyCents: number;
  ceilingUpfrontCents: number;
}

/** Defaults matching `20260826160000_line_country_catalog.sql`. A missing key
 *  must not disable the freshness rule or the ceiling — an absent config is
 *  exactly the state in which a guard silently stops guarding, which this repo
 *  has already paid for twice (`smspva_health`, `smspva_retired`). */
const DEFAULTS: LineCatalogConfig = {
  maxAgeHours: 48,
  ceilingMonthlyCents: 300,
  ceilingUpfrontCents: 500,
};

const CONFIG_KEYS = [
  "line_country_catalog_max_age_hours",
  "line_wholesale_ceiling_monthly_cents",
  "line_wholesale_ceiling_upfront_cents",
];

/** ONE `app_config` read per request. Both the sellability gate and the
 *  wholesale ceiling need config; loading it once and passing it down is what
 *  keeps a picker keystroke from firing three round trips. */
export async function loadLineCatalogConfig(
  sb: SupabaseClient,
): Promise<LineCatalogConfig> {
  const { data, error } = await sb.from("app_config")
    .select("key, value").in("key", CONFIG_KEYS);
  if (error || !data) return { ...DEFAULTS };
  const num = (key: string, fallback: number) => {
    const row = (data as Array<{ key: string; value: unknown }>)
      .find((r) => r.key === key);
    const n = Number(row?.value);
    return Number.isFinite(n) && n > 0 ? n : fallback;
  };
  return {
    maxAgeHours: num(CONFIG_KEYS[0], DEFAULTS.maxAgeHours),
    ceilingMonthlyCents: num(CONFIG_KEYS[1], DEFAULTS.ceilingMonthlyCents),
    ceilingUpfrontCents: num(CONFIG_KEYS[2], DEFAULTS.ceilingUpfrontCents),
  };
}

const CATALOG_COLUMNS =
  "country_code, number_type, country_name, supports_voice, supports_sms, " +
  "supports_mms, supports_emergency, reservable, requirements_empty, " +
  "requirement_group_id, requirement_group_status, requirements_checked_at, " +
  "coverage_checked_at, sell_state, sell_reason";

interface CatalogRow {
  country_code: string;
  number_type: string;
  country_name: string | null;
  supports_voice: boolean | null;
  supports_sms: boolean | null;
  supports_mms: boolean | null;
  supports_emergency: boolean | null;
  reservable: boolean | null;
  requirements_empty: boolean | null;
  requirement_group_id: string | null;
  requirement_group_status: string | null;
  requirements_checked_at: string | null;
  coverage_checked_at: string | null;
  sell_state: string;
  sell_reason: string | null;
}

/** Which capability filters a search may safely send for this country.
 *
 *  ⚠️ Only capabilities the catalog says are TRUE are ever sent. `supports_sms`
 *  is NULL until probed, and sending `sms` on the strength of a null is exactly
 *  the 400-`10015` false stockout this whole change exists to remove.
 *
 *  For US/CA — `supports_sms` and `supports_voice` both true — this yields
 *  `["sms","voice"]`, i.e. byte-identical to the hardcoded filter the NANP
 *  path has always sent and been proven against. */
function searchFeatures(row: CatalogRow): string[] {
  const f: string[] = [];
  if (row.supports_sms === true) f.push("sms");
  if (row.supports_voice === true) f.push("voice");
  return f;
}

function hoursSince(iso: string | null): number | null {
  if (!iso) return null;
  const t = Date.parse(iso);
  if (!Number.isFinite(t)) return null;
  return (Date.now() - t) / 3_600_000;
}

/**
 * May we sell a number in this country, and if so what do we search with?
 *
 * Fails closed four ways, each with its own reason:
 *
 *  - **`catalog_unreadable`** — the query errored. Never treated as "no such
 *    country": a database we cannot read must not be able to open a country OR
 *    to silently close one without saying which happened.
 *  - **`country_not_sellable`** — no row, or `sell_state <> 'sellable'`. The
 *    catalog's own `sell_reason` rides along in `detail`.
 *  - **`catalog_stale`** — the probe backing this decision is older than
 *    `app_config.line_country_catalog_max_age_hours`. Regulatory status changes
 *    without telling us, and a year-old "no documents needed" is a guess.
 *  - a row whose relevant timestamp is missing entirely is stale by the same
 *    rule (never probed ⇒ blocked).
 *
 * ⚠️ The requirements probe is only part of the freshness test when it is what
 * the decision RESTS on. A country selling under an APPROVED requirement group
 * does not need a fresh requirements read — the group is the evidence, and
 * failing that country closed on an old probe would take a legitimately
 * pre-verified market offline for no reason.
 */
export async function sellableCountry(
  sb: SupabaseClient,
  country: string,
  numberType = "local",
  cfg?: LineCatalogConfig,
): Promise<SellableCountry | CatalogFault> {
  const cc = String(country ?? "").trim().toUpperCase();
  if (!cc) {
    return { catalogFault: true, reason: "country_not_sellable", detail: "no_country" };
  }

  const { data, error } = await sb.from("line_country_catalog")
    .select(CATALOG_COLUMNS)
    .eq("country_code", cc)
    .eq("number_type", numberType)
    .maybeSingle();

  if (error) {
    console.error(JSON.stringify({
      alert: "line_catalog_unreadable", country: cc, number_type: numberType,
      detail: error.message,
    }));
    return { catalogFault: true, reason: "catalog_unreadable", detail: null };
  }
  const row = data as CatalogRow | null;
  if (!row) {
    return { catalogFault: true, reason: "country_not_sellable", detail: "never_probed" };
  }
  if (row.sell_state !== "sellable") {
    return {
      catalogFault: true, reason: "country_not_sellable",
      detail: row.sell_reason ?? "blocked",
    };
  }

  const approvedGroup = row.requirement_group_id &&
    row.requirement_group_status === "approved"
      ? row.requirement_group_id
      : null;

  const maxAge = (cfg ?? await loadLineCatalogConfig(sb)).maxAgeHours;
  const relevant: Array<string | null> = [row.coverage_checked_at];
  if (!approvedGroup) relevant.push(row.requirements_checked_at);
  for (const stamp of relevant) {
    const age = hoursSince(stamp);
    if (age === null || age > maxAge) {
      console.error(JSON.stringify({
        alert: "line_catalog_stale", country: cc, number_type: numberType,
        age_hours: age, max_age_hours: maxAge,
      }));
      return { catalogFault: true, reason: "catalog_stale", detail: row.sell_reason };
    }
  }

  return {
    countryCode: cc,
    numberType,
    features: searchFeatures(row),
    requirementGroupId: approvedGroup,
    supportsSms: row.supports_sms === true,
    supportsVoice: row.supports_voice === true,
    supportsMms: row.supports_mms === true,
    supportsEmergency: row.supports_emergency === true,
    countryName: row.country_name,
  };
}

/**
 * What to search and order with for a country we are NOT gating on — a swap,
 * which keeps an existing paying line alive and must not be refused because the
 * country's regulatory status moved after it was sold.
 *
 * `features` is `[]` on any doubt, and `[]` means NO FILTER — the safe
 * direction, because an unfiltered search returns rows while a wrong filter
 * returns 400 `10015` and reads as an outage.
 *
 * `requirementGroupId` is non-null only for an APPROVED group, exactly as in
 * `sellableCountry`: a pending group attached to a real order is worse than
 * none, because it looks like paperwork was filed.
 */
export async function searchProfileFor(
  sb: SupabaseClient, country: string, numberType = "local",
): Promise<{ features: string[]; requirementGroupId: string | null }> {
  const { data, error } = await sb.from("line_country_catalog")
    .select("supports_voice, supports_sms, requirement_group_id, requirement_group_status")
    .eq("country_code", String(country ?? "").toUpperCase())
    .eq("number_type", numberType)
    .maybeSingle();
  if (error || !data) return { features: [], requirementGroupId: null };
  const row = data as CatalogRow;
  return {
    features: searchFeatures(row),
    requirementGroupId: row.requirement_group_id &&
      row.requirement_group_status === "approved" ? row.requirement_group_id : null,
  };
}

/** The curated localities of a country, ordered. Replaces the three hardcoded
 *  CITIES maps, which had already drifted into three copies of one constant —
 *  the exact shape this repo has watched break before. */
export async function localitiesFor(
  sb: SupabaseClient, country: string, numberType = "local",
): Promise<LineLocality[]> {
  const { data, error } = await sb.from("line_localities")
    .select("id, country_code, label, region_label, area_codes, locality, admin_area, number_type")
    .eq("country_code", String(country ?? "").toUpperCase())
    .eq("number_type", numberType)
    .eq("enabled", true)
    .order("sort_order", { ascending: true });
  if (error || !data) return [];
  return (data as Array<Record<string, unknown>>).map((r) => ({
    id: String(r.id),
    countryCode: String(r.country_code),
    label: String(r.label),
    regionLabel: (r.region_label as string | null) ?? null,
    areaCodes: Array.isArray(r.area_codes) ? (r.area_codes as string[]) : [],
    locality: (r.locality as string | null) ?? null,
    adminArea: (r.admin_area as string | null) ?? null,
    numberType: String(r.number_type),
  }));
}

export type CeilingResult =
  | { ok: true }
  | { ok: false; reason: "currency_not_usd" | "cost_unknown" | "line_wholesale_ceiling" };

/**
 * A SAFETY ceiling on what we will pay Telnyx for one number. **Not pricing.**
 *
 * The plan price is flat and the wholesale is stamped live, so nothing here
 * decides what a user is charged — this only stops the line quietly selling a
 * $27/month DR Congo mobile or a $40/month Botswana toll-free against a
 * $9.99 subscription, which is what the 2026-08-05 sweep found sitting in the
 * requirement-free set.
 *
 * Three refusals, in the order they can bite:
 *
 *  1. **A non-USD quote is REFUSED, never converted.** We hold no rate table we
 *     control, and a EUR figure compared against USD cents is a guard that
 *     wrongly ALLOWS. Telnyx quoted GB and DE in USD when probed, so this is a
 *     tripwire rather than a routine path — and it must stay a refusal, because
 *     the day it fires is the day a conversion would have been silently wrong.
 *  2. **An unquoted cost outside NANP is REFUSED.** `searchNumbers` substitutes
 *     the measured US/CA $1.00 when `cost_information` is absent, and says so
 *     via `costKnown`. That figure is a fact about NANP and a guess anywhere
 *     else — see the constants' own comment.
 *  3. The monthly or upfront figure exceeding its configured ceiling.
 */
export function withinWholesaleCeiling(
  offer: Pick<AvailableNumber, "monthlyCents" | "upfrontCents" | "costKnown" | "currency">,
  ceilings: Pick<LineCatalogConfig, "ceilingMonthlyCents" | "ceilingUpfrontCents">,
  country: string,
): CeilingResult {
  const cur = (offer.currency ?? "USD").toUpperCase();
  if (cur !== "USD") return { ok: false, reason: "currency_not_usd" };

  const cc = String(country ?? "").toUpperCase();
  if (!offer.costKnown && !NANP.has(cc)) {
    return { ok: false, reason: "cost_unknown" };
  }

  if (offer.monthlyCents > ceilings.ceilingMonthlyCents ||
      offer.upfrontCents > ceilings.ceilingUpfrontCents) {
    return { ok: false, reason: "line_wholesale_ceiling" };
  }
  return { ok: true };
}
