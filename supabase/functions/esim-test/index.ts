// TEMPORARY operator-only validation probe — delete after use.
// Exercises the real SMSPool eSIM path with the server-held key:
// /esim/purchase → /esim/profile, so we can confirm QR delivery works
// end-to-end before promoting the eSIM tab. CRON_SECRET-gated.

import { handleCors, json } from "../_shared/cors.ts";
import { esimPurchase, esimProfile } from "../_shared/smspool.ts";

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;
  const header = req.headers.get("x-cron-secret");
  const expected = Deno.env.get("CRON_SECRET");
  if (!header || !expected || header !== expected) {
    return json({ error: "unauthorized" }, { status: 401 });
  }

  const { plan, transactionId } = await req.json().catch(() => ({}));

  // Re-check an existing purchase without buying again.
  if (transactionId) {
    return json({ profile: await esimProfile(String(transactionId)) });
  }
  if (!plan) return json({ error: "missing_plan" }, { status: 400 });

  const bought = await esimPurchase(plan);
  if (!bought.ok) return json({ purchase: bought }, { status: 502 });

  // Profile can lag a few seconds behind purchase.
  let profile = await esimProfile(bought.transactionId!);
  for (let i = 0; i < 5 && (!profile.ok || !profile.activationCode); i++) {
    await new Promise((r) => setTimeout(r, 3000));
    profile = await esimProfile(bought.transactionId!);
  }
  return json({ purchase: bought, profile });
});
