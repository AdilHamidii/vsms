import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import { getNumber, getServicePrice, isOk } from "../_shared/smspva.ts";

interface Body {
  service_id: string;
  country_id: string;
}

// Verify-then-charge guard. Before charging the user or reserving a number we
// re-check the LIVE SMSPVA price and refuse the order unless the credits we'd
// charge are worth at least MIN_MARGIN× that cost. This closes the loss vectors
// a stale synced price opens (price spiked since last sync, or a route frozen
// at a too-low seed), and the multiplier also buffers the random-operator
// variance (getNumber with no operator can land on a pricier operator than the
// base price we check here).
//
// NET_USD_PER_CREDIT is the conservative net revenue per credit: the largest
// pack (30 cr / $12.99 ≈ $0.433) after Apple's 30% cut. Using the floor means
// an order that clears the gate is profitable across every pack. Raise it
// toward the gross ~0.43 if you'd rather abort fewer orders.
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
    .from("services").select("id, smspva_code, cost").eq("id", body.service_id).single();
  if (svcErr || !service) return json({ error: "unknown_service" }, { status: 404 });

  const { data: country, error: cErr } = await sb
    .from("countries").select("id, smspva_code, dial_code").eq("id", body.country_id).single();
  if (cErr || !country) return json({ error: "unknown_country" }, { status: 404 });

  const { data: route, error: rErr } = await sb
    .from("routes")
    .select("retail_credits, status, last_cost_cents")
    .eq("service_id", service.id)
    .eq("country_id", country.id)
    .maybeSingle();
  if (rErr) return json({ error: "route_lookup_failed", detail: rErr.message }, { status: 500 });
  // A route is bookable only if it is active AND has a confirmed retail price.
  // Falling back to service.cost when retail_credits is null could undercharge
  // the user vs the actual SMSPVA cost — refuse instead.
  if (!route || route.status !== "active" || route.retail_credits == null) {
    return json({ error: "route_unavailable" }, { status: 409 });
  }

  const cost = route.retail_credits as number;

  // Verify-then-charge: re-read the live SMSPVA price and refuse if this order
  // wouldn't clear MIN_MARGIN. Runs BEFORE wallet_spend and the getNumber
  // reservation, so a rejected order costs the user nothing.
  let liveCostUsd: number | null = null;
  try {
    const priceResp = await getServicePrice(country.smspva_code, service.smspva_code);
    if (isOk(priceResp) && Number.isFinite(priceResp.data?.price) && priceResp.data.price > 0) {
      liveCostUsd = priceResp.data.price;
    }
  } catch {
    // Live lookup failed — fall back to the last synced cost below.
  }
  // Graceful degradation: if the live price is unavailable, fall back to the
  // last synced cost so a transient price-endpoint hiccup doesn't block all
  // sales. If we have neither, refuse rather than sell on an unknown cost.
  if (liveCostUsd == null && route.last_cost_cents != null && (route.last_cost_cents as number) > 0) {
    liveCostUsd = (route.last_cost_cents as number) / 100;
  }
  if (liveCostUsd == null) {
    return json({ error: "route_unavailable" }, { status: 409 });
  }
  if (cost * NET_USD_PER_CREDIT < MIN_MARGIN * liveCostUsd) {
    console.warn(`margin_too_low service=${service.id} country=${country.id} credits=${cost} liveCostUsd=${liveCostUsd}`);
    return json({
      error: "margin_too_low",
      needed_credits: Math.ceil((MIN_MARGIN * liveCostUsd) / NET_USD_PER_CREDIT),
    }, { status: 409 });
  }

  const { data: spent, error: spendErr } = await sb.rpc("wallet_spend", {
    p_user: userId, p_amount: cost, p_reason: "spend",
  });
  if (spendErr) return json({ error: "spend_failed", detail: spendErr.message }, { status: 500 });
  if (spent === false) return json({ error: "insufficient_credits", needed: cost }, { status: 402 });

  // SMSPVA v2 call.
  let smspva;
  try {
    smspva = await getNumber(country.smspva_code, service.smspva_code);
  } catch (e) {
    await sb.rpc("wallet_credit", { p_user: userId, p_amount: cost, p_reason: "refund" });
    return json({ error: "smspva_unreachable", detail: String(e) }, { status: 502 });
  }

  if (!isOk(smspva)) {
    await sb.rpc("wallet_credit", { p_user: userId, p_amount: cost, p_reason: "refund" });
    return json({
      error: "smspva_error",
      smspva_status: smspva.statusCode,
      smspva_type: smspva.error?.type,
      smspva_description: smspva.error?.description,
    }, { status: smspva.statusCode === 407 ? 502 : 503 });
  }

  // v2 returns phoneNumber WITHOUT country code — we format with dial_code so
  // the iOS UI shows a clickable, copy-pasteable full E.164-ish number.
  const formattedNumber = `${country.dial_code} ${smspva.data.phoneNumber}`;

  const { data: order, error: insertErr } = await sb
    .from("orders")
    .insert({
      user_id: userId,
      service_id: service.id,
      country_id: country.id,
      smspva_id: String(smspva.data.orderId),
      smspva_number: formattedNumber,
      cost_credits: cost,
      status: "waiting",
    })
    .select("*").single();

  if (insertErr || !order) {
    await sb.rpc("wallet_credit", { p_user: userId, p_amount: cost, p_reason: "refund" });
    return json({ error: "order_persist_failed", detail: insertErr?.message }, { status: 500 });
  }

  return json({ order });
});
