import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import { getNumber, isOk } from "../_shared/smspva.ts";

interface Body {
  service_id: string;
  country_id: string;
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

  const sb = admin();

  // Load service + country (need codes + cost).
  const { data: service, error: svcErr } = await sb
    .from("services").select("id, smspva_code, cost").eq("id", body.service_id).single();
  if (svcErr || !service) return json({ error: "unknown_service" }, { status: 404 });

  const { data: country, error: cErr } = await sb
    .from("countries").select("id, smspva_code").eq("id", body.country_id).single();
  if (cErr || !country) return json({ error: "unknown_country" }, { status: 404 });

  const cost = service.cost as number;

  // Atomically deduct credits — returns false if balance < cost.
  const { data: spent, error: spendErr } = await sb.rpc("wallet_spend", {
    p_user: userId, p_amount: cost, p_reason: "spend",
  });
  if (spendErr) return json({ error: "spend_failed", detail: spendErr.message }, { status: 500 });
  if (spent === false) return json({ error: "insufficient_credits", needed: cost }, { status: 402 });

  // Ask SMSPVA for a number.
  let smspva;
  try {
    smspva = await getNumber(country.smspva_code, service.smspva_code);
  } catch (e) {
    await sb.rpc("wallet_credit", { p_user: userId, p_amount: cost, p_reason: "refund" });
    return json({ error: "smspva_unreachable", detail: String(e) }, { status: 502 });
  }

  if (!isOk(smspva) || !smspva.id) {
    await sb.rpc("wallet_credit", { p_user: userId, p_amount: cost, p_reason: "refund" });
    return json({
      error: "no_numbers_available",
      service_id: service.id, country_id: country.id,
      smspva_response: smspva.response,
    }, { status: 503 });
  }

  // Persist the order.
  const { data: order, error: insertErr } = await sb
    .from("orders")
    .insert({
      user_id: userId,
      service_id: service.id,
      country_id: country.id,
      smspva_id: String(smspva.id),
      smspva_number: smspva.number ?? null,
      cost_credits: cost,
      status: "waiting",
    })
    .select("*").single();

  if (insertErr || !order) {
    // Refund and ask SMSPVA to release the number.
    await sb.rpc("wallet_credit", { p_user: userId, p_amount: cost, p_reason: "refund" });
    return json({ error: "order_persist_failed", detail: insertErr?.message }, { status: 500 });
  }

  return json({ order });
});
