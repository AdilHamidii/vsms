// Public endpoint that Telegram POSTs updates to, so the operator can query the
// business on demand (/stats, /today, /balance).
//
// THREAT MODEL: this URL is guessable and, unlike every other function here, it
// is not behind a JWT or the cron secret — Telegram's servers must be able to
// reach it. Two independent checks, both required:
//
//   1. X-Telegram-Bot-Api-Secret-Token must equal TELEGRAM_WEBHOOK_SECRET.
//      Telegram echoes back the secret_token given to setWebhook, so a caller
//      who doesn't know it cannot impersonate Telegram.
//   2. message.chat.id must equal TELEGRAM_CHAT_ID. Even if the secret leaked,
//      a stranger messaging the bot gets nothing.
//
// Every rejection returns a silent 200 with no reply. A 401 would confirm the
// endpoint exists and that a guessed secret was wrong; 200 tells an attacker
// nothing and also stops Telegram retrying.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
// esc and balanceLine are used by /balance below. They were referenced without
// being imported for a while — esbuild bundles free identifiers without
// complaint, so /balance THREW ReferenceError on every call in production
// while every other command worked. Keep imports in lockstep with usage.
import {
  sendMessage, ownerChatId, esc, sendMessageWithId, answerCallback,
} from "../_shared/telegram.ts";
import {
  formatDigest, formatRevenue, formatGross, formatLinesMoney, balanceLine,
  formatOrders,
  formatFunnel, formatDelivery, formatSubs,
} from "../_shared/opsFormat.ts";
// Support replies push to the user's device. Imported explicitly for the reason
// in the note above — a free identifier here bundles fine and throws at runtime.
import { sendPush } from "../_shared/apns.ts";

const HELP = [
  "🤖 <b>vSMS ops</b> — /help",
  "",
  "<b>Activity</b>",
  "/stats — last 6 hours",
  "/today — last 24 hours",
  "/week — last 7 days",
  "/funnel — signup → order → code → purchase, per day",
  "     <i>[7d|14d|30d]</i> · default: 7d",
  "/orders — every order, one line each, with its route",
  "     <i>[24h|7d|30d|90d|all]</i> · default: 24h",
  "",
  "<b>Health</b>",
  "/delivery — per-provider delivery, cancels and refusals",
  "     <i>[24h|7d|30d]</i> · default: 7d",
  "/balance — provider balances + watchdog",
  "",
  "<b>Money</b>",
  "/revenue — money customers actually paid (USD)",
  "/profit — revenue minus Apple's cut and wholesale",
  "     <i>[24h|7d|30d|90d|all]</i> · default: all",
  "/subs — second-number subscriptions, lines and MRR",
  "",
  "<b>Controls</b>",
  "/announce <i>message</i> — banner on Home for everyone",
  "     <code>/announce warn …</code> amber · <code>/announce off</code> clears",
  "     <code>/announce</code> alone shows what is live",
  "/esim <i>on|off</i> — put eSIMs on or off sale",
  "/lines <i>on|off</i> — put second numbers on or off sale",
  "",
  "<i>Every delivery rate here excludes user cancels and the app's own " +
    "pre-selection. Purchases are Production receipts only.</i>",
].join("\n");

/** Announcement ceiling. The banner is two or three lines on a phone; anything
 *  longer is silently truncated by the layout, which would let the owner send a
 *  message whose end nobody ever reads. Refuse instead of truncating. */
const MAX_ANNOUNCE = 280;

/** Accepted /revenue periods -> the interval passed to revenue_snapshot.
 *  null means lifetime (the function reads p_window null as no lower bound).
 *
 *  Membership is tested with Object.hasOwn, NOT `in` and NOT truthiness:
 *  truthiness would reject "all" (a legitimate key whose value is null), while
 *  `in` walks the prototype chain — so `/revenue constructor` would pass the
 *  guard and hand Object's constructor to the RPC as p_window. */
const PERIODS: Record<string, string | null> = {
  "": null, "all": null, "lifetime": null, "total": null, "ever": null,
  "24h": "24 hours", "today": "24 hours", "day": "24 hours",
  "7d": "7 days", "week": "7 days",
  "30d": "30 days", "month": "30 days",
  "90d": "90 days", "quarter": "90 days",
};

/** `/funnel` accepts only DAY windows, because it prints one row per day: a
 *  "24h" funnel would be a single line and "all" would be a wall of them. */
const FUNNEL_PERIODS: Record<string, string> = {
  "": "7 days", "7d": "7 days", "week": "7 days",
  "14d": "14 days", "2w": "14 days",
  "30d": "30 days", "month": "30 days",
};

/** `/delivery` windows. 24h is offered because a provider outage has to be
 *  visible the same day; 30d is the longest window over which a rate here is
 *  still about the provider currently serving the route (providers have changed
 *  four times, and evidence does not carry across a switch). */
const DELIVERY_PERIODS: Record<string, string> = {
  "": "7 days", "24h": "24 hours", "today": "24 hours", "day": "24 hours",
  "7d": "7 days", "week": "7 days",
  "30d": "30 days", "month": "30 days",
};

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;

  // Silent 200 on every rejection — see threat model above.
  const ok = () => json({ ok: true });

  const secret = Deno.env.get("TELEGRAM_WEBHOOK_SECRET");
  if (!secret || req.headers.get("x-telegram-bot-api-secret-token") !== secret) {
    return ok();
  }

  let update: {
    message?: {
      chat?: { id?: number | string };
      text?: string;
      reply_to_message?: { message_id?: number };
    };
    callback_query?: {
      id?: string;
      data?: string;
      message?: { chat?: { id?: number | string } };
    };
  };
  try { update = await req.json(); } catch { return ok(); }

  // ── Support chat ─────────────────────────────────────────────────────────
  // Two new update kinds, BOTH gated on the owner chat id exactly like
  // commands. A callback_query carries its chat under
  // `callback_query.message.chat.id`, NOT `message.chat.id` — reusing the old
  // path would have left the Accept button ungated.
  const cbChat = update.callback_query?.message?.chat?.id;
  if (update.callback_query && cbChat != null && String(cbChat) === ownerChatId()) {
    return await handleCallback(update.callback_query);
  }

  const chatId = update.message?.chat?.id;
  if (chatId == null || String(chatId) !== ownerChatId()) return ok();

  // A reply to a relayed support message is an ANSWER, not a command. Checked
  // before command parsing so an agent whose reply happens to start with "/"
  // still reaches the user instead of being swallowed as an unknown command.
  const replyTo = update.message?.reply_to_message?.message_id;
  if (replyTo != null && (update.message?.text ?? "").trim() !== "") {
    const handled = await handleAgentReply(replyTo, update.message!.text!.trim());
    if (handled) return ok();
    // Not a support reply — fall through and treat it as a normal command.
  }

  // Plain text, no leading "/", while a conversation is assigned → it is an
  // ANSWER to that conversation, not a mistyped command.
  //
  // Without this, accepting a chat and then simply typing a reply — the obvious
  // thing to do, and what "I get to be the support to that user" means — got
  // swallowed by the command parser and answered with the help text. The user
  // waiting on the other end saw nothing at all.
  //
  // Replies still take precedence above, and remain the way to target a
  // specific conversation when several are open; this only covers the case
  // where the owner is plainly talking to the one they just accepted.
  const raw = (update.message?.text ?? "").trim();
  if (raw !== "" && !raw.startsWith("/") && update.message?.reply_to_message == null) {
    const routed = await routeToAssignedThread(raw);
    if (routed) return ok();
  }

  const text = raw.toLowerCase();
  const parts = text.split(/\s+/);
  const cmd = parts[0].replace(/@.*$/, "");               // strip @botname suffix
  const arg = (parts[1] ?? "").replace(/^[-/]+/, "");     // tolerate "-7d" / "/7d"

  const sb = admin();

  // The FALLBACK is a pointer, not the whole help text. Answering a typo with
  // 30 lines buries the typo, and answering plain prose with a command list
  // does not explain why the message went nowhere — which, for the owner
  // half-way through a support conversation, is the thing they need to know.
  let reply: string;
  if (cmd === "" || cmd === "/help" || cmd === "/start") {
    reply = HELP;
  } else if (!cmd.startsWith("/")) {
    reply = "❓ Not a command — and no support conversation is assigned, so " +
            "this went nowhere.\n\nPress [✅ Accept] on a thread first, or " +
            "reply directly to a relayed message.\n\n/help for the commands.";
  } else {
    reply = `❓ Unknown command <b>${esc(cmd)}</b>.\n\nTry /help`;
  }

  if (cmd === "/revenue" || cmd === "/profit") {
    if (!Object.hasOwn(PERIODS, arg)) {
      reply = `Unknown period <b>${esc(arg)}</b>.\n\n` +
              `Try: <code>/revenue</code> (all time), or ` +
              `<code>24h</code> · <code>7d</code> · <code>30d</code> · <code>90d</code>`;
    } else {
      // p_window is an interval; null = lifetime. supabase-js sends JSON null,
      // which Postgres binds as SQL NULL, so the DEFAULT is never applied — the
      // function must (and does) treat an explicit null as "no lower bound"
      // rather than relying on its own default value.
      const { data: snap, error } = await sb.rpc("revenue_snapshot", {
        p_window: PERIODS[arg],
      });
      // /revenue answers "how much did customers pay", full stop — no Apple
      // cut, no wholesale, no profit. /profit is where the derived P&L lives.
      // They used to be aliases for the same P&L, which meant there was no way
      // to ask the bot for plain takings.
      const fmt = cmd === "/revenue" ? formatGross : formatRevenue;
      reply = error || !snap
        ? "⚠️ Couldn't read revenue right now."
        : fmt(snap as Record<string, unknown>);
      if (error) console.error("revenue_snapshot failed:", error.message);

      // 🔴 SUBSCRIPTIONS ARE INVISIBLE TO `revenue_snapshot`. It reads
      // `iap_receipts`, and a line purchase is written to `line_subscriptions`
      // instead — so the only product that bills monthly reported exactly $0
      // here. Appended as its own block rather than merged into the totals:
      // "collected" and "recurring" answer different questions, and on this
      // product they differ enormously (every subscriber so far cancelled
      // auto-renew within 16 minutes of paying).
      if (!error && snap) {
        const { data: lm, error: lmErr } = await sb.rpc("lines_money_snapshot", {
          p_window: PERIODS[arg],
        });
        // Destructured, and a failure SAYS SO rather than silently omitting the
        // block — an absent section reads as "no subscriptions", which is the
        // same confidently-wrong shape this command set is being cleaned up to
        // remove.
        if (lmErr) {
          console.error("lines_money_snapshot failed:", lmErr.message);
          reply += "\n\n📞 <b>Second numbers</b>\n⚠️ Couldn't read this — figure above EXCLUDES subscriptions.";
        } else if (lm) {
          reply += formatLinesMoney(lm as Record<string, unknown>);
        }
      }
    }
  } else if (cmd === "/orders") {
    // Same period vocabulary as /revenue, with two deliberate differences:
    //
    //  * the DEFAULT is 24h, not lifetime. This prints one line per order, so
    //    defaulting to "all" would dump the entire history into a chat message.
    //  * a null period (all/lifetime) becomes a very long finite interval,
    //    because orders_recent does `now() - p_window` and a NULL there yields
    //    NULL, which would silently match no rows and read as "no orders".
    //
    // Object.hasOwn, not `in` and not truthiness — same reasoning as PERIODS.
    if (arg !== "" && !Object.hasOwn(PERIODS, arg)) {
      reply = `Unknown period <b>${esc(arg)}</b>.\n\n` +
              `Try: <code>/orders</code> (24h), or ` +
              `<code>7d</code> · <code>30d</code> · <code>90d</code> · <code>all</code>`;
    } else {
      const window = arg === "" ? "24 hours" : (PERIODS[arg] ?? "3650 days");
      const { data: snap, error } = await sb.rpc("orders_recent", { p_window: window });
      reply = error || !snap
        ? "⚠️ Couldn't read orders right now."
        : formatOrders(snap as Record<string, unknown>, arg === "" ? "24h" : (arg || "all"));
      if (error) console.error("orders_recent failed:", error.message);
    }
  } else if (cmd === "/stats" || cmd === "/today" || cmd === "/week") {
    const window = cmd === "/stats" ? "6 hours" : cmd === "/today" ? "24 hours" : "7 days";
    const { data: snap, error } = await sb.rpc("ops_snapshot", { p_window: window });
    reply = error || !snap
      ? "⚠️ Couldn't read stats right now."
      : formatDigest(snap as Record<string, unknown>);
  } else if (cmd === "/funnel") {
    // Object.hasOwn, not `in` and not truthiness — same reasoning as PERIODS:
    // `in` walks the prototype chain, so `/funnel constructor` would hand
    // Object's constructor to the RPC as an interval.
    if (!Object.hasOwn(FUNNEL_PERIODS, arg)) {
      reply = `Unknown period <b>${esc(arg)}</b>.\n\n` +
              `Try: <code>/funnel</code> (7d), or ` +
              `<code>14d</code> · <code>30d</code>`;
    } else {
      const { data: snap, error } = await sb.rpc("ops_funnel", {
        p_window: FUNNEL_PERIODS[arg],
      });
      reply = error || !snap
        ? "⚠️ Couldn't read the funnel right now."
        : formatFunnel(snap as Record<string, unknown>);
      if (error) console.error("ops_funnel failed:", error.message);
    }
  } else if (cmd === "/delivery") {
    if (!Object.hasOwn(DELIVERY_PERIODS, arg)) {
      reply = `Unknown period <b>${esc(arg)}</b>.\n\n` +
              `Try: <code>/delivery</code> (7d), or ` +
              `<code>24h</code> · <code>30d</code>`;
    } else {
      const window = DELIVERY_PERIODS[arg];
      const { data: snap, error } = await sb.rpc("ops_delivery", { p_window: window });
      reply = error || !snap
        ? "⚠️ Couldn't read delivery right now."
        : formatDelivery(snap as Record<string, unknown>, arg === "" ? "7d" : arg);
      if (error) console.error("ops_delivery failed:", error.message);
    }
  } else if (cmd === "/subs") {
    // No period: subscription and line STATE is a right-now question, and the
    // notification block inside carries its own fixed 7-day window.
    const { data: snap, error } = await sb.rpc("ops_subs");
    reply = error || !snap
      ? "⚠️ Couldn't read subscriptions right now."
      : formatSubs(snap as Record<string, unknown>);
    if (error) console.error("ops_subs failed:", error.message);
  } else if (cmd === "/balance") {
    // BOTH providers. Reporting only SMSPool here survived the 2026-07-20
    // migration and became actively misleading: it alarmed about the provider
    // that now only funds eSIMs, while the balance gating every SMS order
    // (SMSPVA) was not shown at all.
    const { data: rows } = await sb
      .from("app_config").select("key, value")
      .in("key", ["5sim_health", "herosms_health", "esimaccess_health",
                  // 🔴 TELNYX WAS MISSING, and it is the float for the product
                  // that costs money PER SUBSCRIBER PER MONTH. `/balance` is
                  // the is-everything-alive reflex, and the one balance that
                  // can strand a paying subscriber's number was not on it —
                  // even though `ROLE` already had a label ready for it.
                  "telnyx_health"]);

    const read = (k: string) => {
      const v = (rows ?? []).find((r) => r.key === k)?.value as
        { balance_usd?: number; checked_at?: string } | null | undefined;
      return v ?? null;
    };
    // Null out a stale reading instead of printing it as current.
    // ops_snapshot was fixed for exactly this in 20260722050000 — "a dead poller
    // produced confidently WRONG 'all is well' digests" — but /balance was not,
    // and it is the owner's is-everything-alive reflex. A bold "$3.55" with a
    // small timestamp underneath is read as now.
    const FRESH_MS = 10 * 60 * 1000;
    const fresh = (v: { checked_at?: string } | null) =>
      !!v?.checked_at && Date.now() - new Date(v.checked_at).getTime() <= FRESH_MS;
    // Only balances that fund something: 5sim buys every SMS, HeroSMS funds
    // the temp-EMAIL line, eSIM Access funds the eSIM line (added 2026-08-10 —
    // while the line is paused this reading is how the owner watches the $50
    // deposit land, which is exactly when it must be visible). SMSPVA serves
    // nothing now, so printing it was noise on the one channel that has to
    // stay readable at a glance.
    const fiveRaw = read("5sim_health");
    const heroRaw = read("herosms_health");
    const eaRaw = read("esimaccess_health");
    // Telnyx funds the SECOND-NUMBER line: $1 up front plus $1/month per
    // subscriber, carried ~45 days ahead of Apple's payout. It was absent here
    // while being the only float that can strand a PAYING subscriber's number,
    // and `ROLE` already had a label waiting for it.
    const tnxRaw = read("telnyx_health");
    const five = fresh(fiveRaw) ? fiveRaw : null;
    const hero = fresh(heroRaw) ? heroRaw : null;
    const ea = fresh(eaRaw) ? eaRaw : null;
    const tnx = fresh(tnxRaw) ? tnxRaw : null;
    const checked = fiveRaw?.checked_at ?? heroRaw?.checked_at ?? eaRaw?.checked_at
      ?? tnxRaw?.checked_at;
    const stalePoller = (fiveRaw || heroRaw || eaRaw || tnxRaw)
      && !five && !hero && !ea && !tnx;

    // Surface the watchdog verdict here too — /balance is the owner's "is
    // everything alive" reflex, so it should answer for the jobs as well.
    const { data: wd } = await sb
      .from("app_config").select("value").eq("key", "watchdog").maybeSingle();
    const wdVal = wd?.value as
      { failing?: { check?: string }[]; checked_at?: string } | null;
    const failing = (wdVal?.failing ?? []).map((f) => f.check ?? "?");
    // Same staleness logic as telegram-notify: a frozen verdict is not health.
    const wdAgeMs = wdVal?.checked_at
      ? Date.now() - new Date(wdVal.checked_at).getTime() : Infinity;
    if (wdAgeMs > 30 * 60 * 1000) failing.push("watchdog_stale");

    reply = [
      // HeroSMS first: it serves SMS for 150 services carrying 99.4% of order
      // volume, so it is the number that answers "can we sell right now".
      balanceLine("5sim", five?.balance_usd),
      balanceLine("HeroSMS", hero?.balance_usd),
      balanceLine("esimaccess", ea?.balance_usd),
      balanceLine("Telnyx", tnx?.balance_usd),
      stalePoller ? "⚠️ balance readings are STALE — the poller may be dead" : "",
      failing.length > 0
        ? `🚨 watchdog: ${esc(failing.join(", "))}`
        : "🟢 watchdog: all jobs healthy",
      checked ? `\n<i>checked ${esc(checked)}</i>` : "",
    ].filter(Boolean).join("\n");
  } else if (cmd === "/announce") {
    // Read `raw`, NOT `text`. The parser lowercases every incoming command, and
    // an announcement is shown to users VERBATIM — "eSIMs are back" must not
    // reach them as "esims are back".
    const body = raw.replace(/^\/announce(@\S+)?\s*/i, "").trim();
    const { data: cur } = await sb
      .from("app_config").select("value").eq("key", "announcement").maybeSingle();
    const curVal = (cur?.value ?? {}) as { active?: boolean; text?: string; kind?: string };

    if (body === "") {
      reply = curVal.active
        ? `📣 Live now:\n\n<b>${esc(curVal.text ?? "")}</b>\n\n` +
          `<code>/announce off</code> to clear it.`
        : "📣 Nothing is showing.\n\n" +
          "<code>/announce Your message</code>\n" +
          "<code>/announce warn Your message</code> — amber";
    } else if (body.toLowerCase() === "off") {
      const { error } = await sb.from("app_config")
        .update({ value: { active: false, text: "", kind: "info", id: "" } })
        .eq("key", "announcement");
      reply = error ? `⚠️ Couldn't clear it: ${esc(error.message)}` : "📣 Cleared.";
    } else {
      const warn = /^warn\s+/i.test(body);
      const msg = warn ? body.replace(/^warn\s+/i, "").trim() : body;
      if (msg.length === 0) {
        reply = "⚠️ Nothing to post — give it some text after <code>warn</code>.";
      } else if (msg.length > MAX_ANNOUNCE) {
        reply = `⚠️ Too long: ${msg.length} characters, limit ${MAX_ANNOUNCE}. ` +
                `Truncating would hide the end of your own message, so it is refused instead.`;
      } else {
        // A fresh `id` per post is what makes a DISMISSED banner come back for
        // the NEXT announcement. Without it the client can only remember
        // "dismissed", and every later message is invisible to whoever waved
        // the first one away — a broadcast channel that quietly stops
        // broadcasting to exactly the people who have used it before.
        const { error } = await sb.from("app_config")
          .update({
            value: {
              active: true, text: msg,
              kind: warn ? "warn" : "info",
              id: new Date().toISOString(),
            },
          })
          .eq("key", "announcement");
        reply = error
          ? `⚠️ Couldn't post it: ${esc(error.message)}`
          : `📣 Live${warn ? " (amber)" : ""}:\n\n<b>${esc(msg)}</b>\n\n` +
            `<i>On Home for everyone running 1.6+. Dismissible — a new one shows again.</i>`;
      }
    }
  } else if (cmd === "/esim") {
    if (arg !== "on" && arg !== "off") {
      const { data: p } = await sb
        .from("app_config").select("value").eq("key", "esim_paused").maybeSingle();
      reply = `🌐 eSIMs are <b>${p?.value === true ? "OFF sale" : "on sale"}</b>.\n\n` +
              `<code>/esim off</code> · <code>/esim on</code>`;
    } else {
      const pausing = arg === "off";
      // Destructure the error. set_esim_paused reports how many plans it moved,
      // and resuming a catalog whose provider is gone legitimately restores 0 —
      // that has to be shown, not read as success.
      const { data, error } = await sb.rpc("set_esim_paused", { p_paused: pausing });
      const d = (data ?? {}) as { plans_active?: number; plans_changed?: number };
      reply = error
        ? `⚠️ Couldn't change it: ${esc(error.message)}`
        : `🌐 eSIMs ${pausing ? "are now OFF sale" : "are back on sale"}.\n` +
          `${d.plans_changed ?? 0} plans changed · ${d.plans_active ?? 0} now on sale` +
          (!pausing && (d.plans_active ?? 0) === 0
            ? `\n\n⚠️ Nothing came back — the catalog has not been synced recently, ` +
              `so there is nothing to put on sale. Wire the new provider's sync first.`
            : "");
    }
  } else if (cmd === "/lines") {
    // 🔴 `set_lines_paused` shipped with NO CALLER ANYWHERE. The kill switch
    // for a product that costs $1/month per subscriber existed only as a
    // function you had to open a SQL console to reach — which is exactly the
    // moment you cannot. Mirrors /esim precisely, including reporting the live
    // count so "pausing did nothing" is visible rather than looking like
    // success.
    if (arg !== "on" && arg !== "off") {
      const { data: p } = await sb
        .from("app_config").select("value").eq("key", "lines_paused").maybeSingle();
      const { count } = await sb.from("phone_lines")
        .select("id", { count: "exact", head: true })
        .in("status", ["active", "grace", "past_due"]);
      reply = `📞 Second numbers are <b>${p?.value === true ? "OFF sale" : "on sale"}</b>.\n` +
              `${count ?? 0} live line(s).\n\n` +
              `<code>/lines off</code> · <code>/lines on</code>`;
    } else {
      const pausing = arg === "off";
      const { data, error } = await sb.rpc("set_lines_paused", { p_paused: pausing });
      const d = (data ?? {}) as { active_lines?: number };
      reply = error
        ? `⚠️ Couldn't change it: ${esc(error.message)}`
        : `📞 Second numbers ${pausing ? "are now OFF sale" : "are back on sale"}.\n` +
          `${d.active_lines ?? 0} existing line(s) keep working` +
          (pausing
            ? `\n\n<i>Pausing stops NEW rentals only. Live lines keep sending, ` +
              `receiving and calling — and keep costing us rent until they lapse.</i>`
            : "");
    }
  }

  await sendMessage(reply);
  return ok();
});

// ─────────────────────────────────────────────────────────────────────────────
// Support chat — the owner's half of the conversation.
//
// Callers have ALREADY checked the secret token and the owner chat id. Nothing
// below may be reached by anyone else.

/** [✅ Accept] on the first message of a thread. */
async function handleCallback(
  cb: { id?: string; data?: string },
): Promise<Response> {
  const ok = () => json({ ok: true });
  const data = cb.data ?? "";
  if (!data.startsWith("sup:accept:")) { await answerCallback(cb.id ?? ""); return ok(); }

  const threadId = data.slice("sup:accept:".length);
  const sb = admin();
  // Claim-gated: only an OPEN thread can be accepted, so a double-tap (or a
  // stale button from an old notification) cannot reopen a closed conversation.
  const { data: claimed, error } = await sb
    .from("support_threads")
    .update({ status: "assigned" })
    .eq("id", threadId).eq("status", "open")
    .select("id");
  if (error) console.error(`support accept: ${error.message}`);

  await answerCallback(
    cb.id ?? "",
    claimed?.length ? "You're on it — reply to the message to answer." : "Already handled.",
  );
  return ok();
}

/** The owner replied to a relayed message. Route it back to that user.
 *
 *  Returns false when the reply does not correspond to a support message, so
 *  the caller can fall through and treat it as an ordinary command. */
async function handleAgentReply(replyToId: number, text: string): Promise<boolean> {
  const sb = admin();

  // tg_message_id -> thread. Set when the message was relayed, which is why a
  // reply to ANY message in a thread works, not only the newest.
  const { data: src, error: findErr } = await sb
    .from("support_messages")
    .select("thread_id")
    .eq("tg_message_id", replyToId)
    .maybeSingle();
  if (findErr) {
    console.error(`support reply: lookup failed tg=${replyToId}: ${findErr.message}`);
    return false;
  }
  if (!src) return false;                      // replying to some other message

  const { data: thread, error: thErr } = await sb
    .from("support_threads").select("id, user_id, status").eq("id", src.thread_id).maybeSingle();
  if (thErr || !thread) {
    console.error(`support reply: thread missing for tg=${replyToId}`);
    return false;
  }

  const { data: posted, error: postErr } = await sb.rpc("post_support_message", {
    p_user: thread.user_id, p_body: text, p_sender: "agent",
  });
  if (postErr) {
    console.error(`support reply: post failed thread=${thread.id}: ${postErr.message}`);
    await sendMessage("⚠️ Couldn't deliver that reply — it was NOT sent to the user.");
    return true;
  }
  const res = posted as { ok?: boolean; reason?: string } | null;
  if (!res?.ok) {
    await sendMessage(`⚠️ Reply rejected (${esc(res?.reason ?? "unknown")}) — NOT sent.`);
    return true;
  }

  // Answering implies accepting: a thread the owner has replied to is theirs,
  // whether or not they pressed the button first.
  if (thread.status === "open") {
    await sb.from("support_threads").update({ status: "assigned" }).eq("id", thread.id);
  }

  // Wake the user. Without this the reply sits unread until they happen to
  // reopen the app, which for a support answer is most of its value gone.
  await pushSupportReply(sb, thread.user_id, text);
  return true;
}

/** Plain text from the owner while a conversation is assigned → send it there.
 *
 *  Returns false when there is nothing assigned, so the caller falls through to
 *  command parsing and an ordinary typo still gets the help text. */
async function routeToAssignedThread(text: string): Promise<boolean> {
  const sb = admin();

  // Most recently active assigned thread. With several open at once this is a
  // guess, which is why the confirmation below NAMES the recipient — the owner
  // must be able to see immediately that it went somewhere they did not mean,
  // and `reply` remains the way to target one explicitly.
  const { data: thread, error } = await sb
    .from("support_threads")
    .select("id, user_id")
    .eq("status", "assigned")
    .order("last_message_at", { ascending: false })
    .limit(1).maybeSingle();
  if (error) {
    console.error(`support route: lookup failed: ${error.message}`);
    return false;
  }
  if (!thread) return false;

  const { data: posted, error: postErr } = await sb.rpc("post_support_message", {
    p_user: thread.user_id, p_body: text, p_sender: "agent",
  });
  if (postErr) {
    console.error(`support route: post failed thread=${thread.id}: ${postErr.message}`);
    await sendMessage("⚠️ Couldn't deliver that — it was NOT sent to the user.");
    return true;
  }
  const res = posted as { ok?: boolean; reason?: string } | null;
  if (!res?.ok) {
    await sendMessage(`⚠️ Rejected (${esc(res?.reason ?? "unknown")}) — NOT sent.`);
    return true;
  }

  const { data: profile } = await sb
    .from("profiles").select("display_name").eq("user_id", thread.user_id).maybeSingle();
  const who = profile?.display_name?.trim() || `user ${String(thread.user_id).slice(0, 8)}`;

  await pushSupportReply(sb, thread.user_id, text);
  // Confirm, and say to WHOM. Silent delivery to an unnamed recipient is how
  // the owner ends up sending a private note into a customer conversation.
  await sendMessage(`✅ Sent to <b>${esc(who)}</b>.`);
  return true;
}

/** Best-effort APNs nudge. Never throws: a failed push must not make the owner
 *  think the message itself failed — it is stored and will render in-app. */
async function pushSupportReply(
  // deno-lint-ignore no-explicit-any
  sb: any, userId: string, text: string,
): Promise<void> {
  try {
    const { data: devices } = await sb
      .from("push_devices").select("token, environment").eq("user_id", userId);
    if (!devices?.length) return;
    for (const d of devices) {
      await sendPush(d.token, {
        alertTitle: "vSMS support",
        alertBody: text.length > 120 ? `${text.slice(0, 117)}…` : text,
        sound: "default",
        // No orderId: PushManager routes on that key, and a support reply is
        // not an order — carrying one would deep-link into the wrong screen.
        customData: { kind: "support" },
      }, d.environment === "sandbox" ? "sandbox" : undefined);
    }
  } catch (e) {
    console.error(`support push failed user=${userId}: ${String(e)}`);
  }
}
