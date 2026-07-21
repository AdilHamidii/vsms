import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import { verifyTransactionJWS, creditsForProduct } from "../_shared/iap.ts";
import { notifySafe, esc } from "../_shared/telegram.ts";

interface Body { jws: string; }

/** Claim the event, then alert. The claim makes this exactly-once against the
 *  per-minute sweep in telegram-notify, which re-sends anything that fails
 *  here. Swallows everything — this must never affect a purchase. */
async function alertPurchase(
  sb: ReturnType<typeof admin>,
  p: { receiptId?: number | null; credits: number; productId: string; environment: string },
): Promise<void> {
  try {
    if (p.receiptId == null) return;
    const { data: claimed } = await sb
      .from("telegram_events")
      .insert({ kind: "purchase", ref: String(p.receiptId) })
      .select("ref").maybeSingle();
    if (!claimed) return;   // sweep already sent it

    const pack = p.productId.split(".").pop();
    const sandbox = p.environment !== "Production" ? `\n<i>${esc(p.environment)}</i>` : "";
    await notifySafe(
      `💳 <b>Credits purchased</b>\n${p.credits} credits (pack ${esc(pack)})${sandbox}`,
    );
  } catch (e) {
    console.error("alertPurchase failed (ignored):", e);
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

  // Operator alert. Deliberately NOT awaited: waitUntil lets it run after the
  // response is sent, so a slow or dead Telegram can never add latency to — or
  // fail — a real purchase. The whole call is wrapped because a synchronous
  // throw here (e.g. a missing env var) would otherwise escape into this path.
  // Unreachable for a replayed receipt: the duplicate transaction_id returns
  // early above, so this only ever runs for a genuinely new purchase.
  try {
    EdgeRuntime.waitUntil(alertPurchase(sb, {
      receiptId: inserted?.id, credits, productId: tx.productId, environment: tx.environment,
    }));
  } catch (e) {
    console.error("purchase alert dispatch failed (ignored):", e);
  }

  return json({ ok: true, credits, balance_changed: true });
});
