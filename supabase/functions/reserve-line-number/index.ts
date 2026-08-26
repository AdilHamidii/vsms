// Hold a specific number for one user while they decide, and — more
// importantly — REFUSE BEFORE APPLE CHARGES if we could not deliver it.
//
// ── Why the float check lives here and nowhere else ────────────────────────
//
// Every other product line in this app charges credits, which we control and
// can refund in the same transaction. This one charges through Apple, and an
// Apple refund is the one money path we cannot drive. So the ordering is
// inverted from `create-order`: there, the guard sits immediately before OUR
// charge; here it must sit before we ever show a paywall, because after that
// the money is gone and the only remedy is a refund we have to ask Apple for.
//
// That is the whole reason the flow is reserve → paywall → provision rather
// than paywall → provision. It costs a round trip and removes an entire class
// of "charged and got nothing".
//
// ── The price is re-quoted server-side, never taken from the client ────────
//
// The client sends a city and a number. We re-search that city and require the
// number to still be in OUR results before reserving it. That proves the number
// is real and still available, and it means the cost we check the balance
// against is a figure the server produced — the same discipline as the
// order-time price ceiling, which exists because a client-supplied price is a
// client-supplied spend.

import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import { countOccupiedLines } from "../_shared/lines.ts";
import {
  searchNumbers, reserveNumber, getBalance, faultOf, type AvailableNumber,
} from "../_shared/telnyx.ts";
import {
  sellableCountry, localitiesFor, catalogFaultOf, loadLineCatalogConfig,
  withinWholesaleCeiling, type LineLocality,
} from "../_shared/lineCatalog.ts";
import { NANP } from "../_shared/phone.ts";

/** The hardcoded CITIES map that used to sit here — a byte-for-byte copy of
 *  the one in `search-line-numbers`, plus a third in `rent-line-credits` — is
 *  gone. All three now read `public.line_localities`, which is what makes the
 *  three agree on what "Toronto" means BY CONSTRUCTION rather than by anyone
 *  remembering to edit three files. Reserving from a different pool than the
 *  picker showed is exactly the drift a duplicated constant produces. */
const DEFAULT_COUNTRY = "CA";

/** Headroom over the number's own first-month cost. Not a guess at future
 *  months — this only has to cover the purchase we are about to authorise.
 *
 *  ⚠️ Zeroed 2026-08-06 to allow the first test purchase on a $2.33 balance,
 *  which a Canadian number ($1.00 upfront + $1.00/month) missed by 17 cents.
 *  **RESTORED to 50 on 2026-08-07** now that the account holds $7.33 — the
 *  note said to restore it the moment it was funded, and an App Store reviewer
 *  subscribing in Sandbox provisions a REAL number, so this is exactly when a
 *  line must not be able to provision with nothing left behind it.
 *
 *  The guard fails CLOSED either way: we refuse unless the balance covers the
 *  upfront cost AND the first month, and an unquoted cost gets a full extra
 *  month via `unknownCostPad`. The buffer is the margin for what the number
 *  does AFTER it is bought — at zero, a line can provision with too little
 *  left to carry its own inbound traffic or its next month's rent. */
const BALANCE_BUFFER_CENTS = 50;

Deno.serve(async (req) => {
  const pre = handleCors(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, { status: 405 });

  const userId = await callerUserId(req);
  if (!userId) return json({ error: "unauthorized" }, { status: 401 });

  let body: {
    city?: string | null; phone_number?: string;
    country?: string | null; number_type?: string | null;
  } = {};
  try { body = await req.json(); } catch { /* handled by the guards below */ }

  const cityKey = (body.city ?? "").toLowerCase();
  const wanted = body.phone_number ?? "";
  // `country` defaults on BOTH null and absent — shipped 2.3 sends neither.
  const country = (body.country ?? DEFAULT_COUNTRY).toUpperCase();
  const numberType = body.number_type ?? "local";
  if (!wanted) return json({ error: "bad_request" }, { status: 400 });

  const sb = admin();

  // Fails CLOSED on a read error: a flag we cannot read must not be treated as
  // "not paused". Same precedent as the eSIM pause.
  const { data: pausedRow, error: pausedErr } = await sb.from("app_config")
    .select("value").eq("key", "lines_paused").maybeSingle();
  if (pausedErr || (pausedRow?.value as boolean | null) !== false) {
    return json({ error: "lines_paused" }, { status: 409 });
  }

  // The rental cap, checked BEFORE Apple charges — finding out at INSERT time
  // would mean finding out after the money moved.
  //
  // ⚠️ This was a one-line-per-user check on `.maybeSingle()`, which was right
  // while `phone_lines_one_live_per_user` guaranteed at most one and is now
  // wrong twice over: it ERRORS on a second row rather than refusing, and
  // refusing is no longer correct anyway — credits may rent several. Apple is
  // still capped at one, but that is enforced by
  // `phone_lines_one_apple_line_per_user`, which is Apple's own constraint
  // (one active subscription per group) rather than ours.
  const occupied = await countOccupiedLines(sb, userId);
  const { data: capRow } = await sb.from("app_config")
    .select("value").eq("key", "line_max_per_user").maybeSingle();
  const cap = Number(capRow?.value ?? 5) || 5;
  if (occupied >= cap) {
    return json({ error: "line_limit_reached", limit: cap }, { status: 409 });
  }

  // ── The country gate, BEFORE any provider call ───────────────────────────
  // Fails closed: a country we have never probed, whose probe is stale, or
  // whose catalog row we cannot read is REFUSED. `country_not_sellable` is a
  // different answer from `no_numbers_available` and must stay one — "this
  // country needs six regulatory documents" is not a stock problem, and telling
  // the user to pick another city sends them into the same wall forever.
  const cfg = await loadLineCatalogConfig(sb);
  const sellable = await sellableCountry(sb, country, numberType, cfg);
  if (catalogFaultOf(sellable)) {
    return json({
      error: "country_not_sellable",
      reason: sellable.reason === "country_not_sellable"
        ? (sellable.detail ?? "blocked")
        : sellable.reason,
      country,
    }, { status: 409 });
  }

  // Re-quote server-side. Walk the same localities the picker walked, in the
  // same order, and require the requested number to be in the result.
  const localities = await localitiesFor(sb, country, numberType);
  let place: LineLocality | null = null;
  if (cityKey) {
    place = localities.find((l) => l.id === cityKey) ?? null;
    // An unknown city id is a client/server disagreement about the catalog, not
    // a user error. Fall through to the country-wide/first-locality search
    // rather than 400-ing a purchase the user is midway through.
  }
  if (!place) place = localities[0] ?? null;

  const quote = async (opts: { areaCode?: string; locality?: string; administrativeArea?: string }) =>
    await searchNumbers({
      country, numberType, limit: 8,
      // From the catalog, never a literal — a hardcoded `["sms","voice"]`
      // returns 400 `10015` on a voice-only country.
      features: sellable.features,
      ...opts,
    });

  const codes = NANP.has(country) ? (place?.areaCodes ?? []) : [];
  let quoted: AvailableNumber[] = [];

  if (codes.length > 0) {
    for (const code of codes) {
      const r = await quote({ areaCode: code });
      if (faultOf(r)) {
        // Only a real stockout justifies trying the next code. A dead key, an
        // empty account or an outage is not a stock problem, and walking on
        // would end in `number_taken` — which tells the user to pick again,
        // into the same wall, right before we would have charged them.
        if (r.type !== "OUT_OF_STOCK") {
          console.error(JSON.stringify({
            alert: "line_reserve_provider_fault", country, city: cityKey,
            fault: r.type,
          }));
          return json({ error: "provider_unreachable" }, { status: 502 });
        }
        continue;
      }
      if (r.length > 0) { quoted = r; break; }
    }
  } else {
    const r = await quote({
      locality: place?.locality ?? undefined,
      administrativeArea: place?.adminArea ?? undefined,
    });
    if (faultOf(r)) {
      if (r.type !== "OUT_OF_STOCK") {
        console.error(JSON.stringify({
          alert: "line_reserve_provider_fault", country, city: cityKey,
          fault: r.type,
        }));
        return json({ error: "provider_unreachable" }, { status: 502 });
      }
    } else {
      quoted = r;
    }
  }

  const offer = quoted.find((n) => n.phoneNumber === wanted);
  // Gone between the picker and the tap. Ordinary, and the client re-searches
  // rather than treating it as an error — it must never provision a number
  // other than the one on screen.
  if (!offer) return json({ error: "number_taken" }, { status: 409 });

  // ── The wholesale ceiling, BEFORE the float check ────────────────────────
  // Deliberately in this order: "this number is too expensive to sell" and "we
  // cannot afford this number" are different problems with different fixes
  // (drop the country vs top up the account), and the alert keys must not be
  // the same one. The ceiling is a SAFETY guard, not pricing — it exists so the
  // line cannot quietly sell a $27/month DR Congo mobile against a $9.99
  // subscription. A non-USD quote is REFUSED here, never converted.
  const ceiling = withinWholesaleCeiling(offer, cfg, country);
  if (!ceiling.ok) {
    console.error(JSON.stringify({
      alert: "line_wholesale_ceiling", reason: ceiling.reason, country,
      number: wanted, monthly_cents: offer.monthlyCents,
      upfront_cents: offer.upfrontCents, currency: offer.currency,
      cost_known: offer.costKnown,
    }));
    return json({ error: "line_wholesale_ceiling", reason: ceiling.reason },
                { status: 409 });
  }

  // ── The float guard ──────────────────────────────────────────────────────
  // Fails CLOSED, unlike `create-order`'s balance guard which fails OPEN on a
  // stale reading. The asymmetry is deliberate: there, a wrong refusal costs a
  // credit sale we can retry; here, a wrong ALLOW means Apple charges $9.99 for
  // a number we cannot buy.
  // ⚠️ `costKnown` is what stops this guard silently stopping. When Telnyx
  // omits `cost_information`, both figures used to parse to ZERO — so the whole
  // check degraded to "do we have 50 cents?" and would have waved through a
  // purchase we could not afford, with Apple's $9.99 already taken. The adapter
  // now substitutes the measured US/CA rate and says it did; a substituted
  // quote gets a full month of extra headroom rather than being trusted.
  const unknownCostPad = offer.costKnown ? 0 : offer.monthlyCents;
  const needCents = offer.upfrontCents + offer.monthlyCents +
                    BALANCE_BUFFER_CENTS + unknownCostPad;
  if (!offer.costKnown) {
    console.error(JSON.stringify({
      alert: "line_cost_unquoted", number: wanted, assumed_cents: offer.monthlyCents,
    }));
  }
  const bal = await getBalance();
  if (faultOf(bal)) return json({ error: "provider_unreachable" }, { status: 502 });
  if (Math.round(bal.usd * 100) < needCents) {
    console.error(JSON.stringify({
      alert: "line_float_exhausted",
      balance_usd: bal.usd,
      need_cents: needCents,
      number: wanted,
    }));
    return json({ error: "line_unavailable" }, { status: 409 });
  }

  // ── The hold ─────────────────────────────────────────────────────────────
  // Never probed live (see `reserveNumber`). Snapshot the balance either side
  // of the first call so ONE real invocation settles whether a hold costs
  // anything, rather than us assuming it is free the way `regulatory_
  // requirements: null` was assumed to mean "no paperwork" — a $3.83 lesson.
  const before = bal.usd;
  const held = await reserveNumber(wanted, `vsms-${userId}`);
  let heldUntil: string | null = null;
  let reservationId: string | null = null;

  if (faultOf(held)) {
    // ORDINARY. The client renders a number with no hold as "Available now"
    // and the purchase still works — a reservation is a nicety, not a
    // prerequisite. Recorded so a permanently-failing endpoint is visible
    // rather than silently degrading forever.
    console.log(JSON.stringify({ reserve_fault: held.type, detail: held.detail }));
  } else {
    heldUntil = held.expiresAt;
    reservationId = held.reservationId;
    const after = await getBalance();
    if (!faultOf(after)) {
      const deltaCents = Math.round((before - after.usd) * 100);
      await sb.from("app_config").upsert({
        key: "telnyx_reservation_cost",
        value: {
          delta_cents: deltaCents,
          measured_at: new Date().toISOString(),
          note: deltaCents === 0
            ? "reservations are FREE — measured, not assumed"
            : "reservations COST money — check before holding at scale",
        },
      }, { onConflict: "key" });
    }
  }

  return json({
    phone_number: offer.phoneNumber,
    region: offer.region,
    // ⚠️ Echoes what the CLIENT asked for, not what we resolved. `city` is a
    // non-optional String in the shipped client and the checkout screen carries
    // it straight through to the purchase, so substituting our own default here
    // would silently move the user's pick.
    city: cityKey,
    held_until: heldUntil,
    reservation_id: reservationId,
    // Additive capability block — the checkout screen prefers this over the
    // country roll-up because it describes the specific number being bought.
    country: sellable.countryCode,
    country_name: sellable.countryName,
    supports_voice: sellable.supportsVoice,
    supports_sms: sellable.supportsSms,
    supports_mms: sellable.supportsMms,
    supports_emergency: sellable.supportsEmergency,
    number_type: offer.type,
    country_code: offer.countryCode ?? sellable.countryCode,
    features: offer.features,
    currency: offer.currency,
    // Never rendered. Carried so `verify-line-subscription` can stamp it onto
    // phone_lines.monthly_cost_cents — nothing reports the cost again after
    // purchase, so this quote is the only chance to record it.
    monthly_cents: offer.monthlyCents,
    upfront_cents: offer.upfrontCents,
  });
});
