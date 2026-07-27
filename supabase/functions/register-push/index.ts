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

  // Grant the daily credit here, because opening the app IS the trigger.
  //
  // The design wanted "collect your credit" to be an explicit tap, but that
  // button only exists in an unreleased build — so the daily push has gone out
  // 95-104 times a day to zero claims, and repeats forever because its dedupe
  // (`last_daily_credit_on = today`) is something the shipped app can never
  // set. AuthGate calls this endpoint on every signed-in cold launch, so
  // granting here preserves the intent exactly — pay people who came back, not
  // people who didn't — and works on 1.4 today.
  //
  // Idempotent per UTC day and advisory-locked per user inside the function, so
  // several launches in a day grant once. Best-effort: a failure here must
  // never fail the push registration itself.
  let dailyGranted: number | null = null;
  try {
    const { data: claim, error: claimErr } = await sb.rpc("claim_daily_credit_for", { p_user: userId });
    if (claimErr) console.error(`register-push: daily credit failed user=${userId}: ${claimErr.message}`);
    else if ((claim as { granted?: boolean; credits?: number } | null)?.granted) {
      dailyGranted = (claim as { credits?: number }).credits ?? null;
      console.log(`register-push: granted ${dailyGranted} daily credit(s) to ${userId}`);
    }
  } catch (e) {
    console.error("register-push: daily credit threw (ignored):", e);
  }

  return json({ ok: true, daily_credits: dailyGranted });
});
