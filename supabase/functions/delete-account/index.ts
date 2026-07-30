// Apple Guideline 5.1.1(v): apps that create accounts must offer in-app
// deletion. We delete the auth.users row; CASCADE constraints clean up
// profiles, wallets, wallet_transactions, orders, push_devices, iap_receipts.

import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import { release, type OrderProvider } from "../_shared/providers.ts";

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, { status: 405 });

  const userId = await callerUserId(req);
  if (!userId) return json({ error: "unauthorized" }, { status: 401 });

  const sb = admin();

  // Best-effort release any waiting orders at their owning provider before
  // tearing down the account, so we don't leak provider reservations (which
  // also count against virtualsms's concurrent-order cap).
  const { data: pending } = await sb
    .from("orders")
    .select("provider, smspva_id")
    .eq("user_id", userId)
    .eq("status", "waiting");

  for (const o of pending ?? []) {
    if (o.smspva_id) await release((o.provider ?? "smspva") as OrderProvider, o.smspva_id);
  }

  const { error } = await sb.auth.admin.deleteUser(userId);
  if (error) {
    return json({ error: "delete_failed", detail: error.message }, { status: 500 });
  }

  return json({ ok: true });
});
