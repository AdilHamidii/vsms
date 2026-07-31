// Apple Guideline 5.1.1(v): apps that create accounts must offer in-app
// deletion. We delete the auth.users row; CASCADE constraints clean up
// profiles, wallets, wallet_transactions, orders, push_devices, iap_receipts.

import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import { markDead, release, type OrderProvider } from "../_shared/providers.ts";

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

  const { error } = await sb.auth.admin.deleteUser(userId);
  if (error) {
    return json({ error: "delete_failed", detail: error.message }, { status: 500 });
  }

  return json({ ok: true });
});
