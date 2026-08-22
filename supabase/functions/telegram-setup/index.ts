// Register the Telegram webhook AND the bot's command menu, and report what
// both looked like before.
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
// The same argument now covers the `/` AUTOCOMPLETE MENU (`setMyCommands`) and
// the ≡ button (`setChatMenuButton`): both are bot-level state held on
// Telegram's servers, invisible from the code, and stale the moment a command
// is added. They are built from ONE registry (`_shared/tgCommands.ts`) that
// also generates /help, so the menu and the help text cannot drift apart.
//
// Cron-gated (x-cron-secret) so it can be triggered from SQL via pg_net without
// the caller ever handling TELEGRAM_BOT_TOKEN — the token is read here, inside
// the platform, and never appears in a response.
//
// Deploy with --no-verify-jwt.

import { json } from "../_shared/cors.ts";
import { botCommands, COMMAND_BY_NAME } from "../_shared/tgCommands.ts";
// The dispatcher lives in _shared precisely so this file can import it:
// importing telegram-webhook/index.ts would execute its top-level Deno.serve
// and start a second server inside this function.
import { runCommand } from "../_shared/tgHandlers.ts";

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

  // ── preview ───────────────────────────────────────────────────────────────
  // `{"preview": "/trials"}` renders a command and returns the HTML WITHOUT
  // sending anything to Telegram and without touching the webhook. It is how a
  // formatter change is verified against live data before it reaches the
  // owner's phone — previously the only way to see a reply was to type the
  // command, i.e. to ship it.
  //
  // It runs behind the same cron secret as the rest of this function, so it is
  // no more reachable than the setup path is — but it is READ-ONLY BY
  // ENFORCEMENT, not by convention. `runCommand` dispatches the mutating
  // handlers too, so without the refusal below `{"preview":"/announce …"}`
  // publishes a banner on Home for every user and `{"preview":"/esim on"}`
  // flips a product kill switch. Those writes used to need the bot token AND
  // the owner chat id; a preview that ran them would make CRON_SECRET alone
  // sufficient, which is a widening of what one leaked secret buys.
  let body: { preview?: unknown } = {};
  try { body = await req.json(); } catch { /* no body: fall through to setup */ }
  if (typeof body?.preview === "string" && body.preview.trim() !== "") {
    const name = body.preview.trim().split(/\s+/)[0]
      .replace(/^\//, "").replace(/@.*$/, "").toLowerCase();
    if (COMMAND_BY_NAME[name]?.mutates) {
      return json({ error: "preview_refused_mutating", command: name }, { status: 400 });
    }
    try {
      return json({ ok: true, preview: await runCommand(body.preview) });
    } catch (e) {
      console.error(`telegram-setup preview failed: ${String(e)}`);
      return json({ error: "preview_failed", detail: String(e) }, { status: 500 });
    }
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

    // ── the `/` menu ──────────────────────────────────────────────────────
    // Default scope: this bot has exactly one user, so a per-chat scope would
    // be extra state to keep in step for no gain. Telegram validates every
    // entry and rejects the WHOLE call on one bad description, so `commands`
    // (the payload actually sent) is echoed back — a rejection here is
    // otherwise indistinguishable from a menu that simply did not refresh.
    const commands = botCommands();
    const setCommands = await tg("setMyCommands", { commands });
    const menuButton = await tg("setChatMenuButton", {
      menu_button: { type: "commands" },
    });
    // READ IT BACK. This repo has paid three times for trusting a 200 from an
    // API that silently ignored the field it was sent (Telnyx twice, a column
    // revoke once). "Did the menu land" must be answerable from this response.
    const myCommands = await tg("getMyCommands");

    // `url` is safe to echo (it is our own public function). The token is not,
    // and is never included.
    return json({ ok: true, webhook_url: url, allowed_updates: ALLOWED_UPDATES,
                  before, set, after,
                  commands_sent: commands.length, commands,
                  set_commands: setCommands, menu_button: menuButton,
                  get_my_commands: myCommands });
  } catch (e) {
    console.error(`telegram-setup failed: ${String(e)}`);
    return json({ error: "setup_failed", detail: String(e) }, { status: 500 });
  }
});
