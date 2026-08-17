// Refresh a user's eSIM from its provider: activation state, data used/total,
// and (if it was still provisioning) the QR/activation payload.
//
// ROUTES ON esim_orders.provider — the column had ZERO readers until
// 2026-08-10, which meant a provider switch would have sent every legacy
// transaction id to the wrong vendor. 'smspool' rows (the pre-switch installed
// base) take the original code path VERBATIM; 'esimaccess' rows take the new
// one; anything unrecognised is returned untouched, because sending an id to
// the wrong vendor is worse than staleness.

import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import { esimProfile } from "../_shared/smspool.ts";
import {
  dataMbFromBytes, parseLpa, queryEsim, type EaProfile,
} from "../_shared/esimaccess.ts";
import { notifySafe, esc } from "../_shared/telegram.ts";

interface Body { order_id: string; }

// 🔴 A TERMINAL STATUS IS FINAL — never recompute one from provider signals.
// Shared by both provider branches; see the block comment in smspoolRefresh
// for the incident that made this a rule.
const TERMINAL = new Set(["expired", "refunded", "failed", "depleted"]);

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, { status: 405 });

  const userId = await callerUserId(req);
  if (!userId) return json({ error: "unauthorized" }, { status: 401 });

  let body: Body;
  try { body = await req.json(); }
  catch { return json({ error: "invalid_body" }, { status: 400 }); }
  if (!body.order_id) return json({ error: "missing_fields" }, { status: 400 });

  const sb = admin();

  const { data: order, error: oErr } = await sb
    .from("esim_orders")
    .select("*")
    .eq("id", body.order_id).eq("user_id", userId).single();
  if (oErr || !order) return json({ error: "order_not_found" }, { status: 404 });

  if (order.provider === "esimaccess") return await esimaccessRefresh(sb, order);
  if (order.provider === "smspool") return await smspoolRefresh(sb, order);
  console.error(`check-esim-usage: unknown provider '${order.provider}' order=${order.id}`);
  return json({ order });
});

// ── SMSPool (legacy — the 12 pre-switch eSIMs). Body preserved VERBATIM from
//    the pre-routing version of this function; do not edit it, its users can
//    no longer be re-served by anyone else. ─────────────────────────────────

// deno-lint-ignore no-explicit-any
async function smspoolRefresh(sb: ReturnType<typeof admin>, order: any): Promise<Response> {
  if (!order.smspool_tx) return json({ order });

  let profile;
  try { profile = await esimProfile(order.smspool_tx); }
  catch { return json({ order }); }
  if (!profile.ok) return json({ order });

  // 🔴 A TERMINAL STATUS IS FINAL — never recompute one from `activated`.
  //
  // `profile.activated` is a permanent historical fact: SMSPool keeps reporting
  // it forever, and this same function relies on that to stamp `activated_at`.
  // Recomputing status from it flipped an ALREADY-EXPIRED eSIM back to `active`
  // on every view — and since `.active` is a polling state on the client, the
  // detail screen's 8-second loop then held it there against the */15 expiry
  // sweep. 8 rows were sitting in exactly that state when this was found.
  //
  // `depleted` is terminal here too, and that is the variant that could NOT
  // self-heal: the depleted test needs both usage figures, so once the provider
  // stops reporting them `activated` becomes the only signal left and "you have
  // used all your data" silently became "active" with no way back. Only
  // `expire_esim_orders()` moves a row out of these states.

  let status = order.status as string;
  if (!TERMINAL.has(status)) {
    const depleted = profile.dataTotalMb != null && profile.dataUsedMb != null &&
      profile.dataUsedMb >= profile.dataTotalMb;
    if (depleted) status = "depleted";
    else if (profile.activated) status = "active";
    else if (status === "provisioning") status = "installed";
  }

  const patch: Record<string, unknown> = {
    status,
    activated: profile.activated ?? false,
    updated_at: new Date().toISOString(),
  };
  // Start the validity clock the first time we observe the eSIM activated.
  // Before this, expires_at was NEVER set anywhere, so a lapsed 1-day plan
  // showed "active" forever — a wrong claim the user acts on abroad.
  if (profile.activated && !order.activated_at) {
    patch.activated_at = new Date().toISOString();
  }
  if (profile.activated && !order.expires_at) {
    const { data: plan } = await sb
      .from("esim_plans").select("validity_days")
      .eq("id", order.plan_id).maybeSingle();
    if (plan?.validity_days) {
      patch.expires_at = new Date(
        Date.now() + (plan.validity_days as number) * 86_400_000,
      ).toISOString();
    }
  }
  if (profile.dataTotalMb != null) patch.data_total_mb = profile.dataTotalMb;
  if (profile.dataUsedMb != null) patch.data_used_mb = profile.dataUsedMb;
  // Fill delivery fields only if we didn't already have them.
  if (!order.activation_code && profile.activationCode) patch.activation_code = profile.activationCode;
  if (!order.smdp_address && profile.smdp) patch.smdp_address = profile.smdp;
  if (!order.matching_id && profile.matchingId) patch.matching_id = profile.matchingId;
  if (!order.apn && profile.apn) patch.apn = profile.apn;
  // Backfill PIN/PUK for eSIMs bought before we captured them — a user stuck
  // at the iOS "enter SIM PIN" prompt has no other way to get it.
  if (!order.sim_pin && profile.pin) patch.sim_pin = profile.pin;
  if (!order.sim_puk && profile.puk) patch.sim_puk = profile.puk;

  // Atomic claim, the same rule every other status writer in this repo follows.
  // Without `.eq("status", …)` this UPDATE can overwrite a terminal state the
  // */15 expiry sweep wrote between our read above and this write. Losing the
  // race is not an error — the sweep's verdict is newer than ours — so hand
  // back what we read rather than erroring, and let the next poll refresh it.
  const { data: updated } = await sb
    .from("esim_orders").update(patch)
    .eq("id", order.id).eq("status", order.status)
    .select("*").maybeSingle();

  return json({ order: updated ?? order });
}

// ── eSIM Access ─────────────────────────────────────────────────────────────

// deno-lint-ignore no-explicit-any
async function esimaccessRefresh(sb: ReturnType<typeof admin>, order: any): Promise<Response> {
  // Purchase died before the provider order was persisted — nothing to ask.
  if (!order.ea_order_no) return json({ order });

  const q = await queryEsim(
    order.ea_tran_no
      ? { esimTranNo: order.ea_tran_no as string }
      : { orderNo: order.ea_order_no as string },
  );
  if (!q.ok) {
    console.error(`check-esim-usage: query fault order=${order.id}: ${q.error}`);
    return json({ order });
  }
  // Still allocating (200010 or empty list) — not an error; the client keeps
  // polling and allocation completes within ~30s of purchase.
  if (!q.profile) return json({ order });
  const p: EaProfile = q.profile;

  // Same terminal rule as the legacy branch: only expire_esim_orders() (or a
  // human) moves a row out of a terminal state.
  let status = order.status as string;
  let providerClosed: "cancel" | null = null;

  const es = p.esimStatus ?? "";
  // "Activated" from any of three independent signals — esimStatus reaching a
  // usage state, an installation timestamp, or the SM-DP+ reporting the
  // profile on a device. installationTime alone would miss nothing, but the
  // other two survive fields the provider omits.
  const activatedNow = order.activated === true ||
    es === "IN_USE" || es === "USED_UP" || es === "USED_EXPIRED" ||
    p.installationTime != null ||
    ["INSTALLATION", "ENABLED", "DISABLED"].includes(p.smdpStatus ?? "");

  if (!TERMINAL.has(status)) {
    if (es === "USED_UP") status = "depleted";
    else if (es === "UNUSED_EXPIRED" || es === "USED_EXPIRED") status = "expired";
    else if (es === "CANCEL" || es === "REVOKE" || es === "REVOKED") {
      providerClosed = "cancel";
      if (status === "provisioning") {
        // Never allocated to the user — fail_esim_order_claim flips to
        // 'failed' AND refunds in one transaction, so the client's
        // "+N credits refunded" line on the failed card is TRUE.
        const { data: didClose } = await sb.rpc("fail_esim_order_claim", { p_order: order.id });
        if (didClose) {
          const { data: closed } = await sb
            .from("esim_orders").select("*").eq("id", order.id).single();
          await pageProviderClosed(sb, order.id, es, "auto-refunded (was provisioning)");
          return json({ order: closed ?? order });
        }
      }
      if (activatedNow) {
        // The plan was in use and the provider ended it — 'expired' is the
        // honest label ("validity period has ended") and claims no refund.
        status = "expired";
      }
      // Never-activated but past provisioning ('installed'): DO NOT write
      // 'failed' — the shipped client renders failed as "+N credits refunded"
      // and no refund has happened. Keep the status and page; a human decides
      // (the page carries the recipe). Volume here is ~zero: it means the
      // provider revoked an uninstalled, paid profile.
    }
    else if (activatedNow) status = "active";
    else if (status === "provisioning" && p.ac) status = "installed";
    // GOT_RESOURCE without an ac yet, SUSPENDED, or anything unrecognised:
    // keep the current status — fail-safe, the client keeps polling. Their
    // vocabulary is bigger than our enum and the enum CANNOT grow (the Swift
    // decoder has no unknown case; a new value blanks My eSIMs silently).
  }

  const patch: Record<string, unknown> = {
    status,
    activated: activatedNow,
    updated_at: new Date().toISOString(),
  };
  if (activatedNow && !order.activated_at) {
    patch.activated_at = p.activateTime ?? new Date().toISOString();
  }

  // The provider's expiredTime is AUTHORITATIVE — it reflects the real
  // activation clock and moves on top-ups, so overwrite whenever present on a
  // non-terminal row. This is also what makes new orders sweepable by
  // expire_esim_orders(), which only touches rows with expires_at set (10 of
  // 11 legacy rows have it NULL and can never be swept). The computed
  // validity_days fallback survives only for a profile with no expiredTime.
  if (p.expiredTime && !TERMINAL.has(order.status as string)) {
    const t = Date.parse(p.expiredTime);
    if (Number.isFinite(t)) patch.expires_at = new Date(t).toISOString();
  } else if (activatedNow && !order.expires_at) {
    const { data: plan } = await sb
      .from("esim_plans").select("validity_days")
      .eq("id", order.plan_id).maybeSingle();
    if (plan?.validity_days) {
      patch.expires_at = new Date(
        Date.now() + (plan.validity_days as number) * 86_400_000,
      ).toISOString();
    }
  }

  // Usage is ALWAYS written when reported, INCLUDING 0 — the shipped client's
  // `dataUsedMb ?? 0` renders an unwritten column as zero usage anyway, so a
  // written 0 is at least an honest reading. Totals use the shared hybrid
  // conversion; usage is a plain MiB gauge numerator. The provider updates
  // usage every 2-3h and their own docs show it exceeding the total — the
  // client clamps.
  if (p.totalVolume != null) patch.data_total_mb = dataMbFromBytes(p.totalVolume);
  if (p.orderUsage != null) patch.data_used_mb = Math.round(p.orderUsage / 1048576);

  // First sight of the allocated profile: fill the delivery fields. ea_tran_no
  // is captured unconditionally-if-missing — it is the STABLE provider key
  // (ICCIDs are reused) and every later query prefers it.
  if (!order.ea_tran_no && p.esimTranNo) patch.ea_tran_no = p.esimTranNo;
  if (!order.iccid && p.iccid) patch.iccid = p.iccid;
  if (!order.activation_code && p.ac) {
    const lpa = parseLpa(p.ac);
    patch.activation_code = p.ac;
    patch.smdp_address = lpa.smdp;
    patch.matching_id = lpa.matchingId;
  }
  if (!order.apn && p.apn) patch.apn = p.apn;
  if (!order.sim_pin && p.pin) patch.sim_pin = p.pin;
  if (!order.sim_puk && p.puk) patch.sim_puk = p.puk;

  // Same atomic claim as the legacy branch — the */15 expiry sweep may have
  // written a terminal state between our read and this write, and its verdict
  // is newer than ours.
  const { data: updated } = await sb
    .from("esim_orders").update(patch)
    .eq("id", order.id).eq("status", order.status)
    .select("*").maybeSingle();

  if (providerClosed) {
    await pageProviderClosed(
      sb, order.id as string, es,
      status === "expired"
        ? "was active → marked expired (no refund claimed)"
        : "UNRESOLVED — decide by hand: update esim_orders set status='refunded' where id=… ; select wallet_move_esim(user, cost_credits, 'refund', order)",
    );
  }

  return json({ order: updated ?? order });
}

/** Provider-side CANCEL/REVOKE deserves eyes every time — but once per order,
 *  not once per 8-second poll. telegram_events (kind, ref) is the same
 *  exactly-once claim alertEsim uses. */
async function pageProviderClosed(
  sb: ReturnType<typeof admin>, orderId: string, providerStatus: string, action: string,
): Promise<void> {
  try {
    const { data: claimed } = await sb
      .from("telegram_events")
      .insert({ kind: "esim", ref: `revoke:${orderId}` })
      .select("ref").maybeSingle();
    if (!claimed) return;
    await notifySafe(
      `🚨 <b>Provider closed an eSIM</b> (${esc(providerStatus)})\n` +
      `order <b>${esc(orderId)}</b>\n${esc(action)}`,
    );
  } catch (e) {
    console.error("pageProviderClosed failed (ignored):", e);
  }
}
