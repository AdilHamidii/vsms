// Attaches a referrer to the caller by invite code. The actual set-once /
// no-self-referral / code-lookup logic lives in the redeem_referral SECURITY
// DEFINER function; this just authenticates the caller and maps the status.

import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";

interface Body { code: string; }

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, { status: 405 });

  const userId = await callerUserId(req);
  if (!userId) return json({ error: "unauthorized" }, { status: 401 });

  let body: Body;
  try { body = await req.json(); }
  catch { return json({ error: "invalid_body" }, { status: 400 }); }
  if (!body.code) return json({ error: "missing_code" }, { status: 400 });

  const { data: status, error } = await admin()
    .rpc("redeem_referral", { p_referee: userId, p_code: body.code });
  if (error) return json({ error: "redeem_failed", detail: error.message }, { status: 500 });

  // Always 200 with a status the client maps to a message:
  // ok | already_referred | invalid_code | self
  return json({ ok: status === "ok", status });
});
