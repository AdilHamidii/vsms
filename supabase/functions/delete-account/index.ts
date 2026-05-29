// Apple Guideline 5.1.1(v): apps that create accounts must offer in-app
// deletion. We delete the auth.users row; CASCADE constraints clean up
// profiles, wallets, wallet_transactions, orders, push_devices, iap_receipts.

import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, { status: 405 });

  const userId = await callerUserId(req);
  if (!userId) return json({ error: "unauthorized" }, { status: 401 });

  const sb = admin();

  // Best-effort cancel any waiting orders before tearing down the account,
  // so we don't leak SMSPVA reservations.
  const { data: pending } = await sb
    .from("orders")
    .select("id, smspva_id, service:service_id (smspva_code), country:country_id (smspva_code)")
    .eq("user_id", userId)
    .eq("status", "waiting");

  for (const o of pending ?? []) {
    if (!o.smspva_id) continue;
    try {
      const { denial } = await import("../_shared/smspva.ts");
      const svc = o.service as { smspva_code: string };
      const cty = o.country as { smspva_code: string };
      await denial(cty.smspva_code, svc.smspva_code, o.smspva_id);
    } catch (e) {
      console.error("denial during delete failed:", e);
    }
  }

  const { error } = await sb.auth.admin.deleteUser(userId);
  if (error) {
    return json({ error: "delete_failed", detail: error.message }, { status: 500 });
  }

  return json({ ok: true });
});
