// goodwill-credit — grant a named user free credits and tell them by push.
//
// Built 2026-08-02 for the first real make-good: a buyer hit the premium-gate
// and phantom-price bugs, paid $5.99, placed 15 orders and got zero codes.
// There was no mechanism to say sorry with credits — the winback cohorts are
// automatic and the daily credit is disabled — so this is the manual one.
//
// Cron-gated like every ops function: trigger it via net.http_post with
// private_cron_secret(), so the secret never leaves the database:
//
//   select net.http_post(
//     url := 'https://enugzltysdmjzavisloy.supabase.co/functions/v1/goodwill-credit',
//     headers := jsonb_build_object('Content-Type','application/json',
//                                   'x-cron-secret', private_cron_secret()),
//     body := jsonb_build_object(
//       'user_id','<uuid>','credits',10,
//       'title','A gift from us','body','We added 10 free credits.'),
//     timeout_milliseconds := 30000);
//
// MUST be deployed --no-verify-jwt (no Authorization header on the relay);
// fails closed without the secret. Not in either standing deploy list yet —
// same situation as telegram-setup, and documented next to it in CLAUDE.md.
//
// NO tombstone, deliberately: the account-deletion-farming rule covers grants
// a USER can trigger (signup, referral, IAP, daily). This one only the owner
// can fire, so deleting the account cannot re-mint it.
//
// The ledger reason is 'adjustment' — the same reason manual balance moves
// already use — so /revenue and the digest keep ignoring it correctly.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import { sendPush } from "../_shared/apns.ts";

/** A typo must not mint a fortune: one grant is capped at the smallest credit
 *  pack's size. Raise knowingly if a bigger make-good is ever warranted. */
const MAX_GRANT = 30;

Deno.serve(async (req) => {
  const pre = handleCors(req);
  if (pre) return pre;

  const secret = Deno.env.get("CRON_SECRET");
  if (!secret || req.headers.get("x-cron-secret") !== secret) {
    return json({ error: "forbidden" }, { status: 403 });
  }

  let body: { user_id?: string; credits?: number; title?: string; body?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad_json" }, { status: 400 });
  }

  const userId = body.user_id ?? "";
  const credits = body.credits ?? 0;
  if (!/^[0-9a-f-]{36}$/.test(userId)) return json({ error: "bad_user" }, { status: 400 });
  if (!Number.isInteger(credits) || credits < 1 || credits > MAX_GRANT) {
    return json({ error: "bad_amount", max: MAX_GRANT }, { status: 400 });
  }

  const sb = admin();

  // Money rule: supabase-js RETURNS errors, it does not throw. wallet_credit
  // raises on a missing wallet row, and a discarded error here would push
  // "we added credits" for credits that never landed.
  const { error: creditErr } = await sb.rpc("wallet_credit", {
    p_user: userId,
    p_amount: credits,
    p_reason: "adjustment",
    p_order: null,
    p_receipt: null,
  });
  if (creditErr) {
    console.error(`goodwill-credit: GRANT FAILED user=${userId} credits=${credits}: ${creditErr.message}`);
    return json({ error: "grant_failed", detail: creditErr.message }, { status: 500 });
  }

  // Push AFTER the grant committed, so the message can never outrun the money.
  // customData carries NO orderId — PushManager deep-links on that key and
  // there is no order here. A push failure does not undo the grant: the
  // balance is visible in-app regardless, and the response reports it.
  const { data: devices } = await sb
    .from("push_devices")
    .select("token, environment")
    .eq("user_id", userId);

  let pushed = 0, pushFailed = 0;
  for (const d of devices ?? []) {
    try {
      const r = await sendPush(d.token, {
        alertTitle: body.title ?? "A gift from us",
        alertBody: body.body ?? `We added ${credits} free credits to your account.`,
        customData: { goodwill: true },
      }, d.environment as "sandbox" | "production");
      if (r.ok) pushed++;
      else { pushFailed++; console.error("goodwill-credit APNs", r.status, r.body); }
    } catch (e) {
      pushFailed++;
      console.error("goodwill-credit APNs threw:", e);
    }
  }

  console.log(`goodwill-credit: user=${userId} credits=${credits} pushed=${pushed}/${(devices ?? []).length}`);
  return json({ granted: credits, pushed, push_failed: pushFailed, devices: (devices ?? []).length });
});
