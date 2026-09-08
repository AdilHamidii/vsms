// Rent a number with CREDITS — the path that makes several numbers possible.
//
// Apple cannot express "three numbers": one active subscription per group, and
// `quantity` applies only to consumables. Credits have no such limit, so this
// is the only route to the multi-number product. `verify-line-subscription` is
// its Apple-billed sibling and stays exactly as it is; the provisioning half
// below is deliberately the SAME sequence, in the same order, because that
// sequence is what has already been debugged:
//
//   1. re-quote server-side          (never trust a client's number or price)
//   2. begin_credit_line_rental      (charge + row, ONE transaction)
//   3. orderNumber                   (customer_reference = line id)
//   4. record_line_order             (the only handle on an async purchase)
//   5. poll getOrder
//   6. attachMessagingProfile        (routes inbound SMS to our webhook)
//   7. activate_line_claim           (stamp the ids, flip to active)
//
// 🔴 EVERY failure after step 2 must refund. The money moved before the
// provider was ever called — deliberately, so a Telnyx failure can never leave
// a purchased number with nothing pointing at it — which means the refund is
// not a nicety, it is the other half of the charge. `refund_credit_line_claim`
// does the status flip and the credit in one transaction and clears the rent
// tombstone so a retry can charge again legitimately.

import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import { searchNumbers, faultOf, type AvailableNumber } from "../_shared/telnyx.ts";
import {
  completeLineProvision, DEFAULT_LINE_COUNTRY,
} from "../_shared/lineProvision.ts";
import {
  sellableCountry, localitiesFor, catalogFaultOf, loadLineCatalogConfig,
  withinWholesaleCeiling, type LineLocality,
} from "../_shared/lineCatalog.ts";
import { NANP } from "../_shared/phone.ts";

/** The third copy of the hardcoded CITIES map lived here. All three now read
 *  `public.line_localities`, so the picker, the reserve step and this one agree
 *  on what "Toronto" means by construction rather than by anyone remembering
 *  to edit three files. */
const DEFAULT_COUNTRY = DEFAULT_LINE_COUNTRY;

/** Owner decision 2026-08-06: 20 credits/month for 100 SMS + 50 minutes.
 *  A credit nets $0.397 blended, so this is ~$7.94 against ~$1 rent plus
 *  ~$2.15 worst-case usage. The allowance is deliberately smaller than the
 *  Apple plan's: credits are cheaper in bulk, so a 150-pack buyer nets us
 *  ~$6.80 and the full 200/100 would leave ~$1.50. */
const RENT_CREDITS = 20;
const SMS_ALLOWANCE = 100;
const VOICE_ALLOWANCE_SECONDS = 3000;

async function refund(sb: ReturnType<typeof admin>, lineId: string, reason: string) {
  const { data, error } = await sb.rpc("refund_credit_line_claim", { p_line: lineId });
  // NEVER silent. This is the only thing that returns the user's credits, and
  // supabase-js RETURNS errors rather than throwing — a discarded one here is
  // the exact shape of the four wallet_credit bugs this repo has already paid
  // for.
  if (error || data !== true) {
    console.error(JSON.stringify({
      alert: "line_credit_refund_failed",
      line: lineId, reason, detail: error?.message ?? "claim returned false",
    }));
  }
}

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
  try { body = await req.json(); } catch { /* guarded below */ }

  const cityKey = (body.city ?? "").toLowerCase();
  const wanted = body.phone_number ?? "";
  // Defaults on BOTH null and absent — shipped 2.3 sends neither.
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

  // ── 1. Re-quote. The client's number is a REQUEST, not a fact. ───────────
  // Walk the same codes in the same order the picker did and require the
  // requested number to still be in the result, so a stale pick fails here
  // rather than after the credits are gone.
  // ⚠️ `monthlyCents` is captured HERE and nowhere else. Neither the order
  // response nor the number resource ever reports a cost again — the order
  // returns `cost_information: null` and the resource has no price field at
  // all — so this quote is the only chance to record what Telnyx charges US.
  // Losing it makes margin analysis on this line impossible.
  // The country gate, before any provider call and long before the charge.
  // Fails CLOSED — unreadable, missing and stale all refuse, each with its own
  // reason, because `country_not_sellable` and `no_numbers_available` send a
  // user to completely different places.
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

  const localities = await localitiesFor(sb, country, numberType);
  let place: LineLocality | null = null;
  if (cityKey) place = localities.find((l) => l.id === cityKey) ?? null;
  if (!place) place = localities[0] ?? null;

  const quote = async (opts: { areaCode?: string; locality?: string; administrativeArea?: string }) =>
    await searchNumbers({
      country, numberType, limit: 8,
      // From the catalog, never a literal.
      features: sellable.features,
      ...opts,
    });

  let monthlyCents: number | null = null;
  let offer: AvailableNumber | null = null;
  const codes = NANP.has(country) ? (place?.areaCodes ?? []) : [];

  if (codes.length > 0) {
    for (const code of codes) {
      const r = await quote({ areaCode: code });
      if (faultOf(r)) {
        // Only a real stockout justifies trying the next code — a dead key or
        // an outage is not a stock problem, and walking on would end in a
        // misleading "that number is taken".
        if (r.type !== "OUT_OF_STOCK") {
          return json({ error: "provider_unreachable" }, { status: 502 });
        }
        continue;
      }
      const m = r.find((n) => n.phoneNumber === wanted);
      if (m) { offer = m; break; }
    }
  } else {
    const r = await quote({
      locality: place?.locality ?? undefined,
      administrativeArea: place?.adminArea ?? undefined,
    });
    if (faultOf(r)) {
      if (r.type !== "OUT_OF_STOCK") {
        return json({ error: "provider_unreachable" }, { status: 502 });
      }
    } else {
      offer = r.find((n) => n.phoneNumber === wanted) ?? null;
    }
  }
  if (!offer) return json({ error: "number_taken" }, { status: 409 });
  monthlyCents = offer.monthlyCents ?? null;

  // ── 1b. The wholesale ceiling, BEFORE the charge ─────────────────────────
  // A SAFETY guard, never pricing. Refusing here costs the user nothing;
  // refusing after `begin_credit_line_rental` would mean charging credits for a
  // number we then have to hand back. A non-USD quote is refused, never
  // converted, and an unquoted cost outside NANP is refused rather than padded.
  const ceiling = withinWholesaleCeiling(offer, cfg, country);
  if (!ceiling.ok) {
    console.error(JSON.stringify({
      alert: "line_wholesale_ceiling", context: "rent_credits",
      reason: ceiling.reason, country, number: wanted,
      monthly_cents: offer.monthlyCents, upfront_cents: offer.upfrontCents,
      currency: offer.currency, cost_known: offer.costKnown,
    }));
    return json({ error: "line_wholesale_ceiling", reason: ceiling.reason },
                { status: 409 });
  }

  // ── 2. Charge + row, ONE transaction. ────────────────────────────────────
  // Enforces the pause, the per-user cap and the balance, all under the same
  // advisory lock, and rolls the row back if the spend fails.
  const { data: begun, error: beginErr } = await sb.rpc("begin_credit_line_rental", {
    p_user: userId,
    p_e164: wanted,
    p_country: country,
    p_number_type: numberType,
    p_rent_credits: RENT_CREDITS,
    p_sms_allowance: SMS_ALLOWANCE,
    p_voice_allowance_seconds: VOICE_ALLOWANCE_SECONDS,
  });
  if (beginErr) {
    console.error(JSON.stringify({ alert: "line_rent_begin_failed", detail: beginErr.message }));
    return json({ error: "provision_failed" }, { status: 500 });
  }
  if (!begun?.ok) {
    const reason = String(begun?.reason ?? "provision_failed");
    // `insufficient_credits` and `line_limit_reached` are the user's to act on
    // and must not read as our fault; both are 409 with the reason intact.
    return json({ error: reason, limit: begun?.limit ?? null }, { status: 409 });
  }
  const lineId = String(begun.line_id);

  // Which locality this number came from. `begin_credit_line_rental` has no
  // `p_locality` argument, and widening a SQL signature that six paths call is
  // a far larger change than one nullable stamp — so it is written here.
  // Best-effort and non-fatal: it is only ever read by a non-NANP SWAP, which
  // falls back to a country-wide search when it is absent. Outside NANP there
  // is no area code to recover it from later, which is the whole reason the
  // column exists.
  if (place?.id) {
    const { error: locErr } = await sb.from("phone_lines")
      .update({ locality: place.id }).eq("id", lineId);
    if (locErr) {
      console.error(JSON.stringify({
        alert: "line_locality_unrecorded", line: lineId, locality: place.id,
        detail: locErr.message,
      }));
    }
  }

  // ── 3-7. Buy it, configure it, activate it ───────────────────────────────
  // ONE sequence, shared with `verify-line-subscription` and with the
  // reprovision path in `apple-notifications` (`_shared/lineProvision.ts`).
  // 🔴 EVERY failure after step 2 refunds — the money moved before the provider
  // was ever called, so the refund is the other half of the charge, and that is
  // what `onFail` carries here.
  const done = await completeLineProvision(sb, {
    lineId, e164: wanted, country, numberType,
    requirementGroupId: sellable.requirementGroupId,
    // The period the rent just bought. `begin_credit_line_rental` already set
    // current_period_end and next_debit_at 30 days out; this keeps the claim's
    // own view consistent with them.
    periodEnd: new Date(Date.now() + 30 * 86_400_000).toISOString(),
    // From the server-side re-quote above, never from the request: this is what
    // we PAY, and a client-supplied cost is a client-supplied margin.
    monthlyCents,
    onFail: (reason) => refund(sb, lineId, reason),
  });
  if (!done.ok) {
    return json({ error: done.reason }, { status: done.status });
  }
  const e164 = done.e164;

  return json({
    ok: true, line_id: lineId, e164, rent_credits: RENT_CREDITS,
    inbound_ready: done.inboundReady,
  });
});
