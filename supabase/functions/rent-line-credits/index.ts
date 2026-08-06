// Rent a number with CREDITS — the path that makes several numbers possible.
//
// Apple cannot express "three numbers": one active subscription per group, and
// `quantity` applies only to consumables. Credits have no such limit, so this
// is the only route to the multi-number product. `verify-line-subscription` is
// its Apple-billed sibling and stays exactly as it is; the provisioning half
// below is deliberately the SAME sequence, in the same order, because that
// sequence is what has already been debugged:
//
//   1. re-quote server-side          (never trust a client's number or price)
//   2. begin_credit_line_rental      (charge + row, ONE transaction)
//   3. orderNumber                   (customer_reference = line id)
//   4. record_line_order             (the only handle on an async purchase)
//   5. poll getOrder
//   6. attachMessagingProfile        (routes inbound SMS to our webhook)
//   7. activate_line_claim           (stamp the ids, flip to active)
//
// 🔴 EVERY failure after step 2 must refund. The money moved before the
// provider was ever called — deliberately, so a Telnyx failure can never leave
// a purchased number with nothing pointing at it — which means the refund is
// not a nicety, it is the other half of the charge. `refund_credit_line_claim`
// does the status flip and the credit in one transaction and clears the rent
// tombstone so a retry can charge again legitimately.

import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import {
  searchNumbers, orderNumber, getOrder, findNumberId, attachMessagingProfile,
  releaseNumber, faultOf,
} from "../_shared/telnyx.ts";

/** Mirrors `reserve-line-number` and `search-line-numbers`. The three must
 *  agree on what "Toronto" means or this buys from a different pool than the
 *  one the picker showed. */
const CITIES: Record<string, { country: string; codes: string[] }> = {
  toronto:   { country: "CA", codes: ["437", "647", "416", "905", "289"] },
  montreal:  { country: "CA", codes: ["438", "514"] },
  vancouver: { country: "CA", codes: ["604", "778", "236"] },
  calgary:   { country: "CA", codes: ["587", "403", "825"] },
  ottawa:    { country: "CA", codes: ["343", "613"] },
  halifax:   { country: "CA", codes: ["902", "782"] },
  winnipeg:  { country: "CA", codes: ["204", "431"] },
};

/** Owner decision 2026-08-06: 20 credits/month for 100 SMS + 50 minutes.
 *  A credit nets $0.397 blended, so this is ~$7.94 against ~$1 rent plus
 *  ~$2.15 worst-case usage. The allowance is deliberately smaller than the
 *  Apple plan's: credits are cheaper in bulk, so a 150-pack buyer nets us
 *  ~$6.80 and the full 200/100 would leave ~$1.50. */
const RENT_CREDITS = 20;
const SMS_ALLOWANCE = 100;
const VOICE_ALLOWANCE_SECONDS = 3000;

const ORDER_POLL_ATTEMPTS = 10;
const ORDER_POLL_MS = 1000;

async function refund(sb: ReturnType<typeof admin>, lineId: string, reason: string) {
  const { data, error } = await sb.rpc("refund_credit_line_claim", { p_line: lineId });
  // NEVER silent. This is the only thing that returns the user's credits, and
  // supabase-js RETURNS errors rather than throwing — a discarded one here is
  // the exact shape of the four wallet_credit bugs this repo has already paid
  // for.
  if (error || data !== true) {
    console.error(JSON.stringify({
      alert: "line_credit_refund_failed",
      line: lineId, reason, detail: error?.message ?? "claim returned false",
    }));
  }
}

Deno.serve(async (req) => {
  const pre = handleCors(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, { status: 405 });

  const userId = await callerUserId(req);
  if (!userId) return json({ error: "unauthorized" }, { status: 401 });

  let body: { city?: string; phone_number?: string } = {};
  try { body = await req.json(); } catch { /* guarded below */ }

  const cityKey = (body.city ?? "").toLowerCase();
  const wanted = body.phone_number ?? "";
  const city = CITIES[cityKey];
  if (!city || !wanted) return json({ error: "bad_request" }, { status: 400 });

  const sb = admin();

  // Fails CLOSED on a read error: a flag we cannot read must not be treated as
  // "not paused". Same precedent as the eSIM pause.
  const { data: pausedRow, error: pausedErr } = await sb.from("app_config")
    .select("value").eq("key", "lines_paused").maybeSingle();
  if (pausedErr || (pausedRow?.value as boolean | null) !== false) {
    return json({ error: "lines_paused" }, { status: 409 });
  }

  // ── 1. Re-quote. The client's number is a REQUEST, not a fact. ───────────
  // Walk the same codes in the same order the picker did and require the
  // requested number to still be in the result, so a stale pick fails here
  // rather than after the credits are gone.
  // ⚠️ `monthlyCents` is captured HERE and nowhere else. Neither the order
  // response nor the number resource ever reports a cost again — the order
  // returns `cost_information: null` and the resource has no price field at
  // all — so this quote is the only chance to record what Telnyx charges US.
  // Losing it makes margin analysis on this line impossible.
  let monthlyCents: number | null = null;
  let found = false;
  for (const code of city.codes) {
    const r = await searchNumbers({ country: city.country, areaCode: code, limit: 8 });
    if (faultOf(r)) {
      // Only a real stockout justifies trying the next code — a dead key or an
      // outage is not a stock problem, and walking on would end in a misleading
      // "that number is taken".
      if (r.type !== "OUT_OF_STOCK") {
        return json({ error: "provider_unreachable" }, { status: 502 });
      }
      continue;
    }
    const hit = r.find((n) => n.phoneNumber === wanted);
    if (hit) { found = true; monthlyCents = hit.monthlyCents ?? null; break; }
  }
  if (!found) return json({ error: "number_taken" }, { status: 409 });

  // ── 2. Charge + row, ONE transaction. ────────────────────────────────────
  // Enforces the pause, the per-user cap and the balance, all under the same
  // advisory lock, and rolls the row back if the spend fails.
  const { data: begun, error: beginErr } = await sb.rpc("begin_credit_line_rental", {
    p_user: userId,
    p_e164: wanted,
    p_country: city.country,
    p_number_type: "local",
    p_rent_credits: RENT_CREDITS,
    p_sms_allowance: SMS_ALLOWANCE,
    p_voice_allowance_seconds: VOICE_ALLOWANCE_SECONDS,
  });
  if (beginErr) {
    console.error(JSON.stringify({ alert: "line_rent_begin_failed", detail: beginErr.message }));
    return json({ error: "provision_failed" }, { status: 500 });
  }
  if (!begun?.ok) {
    const reason = String(begun?.reason ?? "provision_failed");
    // `insufficient_credits` and `line_limit_reached` are the user's to act on
    // and must not read as our fault; both are 409 with the reason intact.
    return json({ error: reason, limit: begun?.limit ?? null }, { status: 409 });
  }
  const lineId = String(begun.line_id);

  // ── 3. Buy it. `customer_reference` = the line id is what makes orphan
  //      reconciliation possible: a number we own with no live line pointing at
  //      it is otherwise invisible until the invoice.
  const order = await orderNumber(wanted, lineId);
  if (faultOf(order)) {
    await refund(sb, lineId, `order_${order.type}`);
    return json({ error: "provision_failed" }, { status: 502 });
  }

  // ── 4. Stamp the order id NOW, not on success. A purchase that fails after
  //      the buy is exactly when this handle matters: the order is ASYNCHRONOUS
  //      and the number may still arrive after we stop polling.
  const { error: orderIdErr } = await sb.rpc("record_line_order", {
    p_line: lineId, p_order_id: order.orderId,
  });
  if (orderIdErr) {
    console.error(JSON.stringify({
      alert: "line_order_id_unrecorded", line: lineId, order: order.orderId,
      detail: orderIdErr.message,
    }));
  }

  // ── 5. Poll. ─────────────────────────────────────────────────────────────
  let e164: string | null = null;
  for (let i = 0; i < ORDER_POLL_ATTEMPTS; i++) {
    const st = await getOrder(order.orderId);
    if (faultOf(st)) break;
    const n = st.numbers[0];
    // ⚠️ `requirement-info-pending` means BOUGHT AND UNUSABLE pending
    // regulatory documents. It reads like progress and is a dead end — the
    // mistake that cost $3.83 on a GB number. CA needs no documents, so seeing
    // it here means something changed and the number must be released.
    if (n?.status === "requirement-info-pending") {
      const id = await findNumberId(wanted);
      if (typeof id === "string") await releaseNumber(id);
      await refund(sb, lineId, "requirements_pending");
      return json({ error: "provision_failed" }, { status: 502 });
    }
    if (st.status === "success" && n?.e164) { e164 = n.e164; break; }
    if (st.status === "failed") break;
    await new Promise((r) => setTimeout(r, ORDER_POLL_MS));
  }

  if (!e164) {
    // Might still land after we stop looking, so do NOT release blindly — the
    // orphan reconciler sweeps a number that arrived late. Refund and page.
    await refund(sb, lineId, "order_timeout");
    return json({ error: "provision_failed" }, { status: 504 });
  }

  // ── 6/7. Configure and activate. ─────────────────────────────────────────
  // The messaging profile is what routes inbound SMS to our webhook, and it is
  // NOT settable on the main number resource (error 10027) — it lives on the
  // /messaging sub-resource.
  const numberId = await findNumberId(e164);
  const msgProfile = Deno.env.get("TELNYX_MESSAGING_PROFILE_ID") ?? null;
  if (typeof numberId === "string" && msgProfile) {
    const attached = await attachMessagingProfile(numberId, msgProfile);
    if (faultOf(attached)) {
      // Not fatal — the number exists and voice works — but inbound SMS goes
      // nowhere, so it pages.
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
    // The period the rent just bought. `begin_credit_line_rental` already set
    // current_period_end and next_debit_at 30 days out; this keeps the claim's
    // own view consistent with them.
    p_period_end: new Date(Date.now() + 30 * 86_400_000).toISOString(),
    // From the server-side re-quote, never from the request: this is what we
    // PAY, and a client-supplied cost is a client-supplied margin.
    p_monthly_cost_cents: monthlyCents,
  });
  if (actErr || activated !== true) {
    // The number is BOUGHT. Refunding the credits is right — the user has no
    // usable line — and the orphan reconciler is what recovers the DID, which
    // is why the line is not left half-activated.
    console.error(JSON.stringify({
      alert: "line_activate_failed", line: lineId,
      detail: actErr?.message ?? "claim returned false",
    }));
    await refund(sb, lineId, "activate_failed");
    return json({ error: "provision_failed" }, { status: 500 });
  }

  return json({ ok: true, line_id: lineId, e164, rent_credits: RENT_CREDITS });
});
