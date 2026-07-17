import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import { verifyTransactionJWS, creditsForProduct } from "../_shared/iap.ts";

interface Body { jws: string; }

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, { status: 405 });

  const userId = await callerUserId(req);
  if (!userId) return json({ error: "unauthorized" }, { status: 401 });

  let body: Body;
  try { body = await req.json(); }
  catch { return json({ error: "invalid_body" }, { status: 400 }); }
  if (!body.jws) return json({ error: "missing_jws" }, { status: 400 });

  let tx;
  try {
    tx = await verifyTransactionJWS(body.jws);
  } catch (e) {
    return json({ error: "verification_failed", detail: String(e) }, { status: 400 });
  }

  const credits = creditsForProduct(tx.productId);
  if (!credits) {
    return json({ error: "unknown_product", product_id: tx.productId }, { status: 400 });
  }

  const sb = admin();

  // Idempotent insert keyed on transaction_id.
  const { data: inserted, error: insertErr } = await sb
    .from("iap_receipts")
    .insert({
      user_id: userId,
      transaction_id: tx.transactionId,
      original_transaction_id: tx.originalTransactionId,
      product_id: tx.productId,
      bundle_id: tx.bundleId,
      environment: tx.environment,
      granted_credits: credits,
      purchase_date_ms: tx.purchaseDate,
      raw_jws: body.jws,
    })
    .select("id")
    .maybeSingle();

  if (insertErr) {
    // Unique constraint violation => already credited.
    if (insertErr.code === "23505") {
      return json({ ok: true, already_credited: true });
    }
    return json({ error: "persist_failed", detail: insertErr.message }, { status: 500 });
  }

  await sb.rpc("wallet_credit", {
    p_user: userId,
    p_amount: credits,
    p_reason: "purchase",
    p_order: null,
    p_receipt: inserted?.id ?? null,
  });

  // Referral payout: if this buyer was referred and hasn't triggered the reward
  // yet, pay their inviter 5 credits. Idempotent server-side, so firing on every
  // purchase is safe — it only pays out on the buyer's first one.
  try {
    await sb.rpc("apply_referral_reward", { p_referee: userId });
  } catch (e) {
    console.error("apply_referral_reward failed for", userId, e);
  }

  return json({ ok: true, credits, balance_changed: true });
});
