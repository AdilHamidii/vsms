import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import { livePriceUsd, markDead, providerOrder, release, reserve, type RouteCodes } from "../_shared/providers.ts";
import { getCountryPrices, isOk } from "../_shared/smspva.ts";
import { notifySafe, esc } from "../_shared/telegram.ts";

interface Body {
  service_id: string;
  country_id: string;
  /** "standard" (default; random SMSPVA pool — today's behavior) or
   *  "premium" (pinned to the route's real-SIM operator, fail-fast). Old
   *  clients never send this. */
  tier?: string;
}

// Verify-then-charge guard. Before reserving a number we re-check the LIVE
// provider price and refuse unless the credits we'd charge are worth at least
// MIN_MARGIN× that cost. Runs per candidate provider so we never lose money on
// a price spike, and we skip a provider (falling back) rather than overpay.
//
// NET_USD_PER_CREDIT: conservative net revenue per credit — the 30-credit pack
// ($12.99 ≈ $0.433) after Apple's cut, which is the least favourable rung of the
// live ladder. Deliberately pessimistic: valuing a credit high here would let a
// route clear the margin gate on revenue we might not actually collect.
//
// The floor itself is the credits charged being worth at least MARGIN× the
// wholesale cost. That makes the order-time ceiling exactly the pricing sync's
// implied cost line, so honestly-priced routes always clear and anything
// pricier than what we charged is capped or refused. Moving one without the
// other either blocks honest routes or leaks margin.
// PER-PROVIDER since 2026-07-31. The ceiling below is `credits * NET / MARGIN`
// and MUST equal the divisor the route was PRICED with, exactly:
//
//   provider   priced by            divisor    MIN_MARGIN   0.30 / MARGIN
//   herosms    sync-herosms           0.025        12.0         0.025  ✓
//   smspva     sync-prices            0.05          6.0         0.05   ✓
//
// A single global constant cannot express this any more, and getting it wrong
// is silent in the worst direction: too low and every honestly-priced route is
// refused with margin_too_low — charged and instantly refunded — until the next
// sync repriced it, which is exactly what produced 11 of 22 orders in 24h
// closing in under a second with no number on 2026-07-27.
//
// Why the two differ at all: HeroSMS wholesale is far cheaper, so at a shared
// 0.05 its routes would price into the 1-credit band, which measures 18%
// delivery against 46-59% for 2-8 credits. Applying 0.025 to BOTH instead would
// double SMSPVA — 60% of the catalog, and the better-delivering provider — and
// take its 3-credit reach from 729 routes to 16. See the block in sync-herosms.
const MIN_MARGIN_BY_PROVIDER: Record<string, number> = {
  herosms: 12.0,
  smspva: 6.0,
};
/** Falls back to the strictest value we use, never to the loosest: an unknown
 *  provider must under-spend rather than overpay on a route nobody priced. */
const MIN_MARGIN_FALLBACK = 12.0;
const marginFor = (provider: string | null | undefined): number =>
  MIN_MARGIN_BY_PROVIDER[provider ?? ""] ?? MIN_MARGIN_FALLBACK;

const NET_USD_PER_CREDIT = 0.30;

// Absolute slack added to the order-time ceiling so a trivial provider price
// tick doesn't take a route offline between hourly sync-prices runs. Flat, not
// proportional, on purpose: the exposure is bounded at $0.10 per order at any
// price point, while a percentage would grow precisely where it costs most.
// Worst case it trades margin on the cheapest routes (a 2-credit route worth
// $0.60 of revenue may now pay up to $0.20, i.e. 3× rather than 6×) to stop
// losing the order outright — a refunded order earns nothing and burns trust.
const CEILING_HEADROOM_USD = 0.10;

// ── Failure paging. A total SMS outage used to be indistinguishable from a
//    quiet day: every failed order refunded politely, console.error'd, and no
//    human ever heard. Two channels, both deduped through app_config state:
//    • streak: N consecutive failed order attempts (any cause) pages at 5,
//      then every 6h while it persists; any success resets it.
//    • fault: AUTH_ERROR / BALANCE_ERROR means the provider ACCOUNT is dead
//      (revoked key, empty balance) — that pages immediately, 6h dedupe.
const FAIL_STREAK_ALERT_AT = 5;
const REALERT_MS = 6 * 60 * 60 * 1000;
type Admin = ReturnType<typeof admin>;

async function bumpFailStreak(sb: Admin, lastError: string, routeDesc: string): Promise<void> {
  try {
    const { data } = await sb
      .from("app_config").select("value").eq("key", "order_fail_streak").maybeSingle();
    const v = (data?.value ?? {}) as { n?: number; last_alert_at?: string };
    const n = (v.n ?? 0) + 1;
    const due = !v.last_alert_at ||
      Date.now() - new Date(v.last_alert_at).getTime() >= REALERT_MS;
    const value: Record<string, unknown> = { n, last_alert_at: v.last_alert_at ?? null };
    if (n >= FAIL_STREAK_ALERT_AT && due) {
      // Only record the alert if it actually sent — otherwise one dropped
      // Telegram message buys 6h of silence on an active outage.
      const sent = await notifySafe(
        `🚨 <b>${n} consecutive SMS order failures</b>\n` +
        `latest: ${esc(lastError)} on ${esc(routeDesc)}\n` +
        `Users are being charged and refunded with no numbers delivered.`,
      );
      if (sent) value.last_alert_at = new Date().toISOString();
      else console.error("fail-streak page FAILED to send — will retry next failure");
    }
    await sb.from("app_config").upsert({ key: "order_fail_streak", value }, { onConflict: "key" });
  } catch (e) {
    console.error("fail-streak tracking failed (ignored):", e);
  }
}

async function resetFailStreak(sb: Admin): Promise<void> {
  try {
    const { data } = await sb
      .from("app_config").select("value").eq("key", "order_fail_streak").maybeSingle();
    if (((data?.value as { n?: number } | null)?.n ?? 0) > 0) {
      await sb.from("app_config")
        .upsert({ key: "order_fail_streak", value: { n: 0 } }, { onConflict: "key" });
    }
  } catch (e) {
    console.error("fail-streak reset failed (ignored):", e);
  }
}

async function alertProviderFault(sb: Admin, provider: string, errorType: string, detail: string): Promise<void> {
  try {
    const { data } = await sb
      .from("app_config").select("value").eq("key", "provider_fault_alert").maybeSingle();
    const last = (data?.value as { last_at?: string } | null)?.last_at;
    if (last && Date.now() - new Date(last).getTime() < REALERT_MS) return;
    // Send BEFORE stamping the 6h suppression window, and only stamp on
    // success. Stamping first meant a single failed send silenced "the provider
    // account is dead" for six hours.
    const sent = await notifySafe(
      `🚨 <b>${esc(provider)} account fault: ${esc(errorType)}</b>\n${esc(detail)}\n` +
      `Every order on this provider will fail until this is fixed (key revoked or balance empty).`,
    );
    if (!sent) {
      console.error("provider-fault page FAILED to send — not suppressing, will retry");
      return;
    }
    await sb.from("app_config").upsert({
      key: "provider_fault_alert",
      value: { last_at: new Date().toISOString(), provider, error_type: errorType },
    }, { onConflict: "key" });
  } catch (e) {
    console.error("provider-fault alert failed (ignored):", e);
  }
}

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, { status: 405 });

  const userId = await callerUserId(req);
  if (!userId) return json({ error: "unauthorized" }, { status: 401 });

  let body: Body;
  try { body = await req.json(); }
  catch { return json({ error: "invalid_body" }, { status: 400 }); }
  if (!body.service_id || !body.country_id) {
    return json({ error: "missing_fields" }, { status: 400 });
  }
  const tier = body.tier ?? "standard";
  if (tier !== "standard" && tier !== "premium") {
    return json({ error: "invalid_body" }, { status: 400 });
  }

  const sb = admin();

  const { data: service, error: svcErr } = await sb
    .from("services").select("id, smspva_code, herosms_code")
    .eq("id", body.service_id).single();
  if (svcErr || !service) return json({ error: "unknown_service" }, { status: 404 });

  const { data: country, error: cErr } = await sb
    .from("countries").select("id, smspva_code, herosms_id, dial_code")
    .eq("id", body.country_id).single();
  if (cErr || !country) return json({ error: "unknown_country" }, { status: 404 });

  const { data: route, error: rErr } = await sb
    .from("routes")
    .select("retail_credits, status, last_cost_cents, herosms_cost_cents, herosms_physical_count, herosms_real_operator, real_sim_only, provider, smspool_pool, smspva_operator, smspva_operator_cents, premium_credits")
    .eq("service_id", service.id)
    .eq("country_id", country.id)
    .maybeSingle();
  if (rErr) return json({ error: "route_lookup_failed", detail: rErr.message }, { status: 500 });
  if (!route || route.status !== "active" || route.retail_credits == null) {
    return json({ error: "route_unavailable" }, { status: 409 });
  }
  // Premium = "pin a NAMED carrier", and each provider names one differently:
  // SMSPVA via sync-smspva-operators (`smspva_operator`), HeroSMS via the
  // per-country operator probe (`herosms_real_operator`). Either way the route
  // must carry a `premium_credits` price, which is what the checkout chips key
  // off — selling a tier the client cannot price is a dead end.
  //
  // HeroSMS used to be refused outright here because there was no pin to apply;
  // there is now, so the refusal is gone. It remains a HARD refusal when the
  // route has no carrier: downgrading silently would charge the 20% uplift and
  // reserve exactly the standard fill.
  const premiumPin = route.provider === "smspva"
    ? (route.smspva_operator as string | null)
    : route.provider === "herosms"
      ? (route.herosms_real_operator as string | null)
      : null;
  if (tier === "premium" && (premiumPin == null || route.premium_credits == null)) {
    return json({ error: "premium_unavailable" }, { status: 409 });
  }

  // The mirror case: services that reject VoIP are sold ONLY as Real SIM, so a
  // standard order on such a route would knowingly hand back a number the
  // service will refuse. Refuse it instead of taking the money.
  if (tier !== "premium" && route.real_sim_only === true) {
    return json({ error: "real_sim_required" }, { status: 409 });
  }

  // Idempotency backstop against a double-submit (fast double-tap, a retry, or
  // two devices): if the user already has a live 'waiting' order for this exact
  // service+country from the last few seconds, return it instead of charging +
  // reserving a second number. The client also guards this on the main actor;
  // this makes the server safe even if that guard is bypassed. A short window
  // (not a blanket rule) so a deliberate repeat order later still works.
  // Dedupe + charge now happen together in begin_order (one transaction, an
  // advisory lock per user). The old version SELECTed here and INSERTed ~200
  // lines later, with a multi-second provider call in between — two concurrent
  // requests both passed this check and both charged.
  const cost = tier === "premium"
    ? route.premium_credits as number
    : route.retail_credits as number;
  const codes: RouteCodes = {
    heroService: service.herosms_code,
    heroCountry: country.herosms_id,
    smsService: service.smspva_code,
    smsCountry: country.smspva_code,
    dial: country.dial_code,
  };

  // ── Retry steering context. A retry is the one moment we KNOW the previous
  // number/pool failed this user — use that knowledge instead of re-selling it.
  // Measured 2026-07-24: one user's 9 Betano attempts drew only 6 distinct
  // numbers, every attempt pinned to the same carrier. Best-effort: on any
  // error both sets stay empty and behavior is exactly today's.
  const recentNumbers = new Set<string>();
  const triedOperators = new Set<string>();
  try {
    const { data: recent } = await sb
      .from("orders")
      .select("smspva_number, smspool_pool, country_id, provider, status, closed_at")
      .eq("user_id", userId)
      .eq("service_id", service.id)
      .gte("created_at", new Date(Date.now() - 60 * 60 * 1000).toISOString());
    for (const r of recent ?? []) {
      if (r.smspva_number) recentNumbers.add(r.smspva_number as string);
      if (
        // 'expired' counts too: an order that held the full window with no SMS
        // is the STRONGEST evidence that carrier is dead, and rotation was
        // ignoring it entirely — only user-cancels populated this set.
        r.provider === "smspva" && r.smspool_pool &&
        (r.status === "canceled" || r.status === "expired") &&
        r.country_id === country.id && r.closed_at &&
        Date.now() - new Date(r.closed_at as string).getTime() <= 15 * 60 * 1000
      ) triedOperators.add(r.smspool_pool as string);
    }
  } catch (e) {
    console.warn("retry-context read failed (ignored):", e);
  }

  // ONE provider, no fallback (owner decision 2026-07-30). `route.provider`
  // only reflects the display-price source, not the fulfilment preference —
  // providerOrder() is the single routing truth and reads only the codes.
  const providers = providerOrder(codes);
  if (providers.length === 0) return json({ error: "route_unavailable" }, { status: 409 });

  // Write the order row AND charge, atomically. Every paid attempt now has a
  // row from this point on, so a failure below is recorded instead of vanishing
  // — 51% of all charge attempts previously left no trace, which is why the
  // real failure rate was never measurable.
  const { data: begun, error: beginErr } = await sb.rpc("begin_order", {
    p_user: userId,
    p_service: service.id,
    p_country: country.id,
    p_credits: cost,
    p_tier: tier,
  });
  if (beginErr) {
    return json({ error: "spend_failed", detail: beginErr.message }, { status: 500 });
  }

  const begunStatus = (begun as { status?: string } | null)?.status;
  const orderId = (begun as { order_id?: string } | null)?.order_id;

  if (begunStatus === "insufficient_credits") {
    return json({ error: "insufficient_credits", needed: cost }, { status: 402 });
  }
  if (begunStatus === "duplicate" && orderId) {
    const { data: dupe } = await sb.from("orders").select("*").eq("id", orderId).single();
    return json({ order: dupe, deduped: true });
  }
  if (begunStatus !== "ok" || !orderId) {
    return json({ error: "spend_failed", detail: String(begunStatus) }, { status: 500 });
  }

  /** Close the reserved row and return the credits. Linked to the order, so the
   *  ledger reconciles and the attempt stays visible as a closed order rather
   *  than disappearing. */
  const failOrder = async (reason: string) => {
    // CLAIM-GATED. This refund used to be unconditional, which minted credits:
    // begin_order commits the `waiting` row and charges BEFORE the provider
    // loop runs, and that row is readable over PostgREST immediately. A user
    // could cancel-order it mid-loop (refund #1), then this function would lose
    // the flip and refund again (#2) — repeatable, +cost credits per round.
    // The `order_persist_failed` path was worse than a race: reaching it MEANS
    // something else already flipped the row, and every such path refunds.
    // Every other terminal writer (cancel-order, poll-active-orders,
    // check-order) already gates on the row count; this was the only hole.
    const { data: claimed, error: cErr } = await sb
      .from("orders")
      .update({ status: "canceled", closed_at: new Date().toISOString() })
      .eq("id", orderId)
      .eq("status", "waiting")
      .select("id");
    if (cErr) {
      console.error("failOrder: could not close order", orderId, cErr);
      return;
    }
    if (!claimed || claimed.length === 0) {
      // Someone else already closed and refunded this order. Refunding here
      // would be a second credit for one charge.
      console.warn(`failOrder: lost the claim for ${orderId} (reason=${reason}) — refund already issued elsewhere, skipping`);
      return;
    }
    // supabase-js RETURNS errors, it does not throw, and wallet_credit RAISES
    // on a missing wallet row or non-positive amount. This is the busiest
    // failure path in the order flow (margin_too_low, stockout and provider
    // faults all land here) — discarding the error left the order terminal,
    // the user charged, and the console.warn below looking identical to a
    // clean refund. Mirrors the guard cancel-order already had.
    const { error: refundErr } = await sb.rpc("wallet_credit", {
      p_user: userId, p_amount: cost, p_reason: "refund", p_order: orderId,
    });
    if (refundErr) {
      // Roll back to 'waiting' so the expiry sweep closes and refunds it a
      // minute later — every recovery path requires status='waiting', so
      // leaving it terminal makes the charge PERMANENTLY unrefundable.
      // `wallet_transactions_refund_once_idx` makes the retry safe.
      console.error(`create-order: REFUND FAILED order=${orderId} user=${userId} ` +
                    `credits=${cost}: ${refundErr.message} — reverting to waiting`);
      await sb.from("orders")
        .update({ status: "waiting", closed_at: null })
        .eq("id", orderId).eq("status", "canceled");
      return;
    }
    console.warn(`create-order failed svc=${service.id} cty=${country.id} reason=${reason} order=${orderId}`);
  };

  // Try providers in preference order; on each, verify margin against the live
  // price, then reserve. Skip (fall back) on margin failure or a reserve error.
  let reservation = null as Awaited<ReturnType<typeof reserve>> | null;
  let used: (typeof providers)[number] | null = null;
  let usedCostUsd: number | null = null;
  let lastError = "no_numbers_available";

  // The most we can pay and still keep MIN_MARGIN on what we charged. Passed
  // to the provider as a purchase-time cap AND enforced on the actual charged
  // cost — the live quote is per cheapest pool and does not bind the fill
  // price (seen live: wechat/kg quoted 6¢, uncapped purchase filled at 79¢).
  //
  // + CEILING_HEADROOM_USD, because without it this ceiling has ZERO tolerance
  // on most of the catalog. sync-prices sets retail = ceil(cost / 0.05) and
  // this computes cost * 0.05, so whenever wholesale lands on an exact 5¢
  // boundary the cap equals the cost to the cent — measured 2026-07-27:
  // 12,507 of 16,303 active routes (76.7%) sat at exactly zero headroom. A
  // one-cent rise at SMSPVA then made `liveCost > maxCostUsd` true and every
  // order on that route was refused with margin_too_low, charged, and instantly
  // refunded until the next hourly sync-prices repriced it. That is what
  // produced 11 of 22 orders in 24h closing in <1s with no number, and it also
  // fed the auto-hide (see 20260727120000) which removed TikTok/Netherlands
  // from the catalog on 8 orders that never got a number.
  //
  // Resolved from the route's OWN provider, because the two are priced at
  // different divisors — see MIN_MARGIN_BY_PROVIDER. `route.provider` is the
  // right source: providerOrder() returns exactly one provider per service and
  // there is no cross-provider fallback, so the row we priced is the row we buy.
  const minMargin = marginFor(route.provider as string | null);
  const maxCostUsd = (cost * NET_USD_PER_CREDIT) / minMargin + CEILING_HEADROOM_USD;

  // ── Real-SIM carrier ─────────────────────────────────────────────────────
  //
  // `routes.herosms_real_operator` is the named carrier with the most stock for
  // this route, resolved per country by `sync-herosms`. It replaced an earlier
  // `app_config.force_physical_operator` that pinned the single operator
  // `physic` for the whole of the US — which turned out to be one narrow pool,
  // empty for services holding thousands of real numbers elsewhere (badoo/us:
  // physic 0, verizon 14,224, textnow 458,985).
  //
  // Premium pins the route's named carrier STRICTLY (a dry carrier fails and
  // refunds). Standard pins it OPPORTUNISTICALLY — same as the SMSPVA arm
  // below — so a dry carrier, or one over the ceiling, falls back to the
  // general pool instead of losing the sale.
  //
  // Standard must NOT be left unpinned. The tier chips that let a user choose
  // are in the 1.5 archive still awaiting review, and `defaultPremium` is in
  // build 19 — so every order a real user places today is `standard`. Leaving
  // it unpinned put US orders straight back onto a pool that is ~99.97% VoIP
  // (`textnow` alone is 458,985 of ~477,000 numbers), which took 175 of 198
  // credits charged for ZERO codes in the 12h before this was first fixed.
  // Opportunistic pinning costs nothing: the worst case is the old behaviour.
  const heroCarrier = route.herosms_real_operator as string | null;

  // Standard orders pin the route's real-SIM carrier too, whenever it fits
  // the margin ceiling. Probed 2026-07-21: on all 16,320 active routes the
  // carrier costs the same or LESS than a random fill — random just means
  // "probably a Donor* pool", the stock strict services reject. reserve()
  // falls back to a random fill if the carrier is dry (premium doesn't).
  const standardCarrier =
    route.smspva_operator != null && route.smspva_operator_cents != null &&
      (route.smspva_operator_cents as number) / 100 <= maxCostUsd
      ? route.smspva_operator as string
      : null;

  // ── Operator rotation. If the pin we'd use is one this user just failed
  // on, pick a different real carrier from the live per-operator price map
  // (getCountryPrices → po). The alternate must be untried, non-Donor (the
  // anonymized VoIP pools strict services reject), and inside the same
  // margin ceiling as any other fill. Fallbacks: standard → unpinned (at
  // least a different pool than the one that just failed), premium → keep
  // the route pin (the buyer paid for THAT real-SIM pool; never downgrade).
  let smspvaPin: string | null = tier === "premium"
    ? route.smspva_operator as string
    : standardCarrier;
  let rotatedPinUsd: number | null = null;
  if (
    smspvaPin != null && triedOperators.has(smspvaPin) &&
    country.smspva_code && service.smspva_code
  ) {
    try {
      const pr = await getCountryPrices(country.smspva_code as string);
      const row = isOk(pr)
        ? pr.data.find((x) => x.s === service.smspva_code)
        : null;
      const alt = Object.entries(row?.po ?? {})
        .map(([op, usd]) => ({ op, usd: parseFloat(usd) }))
        .filter(({ op, usd }) =>
          !triedOperators.has(op) &&
          !op.toLowerCase().startsWith("donor") &&
          Number.isFinite(usd) && usd <= maxCostUsd)
        .sort((a, b) => a.usd - b.usd)[0] ?? null;
      if (alt) {
        console.warn(`operator rotation: ${smspvaPin} already failed this user — pinning ${alt.op} svc=${service.id} cty=${country.id}`);
        smspvaPin = alt.op;
        rotatedPinUsd = alt.usd;
      } else if (tier !== "premium") {
        console.warn(`operator rotation: ${smspvaPin} already failed this user, no eligible alternate — unpinned svc=${service.id} cty=${country.id}`);
        smspvaPin = null;
      }
    } catch (e) {
      console.warn("operator rotation lookup failed (ignored):", e);
    }
  }

  for (const p of providers) {
    // Premium margins are checked against the pinned operator's own price —
    // livePriceUsd returns the country/service BASE price, usually the
    // cheapest pool, which can sit well under the carrier we actually buy from
    // (whatsapp/UK: base 1.40, Giffgaff 6.00). But smspva_operator_cents is a
    // DAILY-cached column (sync-smspva-operators cursor): if SMSPVA raised
    // prices since the last pass it is stale-LOW, and checking margin against
    // it alone would sell under floor for up to ~24h. So take the HIGHER of
    // the cached operator price and the live base price — a broad live price
    // rise is caught immediately, the carrier premium is still respected.
    let liveCost: number | null;
    if (tier === "premium" && (rotatedPinUsd != null || route.smspva_operator_cents != null)) {
      const opUsd = rotatedPinUsd ?? (route.smspva_operator_cents as number) / 100;
      // Was `p === "smspva" ? ... : null`, which meant any OTHER provider had
      // its premium margin gate evaluated against a frozen SMSPVA operator
      // price and never once looked at what it was actually about to be
      // charged. livePriceUsd() is provider-generic; ask it.
      const liveBase = await livePriceUsd(p, codes);
      liveCost = liveBase != null ? Math.max(opUsd, liveBase) : opUsd;
    } else {
      liveCost = await livePriceUsd(p, codes);
    }
    // Graceful degrade to the last SYNCED cost — but only to a cost synced for
    // THIS provider.
    //
    // `last_cost_cents` is written by sync-prices, which prices SMSPVA and
    // deliberately skips non-SMSPVA rows. So on a HeroSMS route it holds a
    // frozen SMSPVA number. Falling back to it margin-checked a HeroSMS
    // purchase against a retired provider's price, and for routes HeroSMS
    // cannot serve at all (livePriceUsd -> null) that stale cost PASSED the
    // gate — the reservation then failed NO_NUMBERS and the user was charged,
    // refunded, and told to "try another country or service". ~16% of HeroSMS
    // routes were in that state.
    //
    // A HeroSMS route with no HeroSMS cost is now correctly unavailable rather
    // than sellable-then-broken. sync-herosms hides those routes; this is the
    // belt to that braces, for the window before it next runs.
    const cachedCents = p === "herosms"
      ? (route.herosms_cost_cents as number | null)
      : (route.last_cost_cents as number | null);
    if (liveCost == null && cachedCents != null && cachedCents > 0) {
      liveCost = cachedCents / 100;
    }
    if (liveCost == null) { lastError = "route_unavailable"; continue; }
    if (liveCost > maxCostUsd) {
      console.warn(`margin_too_low provider=${p} tier=${tier} svc=${service.id} cty=${country.id} credits=${cost} liveUsd=${liveCost}`);
      lastError = "margin_too_low";
      continue;
    }
    // smspva rides the real-SIM carrier (mandatory for premium, opportunistic
    // for standard). smspvaPin already encodes the tier rule plus any rotation
    // away from a carrier this user just failed on.
    //
    // This used to read `p === "smspva" ? smspvaPin : route.smspool_pool`. Any
    // future provider MUST get its own explicit arm here — the old else-branch
    // silently handed an SMSPool pool name to whatever provider ran next.
    // Any future provider MUST get its own explicit arm here — the old
    // else-branch silently handed an SMSPool pool name to whatever provider
    // ran next.
    const pin = p === "smspva" ? smspvaPin
              : p === "herosms" ? heroCarrier
              : null;
    // Strict when the buyer paid for a specific real-SIM pool (premium), and
    // strict when policy forces one — both mean "this pool or nothing".
    // Strict only for premium: that buyer paid for THAT pool and must never
    // be silently downgraded. Standard may fall back, which is exactly what
    // makes the opportunistic pin free.
    const strictPin = tier === "premium";
    // Fresh-number guarantee: SMSPVA re-issues a just-canceled number to the
    // same buyer. If the fill matches a number this user already drew for
    // this service in the last hour, release it and draw again — at most 3
    // draws. A still-duplicate final draw is kept: a repeat number beats no
    // number. release() never throws (logged internally), and only a
    // SUCCESSFUL duplicate fill re-enters the loop — reserve errors take the
    // existing error path unchanged.
    let res = await reserve(p, codes, maxCostUsd, pin, strictPin);
    for (
      let redraw = 0;
      redraw < 2 && res.ok && res.number && recentNumbers.has(res.number);
      redraw++
    ) {
      console.warn(`duplicate number re-issued (${res.number}) — redrawing svc=${service.id} cty=${country.id}`);
      // markDead, not release. A plain cancelorder leaves the request id alive
      // at SMSPVA for ~10 minutes and the SAME number gets re-allocated — so
      // discarding a duplicate with release() fought retention using the exact
      // mechanism that causes it. Measured: 13.9% of paid orders drew a
      // re-issued number, and those delivered 21.4% against 36.8% for a first
      // issuance. markDead bans first, then cancels, so the wholesale refund is
      // still attempted.
      if (res.orderId) await markDead(p, res.orderId);
      res = await reserve(p, codes, maxCostUsd, pin, strictPin);
    }
    if (res.ok) {
      if (res.costUsd != null && res.costUsd > maxCostUsd + 0.001) {
        console.warn(`actual_cost_over_ceiling provider=${p} svc=${service.id} cty=${country.id} credits=${cost} paidUsd=${res.costUsd} maxUsd=${maxCostUsd}`);
        if (res.orderId) await release(p, res.orderId).catch(() => {});
        lastError = "margin_too_low";
        continue;
      }
      reservation = res; used = p; usedCostUsd = res.costUsd ?? liveCost; break;
    }
    console.warn(`reserve failed provider=${p} svc=${service.id} cty=${country.id} err=${res.error}`);
    // Map the provider's documented failure types onto codes the app already
    // has copy for. Previously every one of these arrived as raw provider text
    // (SMSPool wraps them in HTML), matched nothing in APIError.userMessage,
    // and fell through to "Something went wrong on our side." — the least
    // actionable message, on the most common failure.
    lastError = res.errorType === "OUT_OF_STOCK"    ? "no_numbers_available"
              : res.errorType === "PRICE_NOT_FOUND" ? "margin_too_low"
              : res.errorType === "BALANCE_ERROR"   ? "provider_unreachable"
              : res.errorType === "RATE_LIMITED"    ? "provider_unreachable"
              : res.errorType === "AUTH_ERROR"      ? "provider_unreachable"
              // A timeout or socket failure is NOT a stockout. Without this arm
              // it fell through to no_numbers_available, telling the user to
              // "try another country" for a network problem — and worse, a
              // timeout on the BUY call may mean the number was allocated and
              // billed, so it must be visible rather than filed as scarcity.
              : res.errorType === "TRANSPORT_ERROR" ? "provider_unreachable"
              : res.error === "number_never_activated" ? "no_numbers_available"
              : "no_numbers_available";
    if (res.errorType === "TRANSPORT_ERROR") {
      console.error(`${p} TRANSPORT_ERROR — possible orphaned paid reservation: ${res.error}`);
    }
    if (res.errorType === "BALANCE_ERROR" || res.errorType === "AUTH_ERROR") {
      console.error(`${p} ${res.errorType} — orders will keep failing until fixed: ${res.error}`);
      try {
        EdgeRuntime.waitUntil(alertProviderFault(sb, p, res.errorType, res.error ?? ""));
      } catch { /* paging must never affect the order path */ }
    }
  }

  if (!reservation || !used) {
    await failOrder(lastError);
    try {
      EdgeRuntime.waitUntil(bumpFailStreak(sb, lastError, `${service.id}/${country.id} (${tier})`));
    } catch { /* paging must never affect the order path */ }
    const status = lastError === "margin_too_low" ? 409 : 503;
    return json({ error: lastError }, { status });
  }

  // UPDATE, not insert: the row already exists (begin_order wrote it with the
  // charge). Attach the reservation to it. Guarded on status='waiting' so a
  // row the expiry sweep has already closed underneath us is not resurrected.
  const { data: rows, error: insertErr } = await sb
    .from("orders")
    .update({
      provider: used,
      smspva_id: reservation.orderId,      // generic: the provider's order id
      smspva_number: reservation.number,   // generic: display number
      actual_cost_cents: usedCostUsd != null ? Math.round(usedCostUsd * 100) : null,
      smspool_pool: reservation.pool ?? null,
      // Real-SIM stock on this route at the moment we reserved. Recorded so the
      // VoIP hypothesis behind `voip_strict_services` can be TESTED rather than
      // believed — without it we would hide inventory on a plausible story and
      // never be able to tell whether it helped. Null means "not recorded",
      // never "no real SIMs".
      route_physical_count: (route.herosms_physical_count as number | null) ?? null,
      // Honour the provider's own hold window when it tells us one. The DB
      // default is a flat 8 minutes, but SMSPool's window is pool-dependent
      // (their docs show 1200s) — expiring first meant refunding and
      // abandoning a number we had already paid to hold. Never EXTEND past 8
      // minutes though: every code we have ever received arrived within 337s,
      // so a longer wait only leaves the user staring at a dead number.
      //
      // Always written, not just when the provider reports a deadline: the DB
      // default stamps expires_at at INSERT, which is before the provider
      // loop runs (margin checks, an operator-rotation price lookup that can
      // block up to 10s, and up to two duplicate-number redraws). That time
      // came out of the user's live-number window even though they had no
      // number yet. Measuring from the moment the number actually exists is
      // what the 8 minutes was always meant to be.
      expires_at: new Date(Math.min(
        reservation.expiresAt != null ? reservation.expiresAt * 1000 : Number.MAX_SAFE_INTEGER,
        Date.now() + 8 * 60 * 1000,
      )).toISOString(),
    })
    .eq("id", orderId)
    .eq("status", "waiting")
    .select("*");

  const order = rows && rows.length > 0 ? rows[0] : null;

  if (order) {
    try {
      EdgeRuntime.waitUntil(resetFailStreak(sb));
    } catch { /* paging must never affect the order path */ }
  }

  if (insertErr || !order) {
    // Release the just-reserved number so we don't pay for an order we can't
    // track (and it wouldn't count against the provider's concurrent cap),
    // then close the row and refund the user.
    if (reservation.orderId) await release(used, reservation.orderId);
    await failOrder("order_persist_failed");
    return json({ error: "order_persist_failed", detail: insertErr?.message }, { status: 500 });
  }

  return json({ order });
});
