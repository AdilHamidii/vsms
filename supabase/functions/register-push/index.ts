import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";

interface Body {
  token: string;
  environment: "sandbox" | "production";
  bundle_id: string;
}

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, { status: 405 });

  const userId = await callerUserId(req);
  if (!userId) return json({ error: "unauthorized" }, { status: 401 });

  let body: Body;
  try { body = await req.json(); }
  catch { return json({ error: "invalid_body" }, { status: 400 }); }
  if (!body.token || !body.environment || !body.bundle_id) {
    return json({ error: "missing_fields" }, { status: 400 });
  }
  if (body.environment !== "sandbox" && body.environment !== "production") {
    return json({ error: "invalid_environment" }, { status: 400 });
  }

  const sb = admin();
  const { error } = await sb
    .from("push_devices")
    .upsert({
      user_id: userId,
      token: body.token,
      environment: body.environment,
      bundle_id: body.bundle_id,
      updated_at: new Date().toISOString(),
    }, { onConflict: "user_id,token" });

  if (error) {
    console.error(`register-push FAILED user=${userId} env=${body.environment} bundle=${body.bundle_id}: ${error.message}`);
    return json({ error: "persist_failed", detail: error.message }, { status: 500 });
  }
  // Logged so we can tell from function logs whether the app is even calling
  // this (empty push_devices ⇒ registration path never reached) vs. failing.
  console.log(`register-push OK user=${userId} env=${body.environment} bundle=${body.bundle_id} token=${body.token.slice(0, 8)}…`);

  // The daily credit was disabled (20260801150000) and then REMOVED
  // (2026-08-02): the claim_daily_credit_for round-trip that used to live here
  // was a guaranteed no-op costing every cold launch an RPC. The literal
  // `daily_credits: null` stays in the response because shipped builds decode
  // this shape, and null is exactly what they have received since the disable.
  return json({ ok: true, daily_credits: null });
});
