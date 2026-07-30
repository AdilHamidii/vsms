// Re-register the Telegram webhook, and report what it looked like before.
//
// WHY THIS EXISTS: `setWebhook` was registered by hand, and Telegram only
// delivers the update types named in `allowed_updates`. The support chat's
// [✅ Accept] button sends a `callback_query`, so a webhook registered with
// `allowed_updates: ["message"]` drops every button press silently — the bot
// answers nothing, no error appears anywhere, and the thread stays `open`
// forever. That is exactly what happened: a live thread sat at status `open`
// with the owner tapping Accept and nothing happening.
//
// Registration therefore belongs in the repo, not in someone's shell history.
//
// Cron-gated (x-cron-secret) so it can be triggered from SQL via pg_net without
// the caller ever handling TELEGRAM_BOT_TOKEN — the token is read here, inside
// the platform, and never appears in a response.
//
// Deploy with --no-verify-jwt.

import { json } from "../_shared/cors.ts";

/** Every update type this bot actually uses.
 *
 *  `message` carries commands and the owner's replies; `callback_query` carries
 *  the inline [Accept] button. Naming them explicitly is deliberate: relying on
 *  Telegram's default set means a future default change can silently disable a
 *  feature, and that is the failure mode this file was written to fix. */
const ALLOWED_UPDATES = ["message", "callback_query"];

function token(): string {
  const t = Deno.env.get("TELEGRAM_BOT_TOKEN");
  if (!t) throw new Error("TELEGRAM_BOT_TOKEN not set");
  return t;
}

async function tg(method: string, body?: unknown): Promise<unknown> {
  const res = await fetch(`https://api.telegram.org/bot${token()}/${method}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body ?? {}),
  });
  return await res.json();
}

Deno.serve(async (req) => {
  const secret = Deno.env.get("CRON_SECRET");
  if (!secret || req.headers.get("x-cron-secret") !== secret) {
    return json({ error: "unauthorized" }, { status: 401 });
  }

  const projectUrl = Deno.env.get("SUPABASE_URL");
  const hookSecret = Deno.env.get("TELEGRAM_WEBHOOK_SECRET");
  if (!projectUrl || !hookSecret) {
    return json({ error: "missing_config",
                  has_url: !!projectUrl, has_webhook_secret: !!hookSecret }, { status: 500 });
  }
  const url = `${projectUrl}/functions/v1/telegram-webhook`;

  try {
    // Report the CURRENT registration first. Without a before/after the fix is
    // unfalsifiable — you cannot tell a webhook that was already correct from
    // one this call just repaired.
    const before = await tg("getWebhookInfo");

    const set = await tg("setWebhook", {
      url,
      secret_token: hookSecret,
      allowed_updates: ALLOWED_UPDATES,
      // Old queued updates were produced under the previous configuration and
      // replaying them helps nobody.
      drop_pending_updates: true,
    });

    const after = await tg("getWebhookInfo");

    // `url` is safe to echo (it is our own public function). The token is not,
    // and is never included.
    return json({ ok: true, webhook_url: url, allowed_updates: ALLOWED_UPDATES,
                  before, set, after });
  } catch (e) {
    console.error(`telegram-setup failed: ${String(e)}`);
    return json({ error: "setup_failed", detail: String(e) }, { status: 500 });
  }
});
