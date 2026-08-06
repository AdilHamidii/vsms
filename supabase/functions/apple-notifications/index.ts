// App Store Server Notifications V2 — the only thing that keeps a rented line
// in step with Apple after the first purchase.
//
// Without this, a subscription renews at Apple and the app never hears: the
// allowance never resets, the period end goes stale, a lapsed card silently
// keeps a number we are still paying rent on, and a refunded subscriber keeps
// their number forever. The purchase flow is not survivable on its own.
//
// ── Deploy with --no-verify-jwt ────────────────────────────────────────────
// Apple sends no Supabase Authorization header. The gate here is the JWS
// signature chain, exactly as `telegram-webhook` is gated by its secret rather
// than by a JWT. Deploying without the flag 401s every notification and the
// failure is invisible — Apple just retries into a wall for three days.
//
// ── Persist BEFORE acting ──────────────────────────────────────────────────
// `notificationUUID` is Apple's idempotency key. The raw payload is written
// first so a crash mid-processing leaves a forensic record and a replay is a
// no-op, rather than the state machine advancing twice. Apple retries at
// 1h/12h/24h/48h/72h, and reconcile-subscriptions will replay the same
// transition from the other direction.
//
// ── Return 200 fast ────────────────────────────────────────────────────────
// A non-2xx puts Apple into its retry ladder. Anything slow (releasing a
// number at Telnyx) goes into EdgeRuntime.waitUntil, the same shape iap-verify
// already uses for Telegram.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import {
  verifyNotificationJWS, verifyTransactionJWS, verifyRenewalInfoJWS,
  isSubscriptionProduct,
} from "../_shared/iap.ts";
import { findNumberId, releaseNumber, faultOf } from "../_shared/telnyx.ts";
import { sendMessage, esc } from "../_shared/telegram.ts";

/** How long a suspended number is held before release. A DID costs cents for a
 *  week, and this is the difference between "fix your card and everything is as
 *  you left it" and "your number is gone, and so is everyone who knew it". */
const HOLD_DAYS = 7;

declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined;

Deno.serve(async (req) => {
  const pre = handleCors(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, { status: 405 });

  const raw = await req.text();
  let signedPayload: string;
  try {
    signedPayload = String(JSON.parse(raw).signedPayload ?? "");
  } catch {
    return json({ ok: true }, { status: 200 });   // never make Apple retry junk
  }
  if (!signedPayload) return json({ ok: true }, { status: 200 });

  // Chain-verified against Apple's PINNED root. Never decode-and-trust: the
  // original receipt verifier took the certificate out of the attacker-supplied
  // header and checked the signature against that same certificate.
  let n;
  try {
    n = await verifyNotificationJWS(signedPayload);
  } catch (e) {
    // A signature we cannot verify is not something Apple should retry — it is
    // either an attack or our own verifier being broken, and both need a human.
    console.error(JSON.stringify({ alert: "assn_verify_failed", detail: String(e) }));
    return json({ ok: true }, { status: 200 });
  }

  const sb = admin();

  // ── Persist first ────────────────────────────────────────────────────────
  const { data: claimed, error: claimErr } = await sb
    .from("line_notifications")
    .insert({
      notification_uuid: n.notificationUUID,
      notification_type: n.notificationType,
      subtype: n.subtype ?? null,
      raw_payload: signedPayload,
    })
    .select("notification_uuid").maybeSingle();

  if (claimErr) {
    // A duplicate is the NORMAL case — Apple retries. Anything else is a real
    // failure, and returning non-2xx asks Apple to try again, which is right.
    const dup = String(claimErr.code) === "23505";
    if (!dup) {
      console.error(JSON.stringify({ alert: "assn_persist_failed", detail: claimErr.message }));
      return json({ error: "persist_failed" }, { status: 500 });
    }
    return json({ ok: true, duplicate: true });
  }
  if (!claimed) return json({ ok: true, duplicate: true });

  try {
    await process(sb, n);
    await sb.from("line_notifications")
      .update({ processed_at: new Date().toISOString() })
      .eq("notification_uuid", n.notificationUUID);
  } catch (e) {
    // The row survives with the error recorded, so a failure is inspectable
    // rather than merely absent.
    await sb.from("line_notifications")
      .update({ process_error: String(e) })
      .eq("notification_uuid", n.notificationUUID);
    console.error(JSON.stringify({
      alert: "assn_process_failed", type: n.notificationType, detail: String(e),
    }));
  }

  return json({ ok: true });
});

async function process(sb: ReturnType<typeof admin>, n: Awaited<ReturnType<typeof verifyNotificationJWS>>) {
  const txJws = n.data?.signedTransactionInfo;
  const riJws = n.data?.signedRenewalInfo;
  if (!txJws) return;

  // Both inner payloads are JWS in their own right and are verified, never
  // decoded. A notification is exactly as trustworthy as its signatures.
  const tx = await verifyTransactionJWS(txJws);
  if (!isSubscriptionProduct(tx.productId)) return;   // not our line

  const ri = riJws ? await verifyRenewalInfoJWS(riJws).catch(() => null) : null;
  const originalTx = tx.originalTransactionId;
  const periodEnd = tx.expiresDate ? new Date(tx.expiresDate).toISOString() : null;

  const type = n.notificationType;
  const sub = n.subtype ?? "";

  switch (type) {
    // ── Live again ─────────────────────────────────────────────────────────
    case "SUBSCRIBED":
    case "DID_RENEW": {
      // Idempotent against `line_renewals` — Apple retries, and
      // reconcile-subscriptions replays the same renewal from the other side.
      // Without that tombstone one renewal resets the allowance several times
      // and hands out free capacity.
      const { error } = await sb.rpc("apply_line_renewal", {
        p_original_tx: originalTx,
        p_transaction_id: tx.transactionId,
        p_period_end: periodEnd,
        p_price_milli: tx.price ?? null,
        p_currency: tx.currency ?? null,
        p_storefront: tx.storefront ?? null,
        p_signed_transaction: txJws,
      });
      if (error) throw new Error(`apply_line_renewal: ${error.message}`);
      return;
    }

    // ── Payment trouble ────────────────────────────────────────────────────
    case "DID_FAIL_TO_RENEW": {
      if (sub === "GRACE_PERIOD") {
        // Service stays FULLY live. That is the entire reason Billing Grace
        // Period is enabled — cutting the user off during it defeats the point
        // and turns a card expiry into churn.
        const until = ri?.gracePeriodExpiresDate
          ? new Date(ri.gracePeriodExpiresDate).toISOString()
          : null;
        const { error } = await sb.rpc("enter_line_grace_claim", {
          p_original_tx: originalTx, p_grace_until: until,
        });
        if (error) throw new Error(`enter_line_grace_claim: ${error.message}`);
        return;
      }
      // Billing retry without grace: receive still works, send does not. The
      // user cannot control who texts them, so inbound is the last thing to go.
      const { error } = await sb.rpc("mark_line_past_due_claim", {
        p_original_tx: originalTx,
      });
      if (error) throw new Error(`mark_line_past_due_claim: ${error.message}`);
      return;
    }

    // ── Lapsed ─────────────────────────────────────────────────────────────
    case "GRACE_PERIOD_EXPIRED":
    case "EXPIRED": {
      // SUSPEND, do not release. The 7-day hold is the highest-leverage
      // decision in this whole product: a number costs cents for a week, and
      // losing it costs the user everyone who knew it.
      const hold = new Date(Date.now() + HOLD_DAYS * 86_400_000).toISOString();
      const { error } = await sb.rpc("suspend_line_claim", {
        p_original_tx: originalTx, p_hold_until: hold,
      });
      if (error) throw new Error(`suspend_line_claim: ${error.message}`);
      return;
    }

    // ── Turned auto-renew off ──────────────────────────────────────────────
    case "DID_CHANGE_RENEWAL_STATUS": {
      // NOT a lapse. The line stays fully live until `expires_at`; the UI just
      // says "Ends on <date>" instead of "Renews". Treating this as a
      // cancellation would cut off someone who has already paid for the month.
      const on = ri?.autoRenewStatus === 1 || sub === "AUTO_RENEW_ENABLED";
      const { error } = await sb.from("line_subscriptions")
        .update({ auto_renew: on, updated_at: new Date().toISOString() })
        .eq("original_transaction_id", originalTx);
      if (error) throw new Error(`auto_renew update: ${error.message}`);
      return;
    }

    // ── Money came back ────────────────────────────────────────────────────
    case "REFUND":
    case "REVOKE": {
      // No hold. Apple took the money back, so we stop paying rent immediately
      // — the reasoning that justifies a 7-day hold for a lapse (they might
      // fix their card) does not apply when the purchase itself was undone.
      const { data, error } = await sb.rpc("revoke_line_claim", {
        p_original_tx: originalTx,
        p_reason: tx.revocationReason ?? null,
      });
      if (error) throw new Error(`revoke_line_claim: ${error.message}`);

      const lineId = data?.line_id ? String(data.line_id) : null;
      if (lineId) {
        const work = releaseLine(sb, lineId);
        // Off the response path: Apple must get its 200 promptly, and a slow
        // Telnyx call would push us into the retry ladder.
        if (typeof EdgeRuntime !== "undefined") EdgeRuntime.waitUntil(work);
        else await work;
      }
      await alertOwner(`💸 <b>Line refunded</b>\n${esc(originalTx)}`, sb, originalTx);
      return;
    }

    default:
      // Unknown types are RECORDED and ignored, never guessed at. Apple adds
      // notification types; encoding a guess is what broke eSIM refunds.
      console.log(JSON.stringify({ assn_unhandled: type, subtype: sub }));
  }
}

/** Give the number back so we stop paying for it. */
async function releaseLine(sb: ReturnType<typeof admin>, lineId: string) {
  try {
    const { data: begun } = await sb.rpc("begin_release_line_claim", { p_line: lineId });
    if (begun?.ok !== true) return;

    const numberId = begun.provider_number_id
      ? String(begun.provider_number_id)
      : null;

    // Fall back to a lookup: an older row may predate us storing the id, and
    // failing to release means paying rent forever on a number nobody has.
    const id = numberId ?? await (async () => {
      const { data: row } = await sb.from("phone_lines")
        .select("e164").eq("id", lineId).maybeSingle();
      if (!row?.e164) return null;
      const found = await findNumberId(String(row.e164));
      return typeof found === "string" ? found : null;
    })();

    if (id) {
      const r = await releaseNumber(id);
      if (faultOf(r)) {
        // Left in `releasing` deliberately: the reclaim sweep and the orphan
        // reconciler both pick it up again. Marking it released here would
        // hide a number we are still being billed for.
        console.error(JSON.stringify({ alert: "line_release_failed", lineId }));
        return;
      }
    }
    await sb.rpc("confirm_line_released", { p_line: lineId });
  } catch (e) {
    console.error(JSON.stringify({ alert: "line_release_threw", lineId, detail: String(e) }));
  }
}

/** Exactly-once via the (kind, ref) claim row, releasing the claim on a failed
 *  send so the sweep can still deliver it. */
async function alertOwner(html: string, sb: ReturnType<typeof admin>, ref: string) {
  try {
    const { data: claimed } = await sb.from("telegram_events")
      .insert({ kind: "line_refund", ref }).select("ref").maybeSingle();
    if (!claimed) return;
    const r = await sendMessage(html);
    if (!r.ok) {
      await sb.from("telegram_events")
        .delete().eq("kind", "line_refund").eq("ref", ref);
    }
  } catch { /* an alert must never fail the notification */ }
}
