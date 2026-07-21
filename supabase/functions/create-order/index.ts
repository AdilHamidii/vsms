import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import { livePriceUsd, providerOrder, release, reserve, type RouteCodes } from "../_shared/providers.ts";

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
// NET_USD_PER_CREDIT: conservative net revenue per credit — the largest pack
// (30 cr / $12.99 ≈ $0.433) after Apple's cut. With the 5× retail model
// (credits = ceil(cost/0.10)) this clears comfortably.
// 3× floor: the credits charged must be worth at least 3× the wholesale cost,
// valued at the most conservative pack. This makes the order-time ceiling
// (credits * NET / MIN_MARGIN = credits * $0.10) exactly the sync formula's
// implied cost line (credits = ceil(cost / 0.10)) — honestly-priced routes
// always clear, anything pricier than what we charged is capped or refused.
const MIN_MARGIN = 3.0;
const NET_USD_PER_CREDIT = 0.30;

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
    .from("services").select("id, smspva_code, virtualsms_code, smspool_code")
    .eq("id", body.service_id).single();
  if (svcErr || !service) return json({ error: "unknown_service" }, { status: 404 });

  const { data: country, error: cErr } = await sb
    .from("countries").select("id, smspva_code, virtualsms_code, smspool_code, dial_code")
    .eq("id", body.country_id).single();
  if (cErr || !country) return json({ error: "unknown_country" }, { status: 404 });

  const { data: route, error: rErr } = await sb
    .from("routes")
    .select("retail_credits, status, last_cost_cents, provider, smspool_pool, smspva_operator, smspva_operator_cents, premium_credits")
    .eq("service_id", service.id)
    .eq("country_id", country.id)
    .maybeSingle();
  if (rErr) return json({ error: "route_lookup_failed", detail: rErr.message }, { status: 500 });
  if (!route || route.status !== "active" || route.retail_credits == null) {
    return json({ error: "route_unavailable" }, { status: 409 });
  }
  // Premium exists only where sync-smspva-operators found a real-SIM carrier
  // it could price. The app hides the option when premium_credits is null, so
  // hitting this means a stale client cache — same remedy as a dead route.
  if (tier === "premium" && (route.smspva_operator == null || route.premium_credits == null)) {
    return json({ error: "premium_unavailable" }, { status: 409 });
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
    spService: service.smspool_code,
    spCountry: country.smspool_code,
    vsService: service.virtualsms_code,
    vsCountry: country.virtualsms_code,
    smsService: service.smspva_code,
    smsCountry: country.smspva_code,
    dial: country.dial_code,
  };

  // virtualsms is always tried first where it has a code (real-SIM quality);
  // SMSPVA is the fallback. route.provider only reflects the display-price
  // source, not the fulfilment preference.
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
    const { error: cErr } = await sb
      .from("orders")
      .update({ status: "canceled", closed_at: new Date().toISOString() })
      .eq("id", orderId)
      .eq("status", "waiting");
    if (cErr) console.error("failOrder: could not close order", orderId, cErr);
    await sb.rpc("wallet_credit", {
      p_user: userId, p_amount: cost, p_reason: "refund", p_order: orderId,
    });
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
  const maxCostUsd = (cost * NET_USD_PER_CREDIT) / MIN_MARGIN;

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

  for (const p of providers) {
    // Premium margins are checked against the pinned operator's own synced
    // price — livePriceUsd returns the country/service BASE price, which is
    // usually the cheapest pool and can sit well under the carrier we will
    // actually buy from (whatsapp/UK: base 1.40, Giffgaff 6.00).
    let liveCost = tier === "premium" && route.smspva_operator_cents != null
      ? (route.smspva_operator_cents as number) / 100
      : await livePriceUsd(p, codes);
    if (liveCost == null && route.last_cost_cents != null && (route.last_cost_cents as number) > 0) {
      liveCost = (route.last_cost_cents as number) / 100; // graceful degrade to last synced cost
    }
    if (liveCost == null) { lastError = "route_unavailable"; continue; }
    if (liveCost > maxCostUsd) {
      console.warn(`margin_too_low provider=${p} tier=${tier} svc=${service.id} cty=${country.id} credits=${cost} liveUsd=${liveCost}`);
      lastError = "margin_too_low";
      continue;
    }
    // Pin per provider: smspva rides the real-SIM carrier (mandatory for
    // premium, opportunistic for standard); smspool keeps its pool pin.
    const pin = p === "smspva"
      ? (tier === "premium" ? route.smspva_operator as string : standardCarrier)
      : route.smspool_pool;
    const res = await reserve(p, codes, maxCostUsd, pin, tier === "premium");
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
              : res.error === "number_never_activated" ? "no_numbers_available"
              : "no_numbers_available";
    if (res.errorType === "BALANCE_ERROR" || res.errorType === "AUTH_ERROR") {
      console.error(`SMSPOOL ${res.errorType} — orders will keep failing until fixed: ${res.error}`);
    }
  }

  if (!reservation || !used) {
    await failOrder(lastError);
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
      // Honour the provider's own hold window when it tells us one. The DB
      // default is a flat 8 minutes, but SMSPool's window is pool-dependent
      // (their docs show 1200s) — expiring first meant refunding and
      // abandoning a number we had already paid to hold. Never EXTEND past the
      // default though: every code we have ever received arrived within 337s,
      // so a longer wait only leaves the user staring at a dead number.
      ...(reservation.expiresAt
        ? { expires_at: new Date(Math.min(
            reservation.expiresAt * 1000,
            Date.now() + 8 * 60 * 1000,
          )).toISOString() }
        : {}),
    })
    .eq("id", orderId)
    .eq("status", "waiting")
    .select("*");

  const order = rows && rows.length > 0 ? rows[0] : null;

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
