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
import { searchNumbers, faultOf } from "../_shared/telnyx.ts";
import {
  completeLineProvision, DEFAULT_LINE_COUNTRY,
} from "../_shared/lineProvision.ts";
import { sendMessage, esc } from "../_shared/telegram.ts";
import { sellableCountry, catalogFaultOf } from "../_shared/lineCatalog.ts";
import { NANP } from "../_shared/phone.ts";

/** Shipped 2.3 sends no country. Defaults on BOTH null and absent.
 *  ⚠️ One definition, in `_shared/lineProvision.ts`: this default is also the
 *  fallback place `apple-notifications` reprovisions into, and two copies of it
 *  is how the three CITIES maps drifted. */
const DEFAULT_COUNTRY = DEFAULT_LINE_COUNTRY;

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
    country?: string | null;
    number_type?: string | null;
    /** @deprecated Accepted and IGNORED. This is a COST, and a client-supplied
     *  cost is the same category of mistake as a client-supplied price — it is
     *  re-quoted by `quoteMonthlyCents`. Kept in the shape so shipped builds
     *  that still send it are not rejected. */
    monthly_cents?: number;
  } = {};
  try { body = await req.json(); } catch { /* guarded below */ }

  const jws = body.signed_transaction ?? "";
  const wanted = body.phone_number ?? "";
  const country = (body.country ?? DEFAULT_COUNTRY).toUpperCase();
  const numberType = body.number_type ?? "local";
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
    p_country: country,
    p_number_type: numberType,
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

  // ── 3b. The country gate, RE-CHECKED after the JWS and before the buy ────
  //
  // `reserve-line-number` already checked this before the paywall, but minutes
  // can pass between the reservation and the purchase and Apple has the money
  // by the time we get here. Refusing and paging beats ordering a number that
  // arrives `requirement-info-pending` — bought, unusable, billing us $1/month
  // and unrefundable from our side. That is the $3.83 GB lesson with a $9.99
  // subscription attached to it.
  //
  // Fails CLOSED, like every other reader: unreadable and stale both refuse.
  const sellable = await sellableCountry(sb, country, numberType);
  if (catalogFaultOf(sellable)) {
    console.error(JSON.stringify({
      alert: "line_country_not_sellable_at_purchase",
      user: userId, tx: tx.originalTransactionId, country,
      number_type: numberType, reason: sellable.reason, detail: sellable.detail,
    }));
    await failLine(sb, lineId, "country_not_sellable", userId,
                   tx.originalTransactionId);
    return json({ error: "country_not_sellable" }, { status: 409 });
  }

  // ── 4-7. Buy it, configure it, activate it ───────────────────────────────
  // ONE sequence, shared with `rent-line-credits` and with the reprovision
  // path in `apple-notifications` (`_shared/lineProvision.ts`). It used to be
  // written out here and again there; a third copy is how voice provisioning
  // ended up in one path and not the other.
  const done = await completeLineProvision(sb, {
    lineId, e164: wanted, country, numberType,
    requirementGroupId: sellable.requirementGroupId,
    periodEnd,
    // Re-quoted AFTER the buy, from the number we actually got.
    quoteCost: (got) => quoteMonthlyCents(got, country, numberType, sellable.features),
    // Apple owns the money on this line and we cannot refund it from here, so
    // "undo" is freeing the user to rent again, plus a page.
    onFail: (reason) => failLine(sb, lineId, reason, userId, tx.originalTransactionId),
  });
  if (!done.ok) {
    return json({ error: done.reason }, { status: done.status });
  }
  const e164 = done.e164;

  await alertNewLine(sb, e164, tx.originalTransactionId, tx.environment,
    linePlanLabel(tx));

  return json({ ok: true, line_id: lineId, e164, inbound_ready: done.inboundReady });
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

/** What Telnyx charges US for this number, per month, in cents.
 *
 *  ⚠️ Never the client's figure. The number is ours by the time this runs, so
 *  it is no longer in availability — we re-quote the same market instead,
 *  which is exactly what the reserve step priced against. Prices are per
 *  (country, area code) and measured flat at $1.00 for every US/CA local
 *  number probed, so a sibling number's quote IS this number's cost.
 *
 *  ⚠️ THE COUNTRY IS THE LINE'S, NOT THE LITERAL `"CA"` THIS USED TO SEND.
 *  Area-code extraction is a NANP concept and the +1 prefix cannot tell US
 *  from CA — outside NANP there is no area code at all, so the re-quote is
 *  country-wide (optionally narrowed by nothing, which is correct: every
 *  number in a non-NANP country we sell is quoted at one flat rate today, and
 *  a wrong narrowing would return zero rows and silently take the fallback).
 *
 *  `features` comes from the catalog for the same reason every other search
 *  does: a hardcoded `sms+voice` returns 400 `10015` on a voice-only country,
 *  which here would silently record the fallback as the cost.
 *
 *  Falls back to the measured NANP rate rather than to null: an unknown cost
 *  recorded as nothing reads as a free number and would flatter every margin
 *  reading over this table. ⚠️ That fallback is a NANP fact — outside NANP it
 *  is a guess, and it is knowingly accepted here because the number is ALREADY
 *  BOUGHT and a recorded guess beats a recorded zero. The place to refuse an
 *  unquoted non-NANP cost is `withinWholesaleCeiling`, before the purchase. */
async function quoteMonthlyCents(
  e164: string, country: string, numberType: string, features: string[],
): Promise<number> {
  const FALLBACK = 100;
  try {
    const cc = country.toUpperCase();
    if (NANP.has(cc)) {
      const digits = e164.replace(/\D/g, "");
      if (!digits.startsWith("1") || digits.length < 11) return FALLBACK;
      const areaCode = digits.slice(1, 4);
      const r = await searchNumbers({
        country: cc, numberType, areaCode, limit: 1, features,
      });
      if (faultOf(r) || r.length === 0 || !r[0].costKnown) return FALLBACK;
      return r[0].monthlyCents;
    }
    const r = await searchNumbers({ country: cc, numberType, limit: 1, features });
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
