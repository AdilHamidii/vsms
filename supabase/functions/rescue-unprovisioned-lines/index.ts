// Give a number to a subscriber who PAID AND NEVER RECEIVED ONE.
//
// 🔴 THE INCIDENT. Original transaction 700002748363888 — a $59.99 yearly
// bought 2026-08-22 — produced four Apple notifications and ZERO rows in
// `line_subscriptions` and `phone_lines`. Our own `verify-line-subscription`
// call never landed. The customer got no number, was billed again on the
// billing-recovery retry seventeen days later, and asked for a refund within
// eighty minutes. It was granted, correctly.
//
// ── Why every recovery we already had was insufficient ────────────────────
// They were all client-side. `SubscriptionStore.handle` deliberately leaves
// the StoreKit transaction unfinished so `IAPStore.restorePurchases()` sweeps
// it on the next launch — right, and not enough: it requires the user to
// reopen an app that has given them nothing. This one never did.
//
// `apple-notifications` now also provisions on a renewal, which covers the
// subscriber whose next Apple event arrives soon. A YEARLY whose only event is
// the initial purchase would otherwise wait up to a year. This sweep is the
// half that needs no user and no notification.
//
// ── What keeps it from buying numbers it should not ───────────────────────
// Every guard is in SQL, in `line_unprovisioned_subscriptions` and
// `line_reprovision_target`, so they hold however this function is invoked:
//   • Production only, and the entitlement must be live RIGHT NOW;
//   • no live Apple-billed line, matching `phone_lines_one_apple_line_per_user`
//     exactly, so a candidate is always one `begin_line_rental` will accept;
//   • the subscription must be older than 30 minutes, so this can never race
//     our own client call — the client owns the first purchase and lets the
//     user pick their own number, and provisioning under it would take that
//     choice away and then refuse their call with `line_exists`;
//   • ONE ATTEMPT PER DAY per user. A failed attempt ends `failed`, which sits
//     OUTSIDE that partial unique index so a retry CAN succeed — but without
//     the throttle a permanently broken subscription would be retried every
//     fifteen minutes, and every attempt that gets past the order call has
//     already spent $1 at Telnyx.
// `begin_line_rental` remains the mutex, so two overlapping runs cannot both
// provision: the loser gets `line_exists` and is silent.
//
// Cron-gated: deploy with `--no-verify-jwt`.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import { provisionForSubscription } from "../_shared/lineProvision.ts";
import { sendPush } from "../_shared/apns.ts";
import { sendMessage, esc } from "../_shared/telegram.ts";
import { alertHtml } from "../_shared/tgAlert.ts";

/** Bounded because the edge runtime dies at ~150s and each rescue is several
 *  provider calls. The sweep runs every 15 minutes, so a backlog drains on its
 *  own rather than needing one heroic invocation — and a small cap is also the
 *  blast radius if the candidate query is ever wrong. */
const MAX_RESCUES = 3;

/** How long our own client call gets before this concludes it is not coming.
 *  Mirrored by the SQL, which enforces it independently — this value only
 *  decides which rows are FETCHED; `line_reprovision_target` refuses a younger
 *  one whatever is passed here. */
const MIN_AGE_MINUTES = 30;

Deno.serve(async (req) => {
  const pre = handleCors(req);
  if (pre) return pre;

  if (req.headers.get("x-cron-secret") !== Deno.env.get("CRON_SECRET")) {
    return json({ error: "forbidden" }, { status: 403 });
  }

  const sb = admin();
  const { data: candidates, error: listErr } = await sb
    .rpc("line_unprovisioned_subscriptions", {
      p_min_age_minutes: MIN_AGE_MINUTES,
      p_limit: MAX_RESCUES,
    });
  if (listErr) {
    console.error(JSON.stringify({
      alert: "line_rescue_list_failed", detail: listErr.message,
    }));
    return json({ error: "list_failed" }, { status: 500 });
  }

  const rows = (candidates ?? []) as Array<Record<string, unknown>>;
  const rescued: string[] = [];
  const failed: Array<{ tx: string; reason: string }> = [];

  for (const row of rows) {
    const originalTx = String(row.original_transaction_id ?? "");
    if (!originalTx) continue;
    try {
      // Re-resolved rather than trusting the list: the candidate query ran
      // before any of the provider calls above it, so by now another delivery
      // may have provisioned this very subscriber. This RPC re-checks the
      // occupancy and the 30-minute window from scratch.
      const { data: target, error: targetErr } = await sb
        .rpc("line_reprovision_target",
             { p_original_tx: originalTx, p_allow_first: true });
      if (targetErr) {
        failed.push({ tx: originalTx, reason: targetErr.message });
        continue;
      }
      // They hold a line now: the guard working, and not worth a word.
      if (target?.reason === "line_exists") continue;
      if (target?.ok !== true) {
        failed.push({ tx: originalTx, reason: String(target?.reason ?? "refused") });
        continue;
      }

      const done = await provisionForSubscription(sb, {
        target: target as Record<string, unknown>,
        originalTx,
        productFallback: String(row.product_id ?? ""),
        // The SUBSCRIPTION's own expiry. Without it the new row carries no
        // `current_period_end` and `reclaim_lapsed_lines` suspends the line on
        // its next sweep — buying a $1 number and throwing it away.
        periodEnd: row.expires_at ? String(row.expires_at) : null,
      });
      if (!done.ok) {
        if (!done.silent) failed.push({ tx: originalTx, reason: done.reason });
        continue;
      }

      rescued.push(done.e164);
      const userId = String(target.user_id);
      // They have been paying for a number that did not exist. Tell them it
      // does now — `kind: "line_number"` with no `orderId`, because
      // `PushManager` routes on `orderId` and would deep-link to an order
      // screen that has nothing to do with this.
      await pushNewNumber(sb, userId, done.e164);
      await alertOwner(sb, alertHtml({
        sev: "ℹ️", title: "Rescued a paid subscriber with no number",
        what: `tx ${esc(originalTx)}\nnew number ${esc(done.e164)} (${esc(done.country)})` +
          (done.country !== done.wantedCountry
            ? `\n⚠️ ${esc(done.wantedCountry)} is no longer sellable — moved to ${esc(done.country)}`
            : ""),
        why: "They paid and our own purchase call never provisioned a number, so the sweep bought one. Nothing else would have: every other recovery needs the customer to reopen the app.",
        at: new Date(),
      }), `line_rescued:${originalTx}`);
    } catch (e) {
      failed.push({ tx: originalTx, reason: String(e) });
    }
  }

  // 🔴 A FAILURE HERE IS A CUSTOMER WHO HAS PAID AND STILL HAS NOTHING, so it
  // pages — but ONCE PER SUBSCRIPTION PER DAY, keyed on the transaction and
  // the UTC date, because the throttle in SQL already means one attempt a day
  // and a per-run page would say the same thing 96 times.
  for (const f of failed) {
    const day = new Date().toISOString().slice(0, 10);
    await alertOwner(sb, alertHtml({
      sev: "🟠", title: "Could not rescue a paid subscriber",
      what: `tx ${esc(f.tx)}\n${esc(f.reason)}`,
      why: "This subscription is live and has no number. They are paying for nothing until it is resolved.",
      action: "Check the Telnyx balance first — an order is refused outright below it. Otherwise reach out, or refund via Apple.",
      at: new Date(),
    }), `line_rescue_failed:${f.tx}:${day}`);
  }

  const { error: hbErr } = await sb.from("app_config").upsert({
    key: "line_rescue_heartbeat",
    value: {
      checked_at: new Date().toISOString(),
      candidates: rows.length,
      rescued: rescued.length,
      failed: failed.length,
    },
  });
  if (hbErr) {
    console.error(JSON.stringify({
      alert: "line_rescue_heartbeat_failed", detail: hbErr.message,
    }));
  }

  return json({ candidates: rows.length, rescued, failed });
});

/** Exactly-once against the `telegram_events` claim, byte-for-byte the shape
 *  `apple-notifications` uses: the claim is written BEFORE the send so a retry
 *  cannot double-page, a 23505 is the dedupe working, and ANY other error is
 *  logged — a rejected `kind` otherwise reads as "someone else already sent
 *  it" and the alert is lost on every retry, forever. */
async function alertOwner(
  sb: ReturnType<typeof admin>,
  html: string,
  ref: string,
) {
  try {
    const { data: claimed, error } = await sb.from("telegram_events")
      .insert({ kind: "line_event", ref }).select("ref").maybeSingle();
    if (error) {
      if (error.code !== "23505") {
        console.error(`line_rescue alert claim failed for ${ref}:`,
                      error.code, error.message);
      }
      return;
    }
    if (!claimed) return;
    const r = await sendMessage(html);
    // Release the claim so the next run can try again, rather than recording a
    // page that was never delivered.
    if (!r.ok) {
      await sb.from("telegram_events")
        .delete().eq("kind", "line_event").eq("ref", ref);
    }
  } catch { /* an alert must never fail the sweep */ }
}

async function pushNewNumber(
  sb: ReturnType<typeof admin>,
  userId: string,
  e164: string,
) {
  try {
    // `environment` per device: a sandbox token pushed to production APNs is
    // silently dropped.
    const { data: devices } = await sb.from("push_devices")
      .select("token, environment").eq("user_id", userId);
    for (const d of devices ?? []) {
      await sendPush(String(d.token), {
        alertTitle: "Your number is ready",
        alertBody: `${e164} is set up and can receive texts and calls.`,
        customData: { kind: "line_number" },
      }, (d.environment as "sandbox" | "production" | null) ?? undefined);
    }
  } catch (e) {
    // A push we could not send must never cost the number we just bought.
    console.error(JSON.stringify({
      alert: "line_rescue_push_failed", detail: String(e),
    }));
  }
}
