// Turn a verified StoreKit subscription into a working phone number.
//
// The order of operations is the whole design, and it is the inverse of what
// reads naturally:
//
//   1. verify the JWS against Apple's pinned root
//   2. record the SUBSCRIPTION tombstone   (survives Delete Account)
//   3. begin_line_rental                   (row exists BEFORE any provider call)
//   4. buy the number at Telnyx
//   5. activate_line_claim                 (stamp the ids, flip to active)
//
// Step 3 before step 4 is the lesson from `begin_order`: charging before the
// row existed left 258 spends pointing at 126 orders, half of all paid attempts
// invisible. Here the stranded resource would be worse than an invisible order
// — it is a phone number billing us $1/month forever with nothing in the
// database pointing at it, discoverable only on the invoice.
//
// ⚠️ This function does NOT charge anything and cannot refund. Apple already
// has the money by the time it runs. Everything that could reasonably refuse —
// the float check, the one-line-per-user check, the paused check — happens in
// `reserve-line-number`, BEFORE the paywall. If we get here and cannot deliver,
// the only honest outcome is `fail_line_claim` plus a page to a human.

import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import {
  verifyTransactionJWS, isSubscriptionProduct, IapVerificationError,
} from "../_shared/iap.ts";
import {
  orderNumber, getOrder, findNumberId, attachMessagingProfile,
  releaseNumber, faultOf,
} from "../_shared/telnyx.ts";
import { sendMessage, esc } from "../_shared/telegram.ts";

/** Telnyx number orders are asynchronous: `pending` → `success`, measured under
 *  5s. Poll rather than trusting a webhook — a webhook outage must not strand a
 *  purchase Apple has already taken money for. */
const ORDER_POLL_ATTEMPTS = 8;
const ORDER_POLL_MS = 1200;

/** ⚠️ The App Store reviewer subscribes in SANDBOX. `iap-verify` grants credits
 *  only on Production, for excellent reasons — a Sandbox receipt is genuinely
 *  Apple-signed and costs $0, and any Apple ID can switch. Applying that same
 *  gate here means the reviewer subscribes, receives no number, and rejects.
 *
 *  So the gate is a CONFIG FLAG rather than a constant, defaulting to allowing
 *  Sandbox. It is the same switch that answers "what does the reviewer get",
 *  and it can be flipped without a deploy. Sandbox provisioning spends real
 *  Telnyx money ($1/number), so watch it if it is ever left open at scale. */
async function sandboxProvisioningAllowed(
  sb: ReturnType<typeof admin>,
): Promise<boolean> {
  const { data, error } = await sb.from("app_config")
    .select("value").eq("key", "line_sandbox_provisioning").maybeSingle();
  if (error) return false;          // fail closed on an unreadable flag
  return (data?.value as boolean | null) !== false;
}

Deno.serve(async (req) => {
  const pre = handleCors(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, { status: 405 });

  const userId = await callerUserId(req);
  if (!userId) return json({ error: "unauthorized" }, { status: 401 });

  let body: {
    signed_transaction?: string;
    phone_number?: string;
    city?: string;
    monthly_cents?: number;
  } = {};
  try { body = await req.json(); } catch { /* guarded below */ }

  const jws = body.signed_transaction ?? "";
  const wanted = body.phone_number ?? "";
  if (!jws || !wanted) return json({ error: "bad_request" }, { status: 400 });

  const sb = admin();

  // ── 1. Verify ────────────────────────────────────────────────────────────
  // Chain-verified to Apple's PINNED root. Never decode-and-trust: the original
  // verifier took the certificate out of the attacker-supplied header and
  // checked the signature against that same certificate, which let anyone with
  // a free Apple account mint credits.
  let tx;
  try {
    tx = await verifyTransactionJWS(jws);
  } catch (e) {
    const code = e instanceof IapVerificationError ? e.code : "verification_failed";
    console.error(JSON.stringify({ alert: "line_verify_failed", code }));
    return json({ error: "verification_failed" }, { status: 400 });
  }

  // The subscription id must never reach PRODUCT_TO_CREDITS, and a credit pack
  // must never reach here. Both directions are wrong and both are silent.
  if (!isSubscriptionProduct(tx.productId)) {
    return json({ error: "unknown_product" }, { status: 400 });
  }

  if (tx.environment !== "Production" && !(await sandboxProvisioningAllowed(sb))) {
    return json({ error: "sandbox_not_provisioned" }, { status: 409 });
  }

  // Apple's own expiry, never `purchaseDate + 30 days`. In Sandbox a month is
  // five minutes, so a computed period would be wrong by orders of magnitude
  // in exactly the environment we test in.
  const periodEnd = tx.expiresDate ? new Date(tx.expiresDate).toISOString() : null;

  // ── 2. The subscription tombstone ────────────────────────────────────────
  // Written BEFORE the line, and deliberately cascade-free. Delete Account →
  // re-signin → StoreKit still reports the entitlement; without this row we
  // would provision a SECOND number while the first bills us forever.
  const { data: subRes, error: subErr } = await sb.rpc("record_line_subscription", {
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
  if (subErr) {
    console.error(JSON.stringify({ alert: "line_sub_record_failed", detail: subErr.message }));
    return json({ error: "subscription_record_failed" }, { status: 500 });
  }
  if (subRes?.ok !== true) {
    // `subscription_bound` is the deletion-replay catch, and it is a REFUSAL
    // rather than an error: the entitlement belongs to another account.
    return json({ error: subRes?.reason ?? "subscription_record_failed" }, { status: 409 });
  }

  // ── 3. The line row, before any provider call ────────────────────────────
  const { data: begun, error: beginErr } = await sb.rpc("begin_line_rental", {
    p_user: userId,
    p_e164: wanted,
    p_country: "CA",
    p_number_type: "local",
    p_original_tx: tx.originalTransactionId,
    p_product: tx.productId,
  });
  if (beginErr) {
    console.error(JSON.stringify({ alert: "line_begin_failed", detail: beginErr.message }));
    return json({ error: "provision_failed" }, { status: 500 });
  }
  if (begun?.ok !== true) {
    // A user who already holds a line and somehow paid again: refuse rather
    // than provisioning a second number. They keep the subscription; a human
    // resolves it. Paging because it means money moved for nothing.
    if (begun?.reason === "line_exists") {
      console.error(JSON.stringify({
        alert: "line_paid_but_exists", user: userId, tx: tx.originalTransactionId,
      }));
    }
    return json({ error: begun?.reason ?? "provision_failed" }, { status: 409 });
  }
  const lineId = String(begun.line_id);

  // ── 4. Buy it ────────────────────────────────────────────────────────────
  // `customer_reference` is set to the line id, and that single field is what
  // makes orphan reconciliation possible later: a number we own with no live
  // line pointing at it is otherwise invisible until the invoice.
  const order = await orderNumber(wanted, lineId);
  if (faultOf(order)) {
    await failLine(sb, lineId, `order_${order.type}`, userId, tx.originalTransactionId);
    return json({ error: "provision_failed" }, { status: 502 });
  }

  let e164: string | null = null;
  for (let i = 0; i < ORDER_POLL_ATTEMPTS; i++) {
    const st = await getOrder(order.orderId);
    if (faultOf(st)) break;
    const n = st.numbers[0];
    // ⚠️ `requirement-info-pending` means BOUGHT AND UNUSABLE pending
    // regulatory documents. It reads like progress and is a dead end — this is
    // what cost $3.83 on a GB number. CA/US need no documents, so seeing it
    // here means something changed and the number must be released, not waited
    // on.
    if (n?.status === "requirement-info-pending") {
      await releaseIfPossible(wanted);
      await failLine(sb, lineId, "requirements_pending", userId, tx.originalTransactionId);
      return json({ error: "provision_failed" }, { status: 502 });
    }
    if (st.status === "success" && n?.e164) { e164 = n.e164; break; }
    if (st.status === "failed") break;
    await new Promise((r) => setTimeout(r, ORDER_POLL_MS));
  }

  if (!e164) {
    // Might still land after we stop looking, so do NOT release blindly — the
    // orphan reconciler is what sweeps a number that arrived late. Failing the
    // line keeps the user out of a half-state and pages a human.
    await failLine(sb, lineId, "order_timeout", userId, tx.originalTransactionId);
    return json({ error: "provision_failed" }, { status: 504 });
  }

  // ── 5. Configure and activate ────────────────────────────────────────────
  // The messaging profile is what routes inbound SMS to our webhook. Attaching
  // it is NOT settable on the main number resource (error 10027) — it lives on
  // the /messaging sub-resource.
  const numberId = await findNumberId(e164);
  const msgProfile = Deno.env.get("TELNYX_MESSAGING_PROFILE_ID") ?? null;
  if (typeof numberId === "string" && msgProfile) {
    const attached = await attachMessagingProfile(numberId, msgProfile);
    if (faultOf(attached)) {
      // Not fatal to the purchase — the number exists and voice works — but it
      // means inbound SMS goes nowhere, so it pages.
      console.error(JSON.stringify({
        alert: "line_msg_profile_failed", line: lineId, detail: attached.detail,
      }));
    }
  }

  const { data: activated, error: actErr } = await sb.rpc("activate_line_claim", {
    p_line: lineId,
    p_number_id: typeof numberId === "string" ? numberId : null,
    p_connection: null,
    p_msg_profile: msgProfile,
    p_voice_profile: null,
    p_credential: null,
    p_period_end: periodEnd,
    // The price from the SEARCH quote. Nothing reports it again — the order
    // response returns `cost_information: null` and the number resource has no
    // price field at all — so this is the only chance to record it.
    p_monthly_cost_cents: body.monthly_cents ?? null,
  });
  if (actErr || activated !== true) {
    console.error(JSON.stringify({
      alert: "line_activate_failed", line: lineId, detail: actErr?.message,
    }));
    return json({ error: "provision_failed" }, { status: 500 });
  }

  await alertNewLine(sb, e164, tx.originalTransactionId, tx.environment);

  return json({ ok: true, line_id: lineId, e164 });
});

async function failLine(
  sb: ReturnType<typeof admin>, lineId: string, reason: string,
  userId: string, originalTx: string,
) {
  const { error } = await sb.rpc("fail_line_claim", { p_line: lineId, p_reason: reason });
  if (error) console.error(JSON.stringify({ alert: "line_fail_claim_failed", lineId }));
  // Apple has the money and we cannot refund it from here. A human decides
  // whether to refund through ASC, so this must page rather than log quietly.
  console.error(JSON.stringify({
    alert: "line_provision_failed", reason, user: userId, tx: originalTx,
  }));
}

async function releaseIfPossible(e164: string) {
  const id = await findNumberId(e164);
  if (typeof id === "string") await releaseNumber(id);
}

/** Exactly-once ops ping, following `iap-verify.alertPurchase` precisely.
 *
 *  `telegram_events` is a CLAIM row — `(kind, ref)` and nothing else, no
 *  payload column — written BEFORE sending so the minutely sweep and this
 *  instant path can never double-send. Two properties are load-bearing and
 *  both are easy to lose:
 *
 *  - The claim is RELEASED when the send fails. Otherwise the sweep sees a
 *    claim, assumes it went out, and the alert is lost forever — the exact
 *    opposite of a safety net.
 *  - `kind` is CHECK-constrained. `'line'` was added to that constraint in
 *    20260805170000; a kind the constraint rejects fails the insert, which is
 *    how an alert goes missing with no trace at all.
 *
 *  Never allowed to fail the request: the user's number works whether or not
 *  Telegram is reachable.
 */
async function alertNewLine(
  sb: ReturnType<typeof admin>, e164: string, ref: string, env: string,
) {
  try {
    const { data: claimed } = await sb.from("telegram_events")
      .insert({ kind: "line", ref }).select("ref").maybeSingle();
    if (!claimed) return;   // already sent

    const sandbox = env !== "Production" ? `\n<i>${esc(env)}</i>` : "";
    const r = await sendMessage(
      `📞 <b>New second number</b>\n${esc(e164)}${sandbox}`);
    if (!r.ok) {
      console.error("line alert send failed, releasing claim", r.status, r.body);
      await sb.from("telegram_events")
        .delete().eq("kind", "line").eq("ref", ref);
    }
  } catch (e) {
    console.error("alertNewLine failed (ignored):", e);
  }
}
