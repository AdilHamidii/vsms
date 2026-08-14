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
  // `original_transaction_id` is filled in by `process` once the INNER JWS is
  // verified — the column had no writer at all, which left the forensic trail
  // unjoinable to the line it describes, exactly the thing you need when our
  // state machine and Apple's disagree. It is deliberately not read off the
  // envelope here: ASSN V2 carries it inside the signed transaction, and
  // taking a join key from unverified bytes is the same mistake the chain
  // check exists to prevent.
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

    // 🔴 A DUPLICATE IS NOT NECESSARILY DONE.
    //
    // The row is claimed BEFORE processing, so a failed process left a claimed,
    // UNPROCESSED row — and every one of Apple's retries then short-circuited
    // here as "duplicate" and did nothing. The retry ladder existed and was
    // being swallowed: a renewal that failed once could never be applied, and
    // the only trace was a `process_error` nobody reads.
    const { data: prior } = await sb.from("line_notifications")
      .select("processed_at").eq("notification_uuid", n.notificationUUID).maybeSingle();
    if (prior?.processed_at) return json({ ok: true, duplicate: true });
    // Fall through and reprocess. `process` is idempotent by construction —
    // renewals are tombstoned in `line_renewals`, every claim function is
    // status-gated, and the release path re-checks at the provider.
  }

  try {
    await process(sb, n);
    await sb.from("line_notifications")
      .update({ processed_at: new Date().toISOString(), process_error: null })
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

    // ⚠️ NON-2XX ON PURPOSE, and it is the whole point of the reprocess branch
    // above. Apple retries at 1h/12h/24h/48h/72h; returning 200 here would
    // spend our only free retry ladder on a failure we have not fixed. The
    // header's "return 200 fast" rule is about not making Apple retry JUNK — a
    // transient failure on OUR side is exactly what retries are for.
    return json({ error: "process_failed" }, { status: 500 });
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

  // Now that the inner JWS is verified, join the forensic row to the
  // subscription it describes. Not fatal — the notification still processes if
  // this write fails — but it is the only thing that makes the trail useful.
  const { error: stampErr } = await sb.from("line_notifications")
    .update({ original_transaction_id: originalTx })
    .eq("notification_uuid", n.notificationUUID);
  if (stampErr) {
    console.error(JSON.stringify({
      alert: "assn_stamp_failed", uuid: n.notificationUUID, detail: stampErr.message,
    }));
  }

  const type = n.notificationType;
  const sub = n.subtype ?? "";

  // ⚠️ EVERY BRANCH BELOW IS AN *UPDATE* ON `line_subscriptions`, and an UPDATE
  // matching nothing is not an error. `record_line_subscription` is called from
  // exactly one place — `verify-line-subscription` — so a notification for a
  // subscription we have no row for (the purchase call never landed, the row
  // was lost, or Apple got here first) silently did nothing at all, forever.
  //
  // The row is only ever created here for a subscription we can ATTRIBUTE to a
  // user. Without a user id there is no line to act on and inventing one would
  // bind an entitlement to the wrong account — the precise failure
  // `subscription_bound` exists to prevent.
  await ensureSubscriptionRow(sb, originalTx, tx, periodEnd);

  switch (type) {
    // ── Live again ─────────────────────────────────────────────────────────
    case "SUBSCRIBED":
    case "DID_RENEW": {
      // Idempotent against `line_renewals` — Apple retries, and
      // reconcile-subscriptions replays the same renewal from the other side.
      // Without that tombstone one renewal resets the allowance several times
      // and hands out free capacity.
      const { data, error } = await sb.rpc("apply_line_renewal", {
        p_original_tx: originalTx,
        p_transaction_id: tx.transactionId,
        p_period_end: periodEnd,
        p_price_milli: tx.price ?? null,
        p_currency: tx.currency ?? null,
        p_storefront: tx.storefront ?? null,
        p_signed_transaction: txJws,
      });
      if (error) throw new Error(`apply_line_renewal: ${error.message}`);

      // `line_provisioning` means verify-line-subscription is mid-flight and
      // will set the period itself in seconds. The RPC claims NO tombstone in
      // that case precisely so a retry can still apply the renewal — so throw,
      // which now returns 500 and puts Apple's ladder to work. Swallowing it
      // would drop a renewal that is merely early.
      if (data?.ok !== true && data?.retryable === true) {
        throw new Error(`apply_line_renewal deferred: ${data?.reason}`);
      }
      // `allowance_reset: false` is legitimate — a subscription can outlive its
      // number — but it means the customer's month did NOT reset, so it is
      // recorded rather than assumed away.
      if (data?.ok === true && data?.allowance_reset === false) {
        console.log(JSON.stringify({
          assn_renewal_no_live_line: originalTx, reason: data?.reason ?? null,
        }));
      }
      // Alerts AFTER the state write succeeded — an alert must never describe
      // a transition that did not commit. Sandbox events (the reviewer's
      // subscription is always Sandbox) are labelled so they cannot be read
      // as revenue.
      const sandbox = tx.environment !== "Production"
        ? `\n<i>${esc(tx.environment ?? "?")}</i>` : "";
      if (type === "SUBSCRIBED") {
        // SAME (kind='line', ref=originalTx) claim as verify-line-subscription's
        // instant alert — whichever path runs first sends, the other no-ops,
        // and a purchase whose client call never landed still gets announced.
        await alertOwner(
          `📞 <b>New second number subscription</b>${sandbox}`,
          sb, originalTx, "line");
      } else {
        const amount = tx.price != null && tx.currency
          ? ` — ${(tx.price / 1000).toFixed(2)} ${esc(tx.currency)}` : "";
        // Ref is the renewal's OWN transaction id: unique per renewal, stable
        // across Apple's retry ladder, so retries dedupe and next month's
        // renewal still alerts.
        await alertOwner(
          `🔄 <b>Second number renewed</b>${amount}${sandbox}`,
          sb, `renew:${tx.transactionId}`, "line_event");
      }
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
        // notificationUUID as ref: unique per event, stable across Apple's
        // retry ladder — retries dedupe, a later re-entry into grace alerts.
        await alertOwner(
          `⚠️ <b>Line billing issue — in grace</b>` +
          (until ? `\nservice stays live until ${esc(until)}` : ""),
          sb, `grace:${n.notificationUUID}`, "line_event");
        return;
      }
      // Billing retry without grace: receive still works, send does not. The
      // user cannot control who texts them, so inbound is the last thing to go.
      const { error } = await sb.rpc("mark_line_past_due_claim", {
        p_original_tx: originalTx,
      });
      if (error) throw new Error(`mark_line_past_due_claim: ${error.message}`);
      await alertOwner(
        `⚠️ <b>Line past due</b>\noutbound paused, inbound still works`,
        sb, `pastdue:${n.notificationUUID}`, "line_event");
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
      await alertOwner(
        `❌ <b>Line subscription ended</b>\nnumber suspended — held ` +
        `${HOLD_DAYS} days, then released (rent stops)`,
        sb, `expired:${n.notificationUUID}`, "line_event");
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
      // The owner's "someone cancelled" signal — auto-renew off is the churn
      // event; EXPIRED only arrives when the paid month runs out.
      await alertOwner(
        on
          ? `🔔 <b>Line auto-renew re-enabled</b>`
          : `🔕 <b>Line cancelled (auto-renew off)</b>\nstays live until ` +
            `the period ends${periodEnd ? ` (${esc(periodEnd)})` : ""}`,
        sb, `renewstatus:${n.notificationUUID}`, "line_event");
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

/** Create the subscription row when only a notification knows about it.
 *
 *  Attribution comes from the LINE, which is keyed on the same original
 *  transaction id — never invented. If there is no line either, there is
 *  nothing this notification could act on and nothing is written: a row with a
 *  guessed user_id would bind an Apple entitlement to the wrong account, which
 *  is the exact replay `subscription_bound` exists to refuse. */
async function ensureSubscriptionRow(
  sb: ReturnType<typeof admin>,
  originalTx: string,
  tx: Awaited<ReturnType<typeof verifyTransactionJWS>>,
  periodEnd: string | null,
) {
  const { data: existing, error: readErr } = await sb.from("line_subscriptions")
    .select("original_transaction_id")
    .eq("original_transaction_id", originalTx).maybeSingle();
  if (readErr) {
    console.error(JSON.stringify({
      alert: "assn_sub_lookup_failed", detail: readErr.message,
    }));
    return;
  }
  if (existing) return;

  const { data: line, error: lineErr } = await sb.from("phone_lines")
    .select("user_id").eq("original_transaction_id", originalTx)
    .order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (lineErr || !line?.user_id) {
    console.error(JSON.stringify({
      alert: "assn_sub_unattributable", tx: originalTx,
      detail: lineErr?.message ?? "no line for this transaction",
    }));
    return;
  }

  const { data, error } = await sb.rpc("record_line_subscription", {
    p_original_tx: originalTx,
    p_user: line.user_id,
    p_product: tx.productId,
    p_state: "active",
    p_auto_renew: true,
    p_environment: tx.environment,
    p_expires_at: periodEnd,
    p_last_tx: tx.transactionId,
    p_signed_tx: null,
    p_storefront: tx.storefront ?? null,
    p_price_milli: tx.price ?? null,
    p_currency: tx.currency ?? null,
  });
  if (error || data?.ok !== true) {
    console.error(JSON.stringify({
      alert: "assn_sub_backfill_failed", tx: originalTx,
      detail: error?.message ?? data?.reason,
    }));
  }
}

/** Give the number back so we stop paying for it. */
async function releaseLine(sb: ReturnType<typeof admin>, lineId: string) {
  try {
    const { data: begun, error: beginErr } = await sb
      .rpc("begin_release_line_claim", { p_line: lineId });
    if (beginErr) {
      // Discarded before. A failed claim means the line is NOT in `releasing`,
      // so neither this function nor the reclaim sweep will ever come back for
      // it — the number keeps billing with nothing pointing at it.
      console.error(JSON.stringify({
        alert: "line_release_claim_failed", lineId, detail: beginErr.message,
      }));
      return;
    }
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
        // Left in `releasing` deliberately: `release-lines` sweeps that status
        // every 15 minutes and retries. Marking it released here would hide a
        // number we are still being billed for.
        console.error(JSON.stringify({ alert: "line_release_failed", lineId }));
        return;
      }
    }
    const { error: confirmErr } = await sb.rpc("confirm_line_released", { p_line: lineId });
    if (confirmErr) {
      // Discarded before. The number IS gone at the provider, so the money has
      // stopped — but the row still claims it, and the release sweep will keep
      // retrying a DELETE on a number that no longer exists. Loud, not fatal.
      console.error(JSON.stringify({
        alert: "line_release_confirm_failed", lineId, detail: confirmErr.message,
      }));
    }
  } catch (e) {
    console.error(JSON.stringify({ alert: "line_release_threw", lineId, detail: String(e) }));
  }
}

/** Exactly-once via the (kind, ref) claim row, releasing the claim on a failed
 *  send so the sweep can still deliver it.
 *
 *  `kind` must be a member of the telegram_events check constraint
 *  (20260814100000 added 'line_event') — a rejected insert loses the alert
 *  with no trace, which is why lifecycle alerts share ONE kind with prefixed
 *  refs instead of minting a new kind per event. */
async function alertOwner(
  html: string, sb: ReturnType<typeof admin>, ref: string, kind = "line_refund",
) {
  try {
    const { data: claimed } = await sb.from("telegram_events")
      .insert({ kind, ref }).select("ref").maybeSingle();
    if (!claimed) return;
    const r = await sendMessage(html);
    if (!r.ok) {
      await sb.from("telegram_events")
        .delete().eq("kind", kind).eq("ref", ref);
    }
  } catch { /* an alert must never fail the notification */ }
}
