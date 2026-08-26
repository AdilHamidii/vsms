// Give a rented line a fresh phone number, paid in credits.
//
// ── Why this exists ───────────────────────────────────────────────────────
//
// A yearly subscriber is locked to one number for a year. If that number gets
// spam-flagged or blocked by a service they care about, their $99.99 buys a
// dead product and the only move left is reportaproblem.apple.com. This is the
// cheap escape hatch that stops an Apple refund — it is refund DEFENCE, not a
// revenue line, and it should be priced so nobody hesitates.
//
// ── The ordering, and why it is not the rental's ordering ─────────────────
//
// `verify-line-subscription` reserves BEFORE Apple charges, because an Apple
// refund is the one money path we cannot drive. Here the charge is credits,
// which we own and can return in the same transaction, so the cheaper
// ordering is fine: charge → buy → cut over → release the old one.
//
// The user is never without a working number. The OLD number keeps receiving
// right up to `complete_line_swap`, and if anything fails before that point
// the swap is refunded and they still have the number they started with.
//
// ── The new number matches the old one's area code, deliberately ──────────
//
// Nobody wants a Vancouver number to become a Halifax one. Inside NANP the old
// number's own area code says which pool to search, so this function needs no
// locality lookup at all.
//
// ⚠️ OUTSIDE NANP THERE IS NO AREA CODE TO EXTRACT. A `+44` number carries no
// three-digit field that means "London", so the line's stored `locality` is the
// only handle on where it came from — and when that is absent (an older row, or
// an Apple-billed line, which does not stamp it) the search is country-wide.
// Country-wide is a degradation, never a country change.
//
// 🔴 SAME-COUNTRY IS AN INVARIANT. A swap replaces a number; it never moves a
// user to a different country. Everything below derives the country from
// `phone_lines.country_code` and nothing may take it from a request.

import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import {
  searchNumbers, orderNumber, getOrder, findNumberId,
  attachMessagingProfile, releaseNumber, getBalance, faultOf,
} from "../_shared/telnyx.ts";
import { provisionLineVoice } from "../_shared/lineVoice.ts";
import {
  searchProfileFor, localitiesFor, loadLineCatalogConfig,
  withinWholesaleCeiling,
} from "../_shared/lineCatalog.ts";
import { NANP } from "../_shared/phone.ts";

/** Same headroom as the rental path, and for the same reason: a number must
 *  not be bought with too little left behind it to carry its own traffic. */
const BALANCE_BUFFER_CENTS = 50;
const ORDER_POLL_ATTEMPTS = 10;
const ORDER_POLL_MS = 1500;

/** `+14165551234` -> `416`. Null for anything that is not NANP — an area code
 *  is a NANP concept, and guessing one out of a format we do not recognise
 *  would search the wrong pool. Callers must only ask this of a +1 line; a
 *  non-NANP line uses its stored `locality` instead. */
function areaCodeOf(e164: string | null): string | null {
  if (!e164) return null;
  const m = /^\+1(\d{3})\d{7}$/.exec(e164);
  return m ? m[1] : null;
}

Deno.serve(async (req) => {
  const pre = handleCors(req);
  if (pre) return pre;
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, { status: 405 });
  }

  const userId = await callerUserId(req);
  if (!userId) return json({ error: "unauthorized" }, { status: 401 });

  let body: { line_id?: string } = {};
  try { body = await req.json(); } catch { /* caught by the guard below */ }
  const lineId = body.line_id ?? "";
  if (!lineId) return json({ error: "bad_request" }, { status: 400 });

  const sb = admin();

  // Fails CLOSED, like every other reader of this flag: a pause we cannot read
  // must not be treated as "not paused". A swap buys a number, so it is
  // exactly the thing a pause is meant to stop.
  const { data: pausedRow, error: pausedErr } = await sb.from("app_config")
    .select("value").eq("key", "lines_paused").maybeSingle();
  if (pausedErr || (pausedRow?.value as boolean | null) !== false) {
    return json({ error: "lines_paused" }, { status: 409 });
  }

  // Read the line BEFORE charging, so an area code we cannot parse refuses for
  // free rather than after taking credits.
  // ⚠️ ONE string literal, not a concatenation. supabase-js infers the row
  // type by parsing this argument, and a runtime-built string collapses it to
  // `GenericStringError` — every field access then fails to type-check.
  const { data: line, error: lineErr } = await sb.from("phone_lines")
    .select("id, user_id, status, e164, country_code, number_type, locality, provider_number_id, provider_connection_id, provider_credential_id, provider_voice_profile_id")
    .eq("id", lineId).maybeSingle();
  if (lineErr) return json({ error: "server_error" }, { status: 500 });
  if (!line || line.user_id !== userId) {
    return json({ error: "line_unavailable" }, { status: 404 });
  }

  // ⚠️ The country is the LINE'S, never a request field and never the literal
  // "CA" this used to send. `country_code` is nullable on rows that predate it,
  // and CA is the only country ever sold on this path, so it is the fallback.
  const country = String(line.country_code ?? "CA").toUpperCase();
  const numberType = String(line.number_type ?? "local");

  const area = NANP.has(country) ? areaCodeOf(line.e164 as string | null) : null;
  if (NANP.has(country) && !area) {
    console.error(JSON.stringify({
      alert: "line_swap_unparseable_number", line: lineId, e164: line.e164,
    }));
    return json({ error: "swap_unavailable" }, { status: 409 });
  }

  // Outside NANP the line's stored locality is the only handle on where the
  // number came from. Absent (an older row, or an Apple-billed line, which does
  // not stamp it) means a country-wide search — a degradation, never a country
  // change.
  let localityFilter: string | null = null;
  let adminAreaFilter: string | null = null;
  if (!area && line.locality) {
    const rows = await localitiesFor(sb, country, numberType);
    const match = rows.find((l) => l.id === String(line.locality));
    localityFilter = match?.locality ?? null;
    adminAreaFilter = match?.adminArea ?? null;
  }

  // ── Stock, ceiling and float, all before the charge ──────────────────────
  // ⚠️ Features come from the catalog, and `[]` (no filter) on any doubt. A
  // hardcoded `sms+voice` returns 400 `10015` on a voice-only country, which
  // `classifyTelnyxFault` maps to TRANSPORT_ERROR — so a swap on a perfectly
  // healthy GB line would read as a Telnyx outage. Unlike the sellers, a swap
  // is NOT gated on sellability: it keeps an existing paying line alive, and
  // refusing it because the country's regulatory status moved after the sale
  // would strand exactly the subscriber this feature exists to retain.
  const cfg = await loadLineCatalogConfig(sb);
  const profile = await searchProfileFor(sb, country, numberType);
  const found = await searchNumbers({
    country, numberType, limit: 8, features: profile.features,
    ...(area ? { areaCode: area } : {}),
    ...(localityFilter ? { locality: localityFilter } : {}),
    ...(adminAreaFilter ? { administrativeArea: adminAreaFilter } : {}),
  });
  if (faultOf(found)) {
    // A stockout is the user's problem to retry; anything else is ours, and
    // must not be dressed up as "no numbers" — that sends them back into the
    // same wall. Same distinction `reserve-line-number` draws.
    if (found.type === "OUT_OF_STOCK") {
      return json({ error: "no_numbers_available" }, { status: 409 });
    }
    console.error(JSON.stringify({
      alert: "line_swap_provider_fault", line: lineId, country,
      fault: found.type,
    }));
    return json({ error: "provider_unreachable" }, { status: 502 });
  }
  const offer = found[0];
  if (!offer) return json({ error: "no_numbers_available" }, { status: 409 });

  // The wholesale ceiling, before the credits move. Refusing here costs the
  // user nothing; refusing after `begin_line_swap` means charging for a number
  // we then hand back.
  const ceiling = withinWholesaleCeiling(offer, cfg, country);
  if (!ceiling.ok) {
    console.error(JSON.stringify({
      alert: "line_wholesale_ceiling", context: "swap", reason: ceiling.reason,
      line: lineId, country, number: offer.phoneNumber,
      monthly_cents: offer.monthlyCents, upfront_cents: offer.upfrontCents,
      currency: offer.currency, cost_known: offer.costKnown,
    }));
    return json({ error: "line_wholesale_ceiling", reason: ceiling.reason },
                { status: 409 });
  }

  const unknownCostPad = offer.costKnown ? 0 : offer.monthlyCents;
  const needCents = offer.upfrontCents + offer.monthlyCents +
                    BALANCE_BUFFER_CENTS + unknownCostPad;
  const bal = await getBalance();
  if (faultOf(bal)) return json({ error: "provider_unreachable" }, { status: 502 });
  if (Math.round(bal.usd * 100) < needCents) {
    console.error(JSON.stringify({
      alert: "line_float_exhausted", context: "swap",
      balance_usd: bal.usd, need_cents: needCents, line: lineId,
    }));
    return json({ error: "swap_unavailable" }, { status: 409 });
  }

  // ── Charge ───────────────────────────────────────────────────────────────
  const { data: begun, error: beginErr } = await sb.rpc("begin_line_swap", {
    p_user: userId, p_line: lineId,
  });
  if (beginErr) {
    console.error(JSON.stringify({
      alert: "line_swap_begin_failed", line: lineId, detail: beginErr.message,
    }));
    return json({ error: "server_error" }, { status: 500 });
  }
  if (!begun?.ok) {
    const reason = String(begun?.reason ?? "swap_unavailable");
    const status = reason === "insufficient_credits" ? 402
      : reason === "swap_in_progress" ? 409
      : reason === "swap_too_soon" ? 429 : 409;
    return json({ error: reason, ...begun }, { status });
  }
  const swapId = String(begun.swap_id);

  /** Refund and give the reason back to the client. Every failure after the
   *  charge goes through here — there is no path that returns an error while
   *  leaving the credits spent. */
  const refund = async (reason: string, httpStatus: number, clientError: string) => {
    const { data: undone, error: failErr } = await sb.rpc("fail_line_swap", {
      p_swap: swapId, p_reason: reason,
    });
    if (failErr || undone !== true) {
      // The charge stands and nothing revisits it. This is the one outcome
      // that needs a human, so it pages rather than being logged quietly.
      console.error(JSON.stringify({
        alert: "line_swap_refund_failed", swap: swapId, line: lineId,
        user: userId, credits: begun.credits_charged, reason,
        detail: failErr?.message,
      }));
    }
    return json({ error: clientError }, { status: httpStatus });
  };

  // ── Buy the replacement ──────────────────────────────────────────────────
  // `customer_reference` is the line id, matching the rental path — it is what
  // makes a number with no live line pointing at it findable later.
  const order = await orderNumber(offer.phoneNumber, lineId, {
    requirementGroupId: profile.requirementGroupId,
  });
  if (faultOf(order)) {
    return await refund(`order_${order.type}`, 502, "provider_unreachable");
  }

  let newE164: string | null = null;
  for (let i = 0; i < ORDER_POLL_ATTEMPTS; i++) {
    const st = await getOrder(order.orderId);
    if (faultOf(st)) break;
    const n = st.numbers[0];
    // Bought and unusable pending regulatory documents. CA/US need none, so
    // this means something changed upstream — give it back rather than wait.
    if (n?.status === "requirement-info-pending") {
      const rel = await findNumberId(offer.phoneNumber);
      if (typeof rel === "string") await releaseNumber(rel);
      return await refund("requirements_pending", 502, "provider_unreachable");
    }
    if (st.status === "success" && n?.e164) { newE164 = n.e164; break; }
    if (st.status === "failed") break;
    await new Promise((r) => setTimeout(r, ORDER_POLL_MS));
  }

  if (!newE164) {
    // It may still land after we stop looking, so do NOT release blindly —
    // that is what the orphan reconciler is for. The user keeps their old
    // number and their credits.
    console.error(JSON.stringify({
      alert: "line_swap_order_timeout", swap: swapId, line: lineId,
      order: order.orderId, number: offer.phoneNumber,
    }));
    return await refund("order_timeout", 504, "provider_unreachable");
  }

  // ── Wire the new number up BEFORE cutting over ───────────────────────────
  // Inbound SMS routes through the messaging profile; without it the new
  // number is silent, which is the whole product.
  const newNumberId = await findNumberId(newE164);
  const msgProfile = Deno.env.get("TELNYX_MESSAGING_PROFILE_ID") ?? null;
  if (typeof newNumberId === "string" && msgProfile) {
    const attached = await attachMessagingProfile(newNumberId, msgProfile);
    if (faultOf(attached)) {
      // Fatal HERE, unlike the rental path where Apple has already been paid
      // and a half-working line beats none. Credits are refundable, so the
      // honest move is to give the number back and the credits too.
      if (typeof newNumberId === "string") await releaseNumber(newNumberId);
      console.error(JSON.stringify({
        alert: "line_swap_msg_profile_failed", swap: swapId, line: lineId,
        detail: attached.detail,
      }));
      return await refund("msg_profile_failed", 502, "provider_unreachable");
    }
  }

  // ── Cut over ─────────────────────────────────────────────────────────────
  const { data: done, error: doneErr } = await sb.rpc("complete_line_swap", {
    p_swap: swapId,
    p_new_e164: newE164,
    p_new_number_id: typeof newNumberId === "string" ? newNumberId : null,
    p_order_id: order.orderId,
  });
  if (doneErr || done !== true) {
    // We own a number the line does not point at. Release it so it stops
    // billing, then refund — the user is left exactly as they started.
    if (typeof newNumberId === "string") await releaseNumber(newNumberId);
    console.error(JSON.stringify({
      alert: "line_swap_cutover_failed", swap: swapId, line: lineId,
      new_number: newE164, detail: doneErr?.message,
    }));
    return await refund("cutover_failed", 500, "server_error");
  }

  // ── Point the new number's voice at the line's existing connection ───────
  // `provider_voice_attached` was set false by the cutover, which is what
  // makes step 3 of `provisionLineVoice` run. The connection, outbound profile
  // and credential all survive the swap because they are named after the LINE,
  // not the number. Best-effort: the number already works for SMS, and the
  // hourly `sync-line-voice` repairs a failed attach.
  const voice = await provisionLineVoice(sb, {
    id: lineId,
    provider_number_id: typeof newNumberId === "string" ? newNumberId : null,
    provider_connection_id: line.provider_connection_id as string | null,
    provider_credential_id: line.provider_credential_id as string | null,
    provider_voice_profile_id: line.provider_voice_profile_id as string | null,
    provider_voice_attached: false,
  }, { persistIds: true });
  if (voice.faults.length) {
    console.error(JSON.stringify({
      alert: "line_swap_voice_attach_failed", swap: swapId, line: lineId,
      steps: voice.faults.map((f) => f.step),
    }));
  }

  // ── Give the old number back ─────────────────────────────────────────────
  // Last, and non-fatal. The swap is already complete from the user's side; if
  // this fails the number keeps billing us until the sweep drains it, which is
  // strictly better than releasing before the cutover and risking a user with
  // no number at all.
  const oldNumberId = begun.old_provider_number_id ??
                      (line.provider_number_id as string | null);
  if (oldNumberId) {
    const released = await releaseNumber(String(oldNumberId));
    if (faultOf(released)) {
      console.error(JSON.stringify({
        alert: "line_swap_old_release_failed", swap: swapId, line: lineId,
        old_number_id: oldNumberId, detail: released.detail,
      }));
    } else {
      await sb.rpc("mark_swap_old_released", { p_swap: swapId });
    }
  } else {
    // Nothing to release — record it so the sweep does not chase it forever.
    await sb.rpc("mark_swap_old_released", { p_swap: swapId });
  }

  return json({
    phone_number: newE164,
    previous_number: line.e164,
    credits_charged: begun.credits_charged,
    balance: begun.balance,
    voice_ready: voice.attached,
  });
});
