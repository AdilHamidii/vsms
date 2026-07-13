import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import { livePriceUsd, providerOrder, release, reserve, type RouteCodes } from "../_shared/providers.ts";

interface Body {
  service_id: string;
  country_id: string;
}

// Verify-then-charge guard. Before reserving a number we re-check the LIVE
// provider price and refuse unless the credits we'd charge are worth at least
// MIN_MARGIN× that cost. Runs per candidate provider so we never lose money on
// a price spike, and we skip a provider (falling back) rather than overpay.
//
// NET_USD_PER_CREDIT: conservative net revenue per credit — the largest pack
// (30 cr / $12.99 ≈ $0.433) after Apple's cut. With the 5× retail model
// (credits = ceil(cost/0.10)) this clears comfortably.
const MIN_MARGIN = 1.8;
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

  const sb = admin();

  const { data: service, error: svcErr } = await sb
    .from("services").select("id, smspva_code, virtualsms_code")
    .eq("id", body.service_id).single();
  if (svcErr || !service) return json({ error: "unknown_service" }, { status: 404 });

  const { data: country, error: cErr } = await sb
    .from("countries").select("id, smspva_code, virtualsms_code, dial_code")
    .eq("id", body.country_id).single();
  if (cErr || !country) return json({ error: "unknown_country" }, { status: 404 });

  const { data: route, error: rErr } = await sb
    .from("routes")
    .select("retail_credits, status, last_cost_cents, provider")
    .eq("service_id", service.id)
    .eq("country_id", country.id)
    .maybeSingle();
  if (rErr) return json({ error: "route_lookup_failed", detail: rErr.message }, { status: 500 });
  if (!route || route.status !== "active" || route.retail_credits == null) {
    return json({ error: "route_unavailable" }, { status: 409 });
  }

  const cost = route.retail_credits as number;
  const codes: RouteCodes = {
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

  // Charge up-front so a mid-flight failure can't leak a free number; refund on
  // any path that doesn't end in a persisted order.
  const { data: spent, error: spendErr } = await sb.rpc("wallet_spend", {
    p_user: userId, p_amount: cost, p_reason: "spend",
  });
  if (spendErr) return json({ error: "spend_failed", detail: spendErr.message }, { status: 500 });
  if (spent === false) return json({ error: "insufficient_credits", needed: cost }, { status: 402 });

  const refund = () => sb.rpc("wallet_credit", { p_user: userId, p_amount: cost, p_reason: "refund" });

  // Try providers in preference order; on each, verify margin against the live
  // price, then reserve. Skip (fall back) on margin failure or a reserve error.
  let reservation = null as Awaited<ReturnType<typeof reserve>> | null;
  let used: (typeof providers)[number] | null = null;
  let lastError = "no_numbers_available";

  for (const p of providers) {
    let liveCost = await livePriceUsd(p, codes);
    if (liveCost == null && route.last_cost_cents != null && (route.last_cost_cents as number) > 0) {
      liveCost = (route.last_cost_cents as number) / 100; // graceful degrade to last synced cost
    }
    if (liveCost == null) { lastError = "route_unavailable"; continue; }
    if (cost * NET_USD_PER_CREDIT < MIN_MARGIN * liveCost) {
      console.warn(`margin_too_low provider=${p} svc=${service.id} cty=${country.id} credits=${cost} liveUsd=${liveCost}`);
      lastError = "margin_too_low";
      continue;
    }
    const res = await reserve(p, codes);
    if (res.ok) { reservation = res; used = p; break; }
    console.warn(`reserve failed provider=${p} svc=${service.id} cty=${country.id} err=${res.error}`);
    lastError = res.error ?? "no_numbers_available";
  }

  if (!reservation || !used) {
    await refund();
    const status = lastError === "margin_too_low" ? 409 : 503;
    return json({ error: lastError }, { status });
  }

  const { data: order, error: insertErr } = await sb
    .from("orders")
    .insert({
      user_id: userId,
      service_id: service.id,
      country_id: country.id,
      provider: used,
      smspva_id: reservation.orderId,      // generic: the provider's order id
      smspva_number: reservation.number,   // generic: display number
      cost_credits: cost,
      status: "waiting",
    })
    .select("*").single();

  if (insertErr || !order) {
    // Release the just-reserved number so we don't pay for an order we can't
    // track (and it wouldn't count against the provider's concurrent cap),
    // then refund the user.
    if (reservation.orderId) await release(used, reservation.orderId);
    await refund();
    return json({ error: "order_persist_failed", detail: insertErr?.message }, { status: 500 });
  }

  return json({ order });
});
