// Refresh a user's eSIM from SMSPool's /esim/profile: activation state, data
// used/total, and (if it was still provisioning) the QR/activation payload.

import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";
import { esimProfile } from "../_shared/smspool.ts";

interface Body { order_id: string; }

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
  const TERMINAL = new Set(["expired", "refunded", "failed", "depleted"]);

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
});
