import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import { verifyTransactionJWS, creditsForProduct, IapVerificationError } from "../_shared/iap.ts";
import { notifySafe, sendMessage, esc } from "../_shared/telegram.ts";

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
    // sendMessage (not notifySafe): we need the outcome, because a claim we
    // wrote for a send that then FAILED must be released — otherwise the
    // sweep sees the claim, assumes it was sent, and the alert is lost
    // forever (the exact opposite of what the safety-net comment promises).
    const r = await sendMessage(
      `💳 <b>Credits purchased</b>\n${p.credits} credits (pack ${esc(pack)})${sandbox}`,
    );
    if (!r.ok) {
      console.error("purchase alert send failed, releasing claim", r.status, r.body);
      await sb.from("telegram_events")
        .delete().eq("kind", "purchase").eq("ref", String(p.receiptId));
    }
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
    // A rejection here is now load-bearing, so make it LOUD. Before, this
    // returned 400 with no log and no persisted trace, which meant a genuine
    // regression (Apple rotates a certificate, we reject real purchases) would
    // look exactly like silence. The client does NOT call tx.finish() on
    // failure, so StoreKit keeps redelivering the transaction — a real buyer
    // is recoverable, but only if we know it happened.
    const code = e instanceof IapVerificationError ? e.code : "unknown";
    console.error(`iap verification REJECTED user=${userId} code=${code}`, String(e));
    try {
      EdgeRuntime.waitUntil(notifySafe(
        `🚨 <b>IAP verification rejected</b>\ncode: ${esc(code)}\nuser: ${esc(userId)}\n` +
        `<i>If this is a real buyer, credit them manually — StoreKit will keep retrying.</i>`,
      ));
    } catch { /* alerting must never mask the response */ }
    return json({ error: "verification_failed", detail: code }, { status: 400 });
  }

  // Only a PRODUCTION purchase moves real money. Sandbox and Xcode receipts are
  // genuine Apple-signed transactions that cost $0 — any Apple ID can switch to
  // a Sandbox account in Settings and "buy" packs for free. Receipt id 21 shows
  // this already happened: a real user was granted 12 credits 39 seconds after
  // signing up, for $0.
  //
  // This gate is worthless without the chain verification above, because
  // `environment` is just another field in the payload — a forger writes
  // "Production". It only became meaningful once the payload is trusted.
  //
  // Non-production receipts are still PERSISTED (audit trail, and the local
  // StoreKit test flow still sees success and finishes the transaction) — they
  // simply do not credit the wallet.
  const isProduction = tx.environment === "Production";

  const sb = admin();

  const credits = creditsForProduct(tx.productId);
  if (!credits) {
    // A real, Apple-verified payment for a product this backend doesn't know —
    // i.e. a pack was added in App Store Connect without updating
    // PRODUCT_TO_CREDITS. The client never finishes the transaction, so
    // StoreKit will keep retrying; without an alert every purchase of that
    // pack is silently eaten until someone happens to read the logs. Claimed
    // in telegram_events so the retries don't page every few minutes.
    try {
      const { data: claimed } = await sb
        .from("telegram_events")
        .insert({ kind: "iap_unknown", ref: String(tx.transactionId) })
        .select("ref").maybeSingle();
      if (claimed) {
        await notifySafe(
          `🚨 <b>IAP unknown product</b>\n${esc(tx.productId)} (env ${esc(tx.environment)})\n` +
          `Add it to PRODUCT_TO_CREDITS — StoreKit keeps retrying, the buyer sees no credits.`,
        );
      }
    } catch (e) {
      console.error("unknown_product alert failed (ignored):", e);
    }
    return json({ error: "unknown_product", product_id: tx.productId }, { status: 400 });
  }

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
      granted_credits: isProduction ? credits : 0,
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

  if (isProduction) {
    const { error: creditErr } = await sb.rpc("wallet_credit", {
      p_user: userId,
      p_amount: credits,
      p_reason: "purchase",
      p_order: null,
      p_receipt: inserted?.id ?? null,
    });
    if (creditErr) {
      // The receipt row exists but the wallet did NOT move. Returning ok here
      // would make the client finish() the transaction — and the replay path
      // above would answer already_credited forever after: the buyer's money
      // would be permanently eaten by a transient DB error. Instead, delete
      // the receipt so StoreKit's automatic redelivery retries the whole
      // grant, fail the request, and page the owner either way.
      console.error(`CRITICAL: wallet_credit failed after receipt persist user=${userId}`, creditErr);
      const { error: delErr } = inserted?.id != null
        ? await sb.from("iap_receipts").delete().eq("id", inserted.id)
        : { error: { message: "receipt id unknown — delete skipped" } };
      try {
        EdgeRuntime.waitUntil(notifySafe(
          `🚨 <b>IAP credit FAILED after payment</b>\n` +
          `user ${esc(userId)} paid for ${credits} credits (${esc(tx.productId)})\n` +
          `wallet_credit error: ${esc(creditErr.message)}\n` +
          (delErr
            ? `⚠️ receipt row could NOT be rolled back (${esc(delErr.message)}) — credit MANUALLY, StoreKit will not retry.`
            : `receipt rolled back — StoreKit retries automatically; this resolves itself unless it repeats.`),
        ));
      } catch { /* alerting must never mask the response */ }
      return json({ error: "credit_failed" }, { status: 500 });
    }
  } else {
    console.warn(`iap: ${tx.environment} receipt persisted WITHOUT credit — user=${userId} product=${tx.productId}`);
  }

  // Referral payout: if this buyer was referred and hasn't triggered the reward
  // yet, pay their inviter 5 credits. Idempotent server-side, so firing on every
  // purchase is safe — it only pays out on the buyer's first one.
  // Production only — a free Sandbox "purchase" must not trigger a real
  // 5-credit payout to an inviter either.
  if (isProduction) {
    try {
      await sb.rpc("apply_referral_reward", { p_referee: userId });
    } catch (e) {
      console.error("apply_referral_reward failed for", userId, e);
    }
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

  // ok:true even for a sandbox receipt, so the client calls tx.finish() and
  // StoreKit stops redelivering it. credits/balance_changed report the truth.
  return json({
    ok: true,
    credits: isProduction ? credits : 0,
    balance_changed: isProduction,
  });
});
