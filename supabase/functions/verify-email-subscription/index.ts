// Turn a verified StoreKit mail subscription into a server-side entitlement.
//
// Much simpler than `verify-line-subscription`, and the difference is the
// whole point: a line provisions a PHYSICAL resource that bills us monthly, so
// its ordering (tombstone → row → provider → activate) exists to make a
// stranded number impossible. A mail subscription provisions nothing. The row
// IS the entitlement, so there is one write and nothing to strand.
//
// ⚠️ This function does not charge and cannot refund — Apple already has the
// money when it runs. There is nothing here that may legitimately refuse
// except a failed verification or an entitlement bound to another account.

import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import {
  verifyTransactionJWS, subscriptionFamily, IapVerificationError, mailPlanLabel,
} from "../_shared/iap.ts";
import { sendMessage, esc } from "../_shared/telegram.ts";

Deno.serve(async (req) => {
  const pre = handleCors(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, { status: 405 });

  const userId = await callerUserId(req);
  if (!userId) return json({ error: "unauthorized" }, { status: 401 });

  let body: { signed_transaction?: string } = {};
  try { body = await req.json(); } catch { /* guarded below */ }

  const jws = body.signed_transaction ?? "";
  if (!jws) return json({ error: "bad_request" }, { status: 400 });

  const sb = admin();

  // Chain-verified to Apple's PINNED root. Never decode-and-trust.
  let tx;
  try {
    tx = await verifyTransactionJWS(jws);
  } catch (e) {
    const code = e instanceof IapVerificationError ? e.code : "verification_failed";
    console.error(JSON.stringify({ alert: "mail_verify_failed", code }));
    return json({ error: "verification_failed" }, { status: 400 });
  }

  // A line subscription or a credit pack arriving here is a client routing bug,
  // and accepting it would grant the wrong entitlement.
  if (subscriptionFamily(tx.productId) !== "mail") {
    return json({ error: "unknown_product" }, { status: 400 });
  }

  // Sandbox is ACCEPTED here, deliberately and unlike `iap-verify`.
  //
  // The App Store reviewer subscribes in Sandbox. `iap-verify` gates credits on
  // Production because a Sandbox receipt is genuinely Apple-signed and costs
  // $0, so anyone could mint credits. There is no equivalent exposure here: the
  // entitlement grants addresses on domains that cost us NOTHING, and it is
  // still bounded by the subscriber daily cap. Refusing Sandbox would mean the
  // reviewer subscribes, gets nothing, and rejects the build.
  const periodEnd = tx.expiresDate ? new Date(tx.expiresDate).toISOString() : null;

  const { data: res, error } = await sb.rpc("record_email_subscription", {
    p_original_tx: tx.originalTransactionId,
    p_user: userId,
    p_product: tx.productId,
    p_state: "active",
    p_auto_renew: true,
    p_environment: tx.environment,
    p_expires_at: periodEnd,
    p_last_tx: tx.transactionId,
    p_signed_tx: jws,
    p_storefront: tx.storefront ?? null,
    p_price_milli: tx.price ?? null,
    p_currency: tx.currency ?? null,
  });
  if (error) {
    console.error(JSON.stringify({ alert: "mail_sub_record_failed", detail: error.message }));
    return json({ error: "subscription_record_failed" }, { status: 500 });
  }
  if (res?.ok !== true) {
    // `subscription_bound` is the deletion-replay catch, and it is a REFUSAL
    // rather than an error: the entitlement belongs to another account.
    return json({ error: res?.reason ?? "subscription_record_failed" }, { status: 409 });
  }

  // Claimed on (kind='mail_sub', ref=originalTransactionId) so this alert and
  // any future ASSN branch for mail cannot both fire — whichever arrives
  // first sends, and a failed send releases the claim for the sweep.
  const sandbox = tx.environment !== "Production"
    ? `\n<i>${esc(tx.environment ?? "?")}</i>` : "";
  await alertOwnerOnce(
    `📬 <b>New e-mail subscription</b>\n${esc(mailPlanLabel(tx))}${sandbox}`,
    sb, tx.originalTransactionId, "mail_sub",
  );

  return json({ ok: true, entitled: true });
});

/** Alert the owner exactly once for this subscription.
 *
 * The claim row is written BEFORE the send and deleted if the send fails, so
 * this function and `apple-notifications`' SUBSCRIBED branch can both run for
 * the same purchase and only one message goes out — whichever arrives first.
 * That matters because Apple's notification and the client's own verify call
 * race on every purchase, and neither is guaranteed to be first.
 *
 * Deliberately duplicated from `apple-notifications.alertOwner` rather than
 * shared: `_shared/*` is bundled into every edge function at deploy time, so
 * moving ten lines there would force a redeploy of ~20 functions to pick it up.
 *
 * An alert must never fail an entitlement the user has paid for — every error
 * path here is swallowed.
 */
async function alertOwnerOnce(
  html: string, sb: ReturnType<typeof admin>, ref: string, kind: string,
) {
  try {
    const { data: claimed } = await sb.from("telegram_events")
      .insert({ kind, ref }).select("ref").maybeSingle();
    if (!claimed) return;
    const r = await sendMessage(html);
    if (!r.ok) {
      await sb.from("telegram_events").delete().eq("kind", kind).eq("ref", ref);
    }
  } catch { /* never fail the entitlement for an alert */ }
}
