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
      // The DETAIL, not just the code. `chain_verify_failed` alone is
      // unactionable: it is thrown whenever the certificate walk raises, and
      // the reason — wrong root, unsupported curve, a locally-signed StoreKit
      // test receipt — lives only in the exception message, which until now
      // went to a function log nobody reads at 3am. Diagnosing this from the
      // code alone produced one wrong answer already.
      EdgeRuntime.waitUntil(notifySafe(
        `🚨 <b>IAP verification rejected</b>\ncode: ${esc(code)}\nuser: ${esc(userId)}\n` +
        `detail: <code>${esc(String(e).slice(0, 300))}</code>\n` +
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
      // Always 0 here. credit_iap_purchase writes the real figure inside the
      // same transaction as the wallet move, so this column can never claim
      // credits that a later failure stopped from landing.
      granted_credits: 0,
      purchase_date_ms: tx.purchaseDate,
      raw_jws: body.jws,
    })
    .select("id")
    .maybeSingle();

  if (insertErr) {
    // Unique constraint violation => already credited.
    if (insertErr.code === "23505") {
      // A duplicate submit is only genuinely "already credited" if the credits
      // LANDED. StoreKit runs two paths into here (Transaction.updates and the
      // Transaction.unfinished sweep), so both can carry the same JWS, and the
      // first attempt may have died after persisting the receipt and before
      // moving the wallet.
      //
      // The guard that used to live here checked the ledger only when
      // granted_credits > 0 — while the failure path it existed to catch SET
      // granted_credits = 0. The two conditions were mutually exclusive, so
      // the exact case it was written for fell straight through to
      // already_credited, the client called finish(), and a payment worth up
      // to $59.99 was retired having granted nothing.
      //
      // credit_iap_purchase is idempotent against its own tombstone, so
      // calling it again IS both the duplicate check and the recovery: it
      // credits if and only if this transaction has never been granted.
      const { data: prior } = await sb
        .from("iap_receipts").select("id, environment")
        .eq("transaction_id", tx.transactionId).maybeSingle();
      if (prior && prior.environment === "Production") {
        const { data: outcome, error: recErr } = await sb.rpc("credit_iap_purchase", {
          p_user: userId,
          p_receipt: prior.id,
          p_amount: credits,
          p_transaction_id: tx.transactionId,
          p_original_transaction_id: tx.originalTransactionId,
        });
        if (recErr) {
          // Do NOT confirm. finish() would stop the redelivery that is the
          // only thing still driving a retry.
          console.error(`iap-verify: recovery credit FAILED tx=${tx.transactionId}`, recErr);
          return json({ error: "credit_pending" }, { status: 409 });
        }
        if (outcome === "granted") {
          console.error(`iap-verify: RECOVERED a lost payment user=${userId} tx=${tx.transactionId}`);
          try {
            EdgeRuntime.waitUntil(notifySafe(
              `✅ <b>Recovered a lost IAP credit</b>\n` +
              `user ${esc(userId)} · ${credits} credits (${esc(tx.productId)})\n` +
              `<i>An earlier attempt persisted the receipt but never moved the wallet.</i>`,
            ));
          } catch { /* alerting must never mask the response */ }
          return json({ ok: true, credits, balance_changed: true, recovered: true });
        }
      }
      return json({ ok: true, already_credited: true });
    }
    return json({ error: "persist_failed", detail: insertErr.message }, { status: 500 });
  }

  if (isProduction) {
    const { data: outcome, error: creditErr } = await sb.rpc("credit_iap_purchase", {
      p_user: userId,
      p_receipt: inserted?.id ?? null,
      p_amount: credits,
      p_transaction_id: tx.transactionId,
      p_original_transaction_id: tx.originalTransactionId,
    });
    if (creditErr) {
      // The receipt row exists but the wallet did NOT move. No rollback is
      // needed any more: granted_credits was inserted as 0 and only
      // credit_iap_purchase sets it, and the tombstone insert rolled back
      // inside the same failed transaction. So the receipt correctly reads
      // "took a payment, granted nothing" and stays RECOVERABLE — StoreKit
      // redelivers, the duplicate branch above calls the same function, and it
      // credits because no tombstone exists.
      //
      // Do not return ok here. finish() would retire the transaction and stop
      // the only retry mechanism there is.
      console.error(`CRITICAL: credit_iap_purchase failed after receipt persist user=${userId}`, creditErr);
      try {
        EdgeRuntime.waitUntil(notifySafe(
          `🚨 <b>IAP credit FAILED after payment</b>\n` +
          `user ${esc(userId)} paid for ${credits} credits (${esc(tx.productId)})\n` +
          `error: ${esc(creditErr.message)}\n` +
          `<i>Receipt kept at 0 credits and recoverable — StoreKit retries and the retry now credits it.</i>`,
        ));
      } catch { /* alerting must never mask the response */ }
      return json({ error: "credit_failed" }, { status: 500 });
    }
    if (outcome === "already_granted") {
      // This transaction was credited before, under an account that no longer
      // exists. Delete Account CASCADEs iap_receipts, which is exactly why the
      // insert above SUCCEEDED instead of hitting the unique constraint —
      // there is no receipt row left to collide with. Apple re-verifies the
      // JWS perfectly: the signature proves the purchase is genuine, never
      // that it is unspent. Only the tombstone knows.
      //
      // Answer ok so the client finishes and StoreKit stops redelivering, but
      // move no money and report it honestly rather than claiming credits.
      console.error(`iap-verify: REPLAY blocked user=${userId} tx=${tx.transactionId}`);
      try {
        EdgeRuntime.waitUntil(notifySafe(
          `⚠️ <b>IAP replay blocked</b>\n` +
          `user ${esc(userId)} re-submitted ${esc(tx.productId)}\n` +
          `tx ${esc(tx.transactionId)}\n` +
          `<i>Already granted previously — no credits issued.</i>`,
        ));
      } catch { /* alerting must never mask the response */ }
      return json({ ok: true, credits: 0, balance_changed: false, already_credited: true });
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
      // supabase-js RETURNS errors, it does not throw — so this try/catch on
      // its own caught nothing, and a failed payout silently cost the referrer
      // their 5 credits with no trace anywhere. The catch stays as a backstop
      // for a synchronous throw; the destructure is what actually reports.
      const { error: refErr } = await sb.rpc("apply_referral_reward", { p_referee: userId });
      if (refErr) console.error("apply_referral_reward FAILED for", userId, refErr);
    } catch (e) {
      console.error("apply_referral_reward threw for", userId, e);
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
