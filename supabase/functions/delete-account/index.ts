// Apple Guideline 5.1.1(v): apps that create accounts must offer in-app
// deletion. We delete the auth.users row; CASCADE constraints clean up
// profiles, wallets, wallet_transactions, orders, push_devices, iap_receipts.

import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import { markDead, release, type OrderProvider } from "../_shared/providers.ts";
import {
  deleteTelephonyCredential, faultOf, findNumberId, releaseNumber,
} from "../_shared/telnyx.ts";
import { cancelActivation } from "../_shared/heromail.ts";
import { cancelEsim, queryEsim } from "../_shared/esimaccess.ts";

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, { status: 405 });

  const userId = await callerUserId(req);
  if (!userId) return json({ error: "unauthorized" }, { status: 401 });

  const sb = admin();

  // Best-effort release any order still holding a number at its owning provider
  // before tearing down the account, so we don't leak provider reservations
  // (which also count against the account's concurrent-order cap).
  //
  // 'canceled' is in this list, and that is not belt-and-braces. Since the
  // late-code rescue shipped (2026-07-27), cancel-order deliberately does NOT
  // release the number: it refunds, stamps `late_watch_until`, and hands the
  // number's whole remaining lifecycle to poll-active-orders' sweep, which is
  // now the ONLY thing that ever calls markDead on a cancelled order. That
  // sweep finds its work by querying `orders` — and orders_user_id_fkey is
  // ON DELETE CASCADE from auth.users, so deleteUser below destroys exactly the
  // rows it would have swept. Without this branch the number stays reserved to
  // its natural expiry and the wholesale is forfeited. delete-account was never
  // updated when cancel stopped releasing.
  const { data: pending } = await sb
    .from("orders")
    .select("provider, smspva_id, status, late_watch_until")
    .eq("user_id", userId)
    .in("status", ["waiting", "canceled"]);

  for (const o of pending ?? []) {
    if (!o.smspva_id) continue;
    const p = (o.provider ?? "smspva") as OrderProvider;
    if (o.status === "canceled") {
      // Only rows the sweep was still watching hold a live number; an older
      // cancel has already been reclaimed. markDead, not release — markDead
      // cancels at the provider FIRST (which is what recovers the wholesale)
      // and only then bans the number.
      if (o.late_watch_until) await markDead(p, o.smspva_id);
    } else {
      await release(p, o.smspva_id);
    }
  }

  // ── The RENTED LINE. This is the expensive one. ────────────────────────────
  //
  // `phone_lines.user_id` is ON DELETE CASCADE, and that row holds the ONLY
  // pointers to the Telnyx resources — provider_number_id, the connection, the
  // credential. Deleting the user destroys them, and every reclaim mechanism we
  // have (`reclaim_lapsed_lines()`, `release-lines`) finds its work by querying
  // `phone_lines`. So a deleted account left a live DID billing $1/month
  // forever with nothing in the database able to name it, discoverable only on
  // the Telnyx invoice. Apple MANDATES this delete button, so it is not an edge
  // case — it is the documented path.
  //
  // Released INLINE rather than by handing off to `release-lines`, because the
  // hand-off writes a claim onto the very row that is about to cascade away.
  // Credential first, then the number — the same order `release-lines` uses:
  // revoking the credential is what makes the cut-off real, and a number
  // released while a credential still registers is briefly reachable.
  const { data: lines } = await sb
    .from("phone_lines")
    .select("id, e164, provider_number_id, provider_credential_id, status")
    .eq("user_id", userId)
    .neq("status", "released");

  for (const l of lines ?? []) {
    if (l.provider_credential_id) {
      const c = await deleteTelephonyCredential(l.provider_credential_id as string);
      if (faultOf(c)) {
        console.error(JSON.stringify({
          alert: "delete_account_credential_revoke_failed",
          line: l.id, detail: c.detail,
        }));
      }
    }
    // `provider_number_id` can be null if provisioning died midway; fall back to
    // the E.164 lookup so a half-provisioned line is still reclaimed.
    let numberId = (l.provider_number_id as string | null) ?? null;
    if (!numberId && l.e164) {
      const found = await findNumberId(l.e164 as string);
      if (!faultOf(found)) numberId = found;
    }
    if (!numberId) {
      // NEVER silent: this is a recurring charge we can no longer name.
      console.error(JSON.stringify({
        alert: "delete_account_line_number_unresolved",
        line: l.id, e164: l.e164,
      }));
      continue;
    }
    const r = await releaseNumber(numberId);
    if (faultOf(r)) {
      console.error(JSON.stringify({
        alert: "delete_account_line_release_failed",
        line: l.id, number: numberId, detail: r.detail, type: r.type,
      }));
    }
  }

  // The subscription tombstone must go WITH the number, and only with it.
  //
  // `line_subscriptions` has no FK to auth.users precisely so it SURVIVES this
  // deletion, and `begin_line_rental` / `record_line_subscription` then refuse
  // anyone whose id differs from the bound one. That guard exists to stop a
  // deleted-and-recreated account being handed a SECOND number while the first
  // billed us forever — but a returning user always has a new uuid, so it fired
  // on the legitimate owner and locked them out permanently, with no path
  // anywhere that rebinds `user_id`. The asymmetry was exactly backwards: the
  // tombstone survived and blocked the owner, while the billed resource it was
  // protecting had already cascaded away unreleased.
  //
  // Now that the number above is genuinely released, the row has nothing left
  // to protect: re-renting costs us a fresh $1 DID, which is the honest price
  // of a fresh rental. Dropping it is also what "delete my account" should mean.
  // ⚠️ This is only safe BECAUSE the release ran first — if you ever make the
  // release conditional, this delete has to become conditional with it.
  const { error: subErr } = await sb
    .from("line_subscriptions").delete().eq("user_id", userId);
  if (subErr) {
    console.error(JSON.stringify({
      alert: "delete_account_subscription_tombstone_failed",
      user: userId, detail: subErr.message,
    }));
  }

  // ── In-flight E-MAIL orders. Same cascade, far smaller stake. ──────────────
  // HeroSMS auto-refunds an abandoned mailbox at ~21 minutes, so the cost is
  // cents; we cancel anyway because it returns the mailbox to their pool
  // immediately and leaves no order we can no longer explain. A cancel inside
  // the provider's hard 120s floor returns EARLY_CANCEL_DENIED — expected, not
  // an error worth alerting on.
  const { data: mails } = await sb
    .from("email_orders").select("id, provider_id")
    .eq("user_id", userId).eq("status", "waiting");

  for (const m of mails ?? []) {
    if (!m.provider_id) continue;
    await cancelActivation(m.provider_id as string).catch(() => null);
  }

  // ── In-flight eSIM orders. ────────────────────────────────────────────────
  // An uninstalled eSIM Access profile CAN be cancelled (wholesale comes back
  // to our balance — the provider refuses once installed, which is the safety
  // we want), so try; SMSPool exposes no cancel at all. Either way a row
  // cascading away leaves a plan at the provider we can never look up again,
  // so every one is reported and recoverable by hand instead of vanishing.
  const { data: esims } = await sb
    .from("esim_orders").select("id, provider, smspool_tx, ea_order_no, ea_tran_no")
    .eq("user_id", userId).in("status", ["provisioning", "installed"]);

  for (const e of esims ?? []) {
    if (e.provider === "esimaccess" && (e.ea_tran_no || e.ea_order_no)) {
      try {
        let tranNo = e.ea_tran_no as string | null;
        if (!tranNo && e.ea_order_no) {
          const q = await queryEsim({ orderNo: e.ea_order_no as string });
          tranNo = q.ok ? q.profile?.esimTranNo ?? null : null;
        }
        if (tranNo) {
          const c = await cancelEsim(tranNo);
          console.error(JSON.stringify({
            alert: "delete_account_esim_cancel", order: e.id,
            tranNo, cancelled: c.ok, ...(c.ok ? {} : { detail: c.error }),
          }));
          continue;
        }
      } catch { /* fall through to the abandoned report */ }
    }
    console.error(JSON.stringify({
      alert: "delete_account_esim_abandoned", order: e.id,
      provider: e.provider, tx: e.smspool_tx ?? e.ea_order_no,
    }));
  }

  const { error } = await sb.auth.admin.deleteUser(userId);
  if (error) {
    return json({ error: "delete_failed", detail: error.message }, { status: 500 });
  }

  return json({ ok: true });
});
