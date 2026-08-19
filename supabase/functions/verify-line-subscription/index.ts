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
  verifyTransactionJWS, subscriptionFamily, IapVerificationError,
  linePlanLabel,
} from "../_shared/iap.ts";
import {
  orderNumber, getOrder, findNumberId, attachMessagingProfile,
  releaseNumber, searchNumbers, faultOf,
} from "../_shared/telnyx.ts";
import { provisionLineVoice } from "../_shared/lineVoice.ts";
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
    /** @deprecated Accepted and IGNORED. This is a COST, and a client-supplied
     *  cost is the same category of mistake as a client-supplied price — it is
     *  re-quoted by `quoteMonthlyCents`. Kept in the shape so shipped builds
     *  that still send it are not rejected. */
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
  //
  // 🔴 THIS MUST BE `subscriptionFamily(...) !== "line"`, NEVER
  // `isSubscriptionProduct`, which answers "is this a subscription at all" and
  // is TRUE for the $2.99 mail products too. Everything below provisions a
  // rented Telnyx number, and neither `record_line_subscription` nor
  // `begin_line_rental` validates the product id — so a mail JWS posted here
  // would write a mail product into `line_subscriptions` and buy a $9.99/mo
  // phone number with a $2.99 purchase. Dispatch on the FAMILY.
  if (subscriptionFamily(tx.productId) !== "line") {
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

  // Stamp the order id NOW, not on success. A purchase that fails after the
  // buy is precisely when this handle matters — the order is ASYNCHRONOUS, the
  // number may still arrive after we stop polling, and `activate_line_claim`
  // never runs on that path. Without it an orphan is invisible until the
  // invoice. Errors are logged, never fatal: the number is already bought.
  const { error: orderIdErr } = await sb.rpc("record_line_order", {
    p_line: lineId, p_order_id: order.orderId,
  });
  if (orderIdErr) {
    console.error(JSON.stringify({
      alert: "line_order_id_unrecorded", line: lineId, order: order.orderId,
      detail: orderIdErr.message,
    }));
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

  // 🔴 VOICE IS PROVISIONED HERE, not lazily on first dialer open — see
  // `_shared/lineVoice.ts`. Attaching the number's voice to a connection is
  // what makes it RING, and it lived only in `mint-line-token`, so a
  // subscription bought a number that could not receive a call until its owner
  // opened the Number tab. Best-effort: Apple has already taken the money, so a
  // voice fault must not fail the purchase, and the lazy path still repairs it.
  const voice = await provisionLineVoice(
    sb,
    { id: lineId, provider_number_id: typeof numberId === "string" ? numberId : null },
    { persistIds: false },
  );
  if (voice.faults.length) {
    console.error(JSON.stringify({
      alert: "line_voice_provision_failed", line: lineId,
      steps: voice.faults.map((f) => f.step),
      detail: voice.faults.map((f) => f.fault.detail).join("; "),
    }));
  }

  const { data: activated, error: actErr } = await sb.rpc("activate_line_claim", {
    p_line: lineId,
    p_number_id: typeof numberId === "string" ? numberId : null,
    p_connection: voice.connectionId,
    p_msg_profile: msgProfile,
    p_voice_profile: voice.voiceProfileId,
    p_credential: voice.credentialId,
    p_period_end: periodEnd,
    // ⚠️ RE-QUOTED SERVER-SIDE, never taken from the request. Nothing reports
    // this again — the order response returns `cost_information: null` and the
    // number resource has no price field at all — so this is the only chance
    // to record it, and it is what we PAY. It used to be `body.monthly_cents`,
    // handed back by the client from the reserve step: a client-supplied COST,
    // the same category of mistake as a client-supplied price, and one that
    // makes the whole line look more profitable than it is.
    p_monthly_cost_cents: await quoteMonthlyCents(e164),
    p_order_id: order.orderId,
  });
  if (actErr || activated !== true) {
    // 🔴 THE PROVISIONING LOCKOUT. This branch used to return 500 and stop,
    // leaving the row `provisioning` forever — and because
    // phone_lines_one_live_per_user counts that status, the user was BARRED
    // from renting again while still paying Apple, with no path back except an
    // Apple refund. The number kept billing us too. Fail the line so they are
    // free, and give the number back so we stop paying for it; the 15-minute
    // reclaim sweep is the backstop if even this write is lost.
    console.error(JSON.stringify({
      alert: "line_activate_failed", line: lineId, detail: actErr?.message,
    }));
    await releaseIfPossible(e164);
    await failLine(sb, lineId, "activate_failed", userId, tx.originalTransactionId);
    return json({ error: "provision_failed" }, { status: 500 });
  }

  // `activate_line_claim` has no `p_attached`, so the one fact that decides
  // whether the phone RINGS is recorded separately, after the line is live.
  if (voice.attached) {
    await sb.rpc("record_line_voice_binding", { p_line: lineId, p_attached: true });
  }

  await alertNewLine(sb, e164, tx.originalTransactionId, tx.environment,
    linePlanLabel(tx));

  return json({ ok: true, line_id: lineId, e164, inbound_ready: voice.attached });
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
  if (typeof id !== "string") return;
  const r = await releaseNumber(id);
  // A release we could not make must not vanish. The line still gets failed,
  // and `release-lines`' orphan sweep is what finds a number whose
  // customer_reference points at a dead row — but only if we say so here.
  if (faultOf(r)) {
    console.error(JSON.stringify({
      alert: "line_orphan_number", e164, detail: r.detail,
    }));
  }
}

/** What Telnyx charges US for this number, per month, in cents.
 *
 *  ⚠️ Never the client's figure. The number is ours by the time this runs, so
 *  it is no longer in availability — we re-quote the same market instead,
 *  which is exactly what the reserve step priced against. Prices are per
 *  (country, area code) and measured flat at $1.00 for every US/CA local
 *  number probed, so a sibling number's quote IS this number's cost.
 *
 *  Falls back to that measured rate rather than to null: an unknown cost
 *  recorded as nothing reads as a free number and would flatter every margin
 *  reading over this table. */
async function quoteMonthlyCents(e164: string): Promise<number> {
  const FALLBACK = 100;
  try {
    const digits = e164.replace(/\D/g, "");
    // NANP: +1 then a 3-digit area code. Anything else is not a market we
    // sell, so do not pretend to price it.
    if (!digits.startsWith("1") || digits.length < 11) return FALLBACK;
    const areaCode = digits.slice(1, 4);
    const r = await searchNumbers({ country: "CA", areaCode, limit: 1 });
    if (faultOf(r) || r.length === 0 || !r[0].costKnown) return FALLBACK;
    return r[0].monthlyCents;
  } catch {
    return FALLBACK;
  }
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
  plan: string,
) {
  try {
    const { data: claimed } = await sb.from("telegram_events")
      .insert({ kind: "line", ref }).select("ref").maybeSingle();
    if (!claimed) return;   // already sent

    const sandbox = env !== "Production" ? `\n<i>${esc(env)}</i>` : "";
    const r = await sendMessage(
      `📞 <b>New second number</b>\n${esc(e164)} · ${esc(plan)}${sandbox}`);
    if (!r.ok) {
      console.error("line alert send failed, releasing claim", r.status, r.body);
      await sb.from("telegram_events")
        .delete().eq("kind", "line").eq("ref", ref);
    }
  } catch (e) {
    console.error("alertNewLine failed (ignored):", e);
  }
}
