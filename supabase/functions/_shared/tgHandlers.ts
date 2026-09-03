// Command dispatch for the Telegram ops bot.
//
// WHY THIS IS A _shared FILE AND NOT telegram-webhook's own code: telegram-setup
// offers a `{"preview": "/trials"}` action so a command can be rendered without
// a phone in the loop. Importing it from telegram-webhook/index.ts would run
// that module's top-level `Deno.serve` and start a SECOND server inside the
// setup function. So the dispatch lives here and BOTH functions import it.
//
// AUTHORISATION IS NOT DONE HERE. `runCommand` is reachable only after the
// caller has proved it is Telegram (secret-token header) and the owner (chat
// id), or — in telegram-setup — after the cron secret. Nothing in this file
// re-checks that, so do not call it from anywhere that has not.
//
// Support-chat routing is deliberately NOT here either: it needs Telegram
// context (reply_to_message ids, callback queries, the ability to push to a
// device) and has nothing to say in a preview. It stays in telegram-webhook.

import { admin } from "./supabaseAdmin.ts";
import { esc } from "./telegram.ts";
import { ago, parisFull, stamp } from "./tgFormat.ts";
import {
  balanceLine,
  CONFIG_KEYS,
  formatAlerts,
  formatConfig,
  formatDelivery,
  formatDigest,
  formatFailures,
  formatFunnel,
  formatGross,
  formatLineCountries,
  formatLines,
  formatLinesMoney,
  formatNow,
  formatOrders,
  formatRevenue,
  formatRoute,
  formatSubs,
  formatSupport,
  formatTrials,
  TELNYX_LOW_USD,
} from "./opsFormat.ts";
import { COMMAND_BY_NAME, CommandSpec, helpText, PERIODS } from "./tgCommands.ts";

/** Announcement ceiling. The banner is two or three lines on a phone; anything
 *  longer is silently truncated by the layout, which would let the owner send a
 *  message whose end nobody ever reads. Refuse instead of truncating. */
const MAX_ANNOUNCE = 280;

/** Everything a handler is allowed to know about the message.
 *
 *  `raw` and `rawBody` preserve the ORIGINAL CASE. /announce must read them —
 *  the parser lowercases every command, and an announcement is shown to users
 *  verbatim, so building it from the parsed text would deliver "esims are back"
 *  to every phone. */
export interface Ctx {
  // deno-lint-ignore no-explicit-any
  sb: any;
  /** parts[1] with a leading "-" or "/" stripped, lowercased. */
  arg: string;
  /** Everything after the command word, original case, trimmed. */
  rawBody: string;
  /** The whole message, original case, trimmed. */
  raw: string;
  /** The whole message lowercased and split on whitespace. */
  parts: string[];
}

/** What a handler hands back.
 *
 *  `stamped` is a FLAG, not a search for "🕒 " in the rendered text. The
 *  formatters all stamp themselves and the hand-built replies do not, so the
 *  dispatcher has to know which it got — and it cannot ask the string:
 *  /announce echoes owner-written text verbatim, so a message containing that
 *  emoji would suppress the footer on the one reply that proves a banner went
 *  live. A bare string means NOT stamped. */
export interface HandlerReply { html: string; stamped: true }
type Handler = (ctx: Ctx) => Promise<string | HandlerReply>;

/** Mark a reply as already carrying its own 🕒 footer (every format* does). */
const stamped = (html: string): HandlerReply => ({ html, stamped: true });

/** One shape for every failed read, so a broken RPC never renders as an empty
 *  but plausible-looking answer — which is the failure mode that let a dead
 *  poller produce confident "all is well" digests. */
const readFail = (what: string) => `⚠️ Couldn't read ${what} right now.`;

// ── handlers ────────────────────────────────────────────────────────────────

/** /revenue and /profit share a body: same snapshot, same subscription read,
 *  different formatter. They are kept as two COMMANDS on purpose — /revenue
 *  answers "how much did customers pay", full stop, and /profit is where the
 *  derived P&L lives. They used to be aliases for one P&L, which meant there
 *  was no way to ask the bot for plain takings. */
async function money(ctx: Ctx, gross: boolean): Promise<string | HandlerReply> {
  const { sb, arg } = ctx;
  // p_window is an interval; null = lifetime. supabase-js sends JSON null,
  // which Postgres binds as SQL NULL, so the DEFAULT is never applied — the
  // function must (and does) treat an explicit null as "no lower bound"
  // rather than relying on its own default value.
  const { data: snap, error } = await sb.rpc("revenue_snapshot", {
    p_window: PERIODS[arg],
  });
  // Read the line's money FIRST — it belongs in the HEADLINE total, not a
  // footnote. A $9.99 subscription is $9.99 taken, exactly like a credit pack,
  // and a renewal is another $9.99.
  const { data: lm, error: lmErr } = await sb.rpc("lines_money_snapshot", {
    p_window: PERIODS[arg],
  });
  if (lmErr) console.error("lines_money_snapshot failed:", lmErr.message);
  if (error) console.error("revenue_snapshot failed:", error.message);

  if (error || !snap) return readFail("revenue");

  const fmt = gross ? formatGross : formatRevenue;
  let reply = fmt(
    snap as Record<string, unknown>,
    lmErr ? null : (lm as Record<string, unknown> | null),
  );

  // A failed read must SAY the total is short, never quietly omit
  // subscriptions — an absent block reads as "no subscriptions", which is the
  // same falsehood in a quieter costume.
  if (lmErr) {
    reply += "\n\n⚠️ <b>Subscriptions not included</b> — couldn't read them, " +
      "so the total above is LOW.";
  } else if (lm) {
    // formatLinesMoney is the only half of this reply that stamps — neither
    // formatGross nor formatRevenue does — so the flag tracks whether it ran.
    reply += formatLinesMoney(lm as Record<string, unknown>);
    return stamped(reply);
  }
  return reply;
}

/** /stats /today /week — the same digest over three windows. */
async function digest(ctx: Ctx, window: string): Promise<string | HandlerReply> {
  const { sb } = ctx;
  const { data: snap, error } = await sb.rpc("ops_snapshot", { p_window: window });
  // Same window, so the subscription figure describes the same period as
  // everything above it. A mismatched window here would be a quiet lie.
  const { data: dlm, error: dlmErr } = await sb.rpc("lines_money_snapshot", {
    p_window: window,
  });
  if (dlmErr) console.error("lines_money_snapshot (digest) failed:", dlmErr.message);
  if (error) console.error("ops_snapshot failed:", error.message);
  return error || !snap ? readFail("stats") : stamped(formatDigest(
    snap as Record<string, unknown>,
    dlmErr ? null : (dlm as Record<string, unknown> | null),
  ));
}

export const handlers: Record<string, Handler> = {
  // ── Status ───────────────────────────────────────────────────────────────
  now: async ({ sb }) => {
    const { data, error } = await sb.rpc("ops_now");
    if (error) console.error("ops_now failed:", error.message);
    return error || !data ? readFail("the status") : stamped(formatNow(data as Record<string, unknown>));
  },

  today: (ctx) => digest(ctx, "24 hours"),
  week: (ctx) => digest(ctx, "7 days"),
  stats: (ctx) => digest(ctx, "6 hours"),

  funnel: async ({ sb, arg }) => {
    const { data, error } = await sb.rpc("ops_funnel", {
      p_window: COMMAND_BY_NAME.funnel.periods![arg],
    });
    if (error) console.error("ops_funnel failed:", error.message);
    return error || !data ? readFail("the funnel") : stamped(formatFunnel(data as Record<string, unknown>));
  },

  alerts: async ({ sb }) => {
    // The watchdog verdict plus every alert-state key telegram-notify stamps.
    // Read as DATA, not as a rendering: what "low_balance_block" means is the
    // formatter's problem, so a new alert key added by the notify side shows up
    // here without a change to this function.
    const NAMED = [
      "watchdog", "low_balance_block", "provider_fault", "fail_streak",
      "support_nag", "telegram_bot", "balance_alert_tier",
    ];
    const { data: named, error } = await sb
      .from("app_config").select("key, value").in("key", NAMED);
    if (error) console.error("alerts: named read failed:", error.message);
    // Anything else the alert layer stamps. Two queries rather than one `.or`
    // filter: PostgREST's or-syntax uses `*` wildcards and its own escaping
    // rules, and a silently-empty result here would read as "nothing firing".
    // `_` is a single-character WILDCARD in SQL LIKE, so an unescaped
    // "%_alert%" is broader than it reads. It still matches everything
    // intended, but a pattern that does not mean what it says is one edit away
    // from matching a balance or a sync cursor and rendering it as an alert.
    const { data: wild, error: wildErr } = await sb
      .from("app_config").select("key, value").like("key", "%\\_alert%");
    if (wildErr) console.error("alerts: wildcard read failed:", wildErr.message);
    if (error && wildErr) return readFail("the alerts");

    const rows = [...(named ?? []), ...(wild ?? [])] as
      { key: string; value: unknown }[];
    const states: Record<string, unknown> = {};
    let watchdog: unknown = null;
    for (const r of rows) {
      if (r.key === "watchdog") watchdog = r.value;
      else states[r.key] = r.value;
    }
    return stamped(formatAlerts({ watchdog, states }));
  },

  balance: async ({ sb }) => {
    // BOTH providers. Reporting only SMSPool here survived the 2026-07-20
    // migration and became actively misleading: it alarmed about the provider
    // that now only funds eSIMs, while the balance gating every SMS order was
    // not shown at all.
    const { data: rows } = await sb
      .from("app_config").select("key, value")
      .in("key", ["5sim_health", "herosms_health", "esimaccess_health",
        "telnyx_health"]);

    const read = (k: string) => {
      const v = (rows ?? []).find((r: { key: string }) => r.key === k)?.value as
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
    // Telnyx funds the second-number line — rent per subscriber, and the one
    // float the owner has named as that product's hard blocker.
    const telnyxRaw = read("telnyx_health");
    const five = fresh(fiveRaw) ? fiveRaw : null;
    const hero = fresh(heroRaw) ? heroRaw : null;
    const ea = fresh(eaRaw) ? eaRaw : null;
    const telnyx = fresh(telnyxRaw) ? telnyxRaw : null;
    const checked = fiveRaw?.checked_at ?? heroRaw?.checked_at ??
      eaRaw?.checked_at ?? telnyxRaw?.checked_at;
    const stalePoller = (fiveRaw || heroRaw || eaRaw || telnyxRaw) &&
      !five && !hero && !ea && !telnyx;

    // Surface the watchdog verdict here too — /balance is the owner's "is
    // everything alive" reflex, so it should answer for the jobs as well.
    const { data: wd } = await sb
      .from("app_config").select("value").eq("key", "watchdog").maybeSingle();
    const wdVal = wd?.value as
      { failing?: { check?: string }[]; checked_at?: string } | null;
    const failing = (wdVal?.failing ?? []).map((f) => f.check ?? "?");
    // Same staleness logic as telegram-notify: a frozen verdict is not health.
    const wdAgeMs = wdVal?.checked_at
      ? Date.now() - new Date(wdVal.checked_at).getTime()
      : Infinity;
    if (wdAgeMs > 30 * 60 * 1000) failing.push("watchdog_stale");

    return [
      balanceLine("5sim", five?.balance_usd),
      balanceLine("HeroSMS", hero?.balance_usd),
      balanceLine("esimaccess", ea?.balance_usd),
      // Telnyx gets its own low-water mark: the SMS $37.50 threshold would
      // print a permanent "top up" against $1/month rent.
      balanceLine("Telnyx", telnyx?.balance_usd, TELNYX_LOW_USD),
      stalePoller ? "⚠️ balance readings are STALE — the poller may be dead" : "",
      failing.length > 0
        ? `🚨 watchdog: ${esc(failing.join(", "))}`
        : "🟢 watchdog: all jobs healthy",
      // Paris, with the age spelled out. A bare ISO timestamp is a number the
      // reader has to convert at 1am, and "checked 2026-08-21T16:43:00Z" says
      // nothing about whether that was a minute or a day ago.
      checked ? `\n<i>checked ${esc(parisFull(checked))} · ${esc(ago(checked))}</i>` : "",
    ].filter(Boolean).join("\n");
  },

  // ── Money ────────────────────────────────────────────────────────────────
  revenue: (ctx) => money(ctx, true),
  profit: (ctx) => money(ctx, false),

  subs: async ({ sb }) => {
    // No period: subscription and line STATE is a right-now question, and the
    // notification block inside carries its own fixed 7-day window.
    const { data, error } = await sb.rpc("ops_subs");
    if (error) console.error("ops_subs failed:", error.message);
    return error || !data ? readFail("subscriptions") : stamped(formatSubs(data as Record<string, unknown>));
  },

  // ── Lines ────────────────────────────────────────────────────────────────
  trials: async ({ sb }) => {
    const { data, error } = await sb.rpc("ops_trials");
    if (error) console.error("ops_trials failed:", error.message);
    return error || !data ? readFail("the trials") : stamped(formatTrials(data as Record<string, unknown>));
  },

  lines: async ({ sb, arg }) => {
    // 🔴 `set_lines_paused` shipped with NO CALLER ANYWHERE. The kill switch
    // for a product that costs $1/month per subscriber existed only as a
    // function you had to open a SQL console to reach — which is exactly the
    // moment you cannot. The on/off half mirrors /esim precisely, including
    // reporting the live count so "pausing did nothing" is visible rather than
    // looking like success.
    // `/lines countries` — the international catalog. READ-ONLY, and it shares
    // the /lines name deliberately: it is the same product, and a separate
    // top-level command would be one more entry in a popup menu the owner
    // scrolls. Checked before both other branches because "countries" is
    // neither on/off nor the fleet list.
    if (arg === "countries" || arg === "country") {
      const { data, error } = await sb.rpc("ops_line_countries");
      if (error) console.error("ops_line_countries failed:", error.message);
      return error || !data
        ? readFail("the country catalog")
        : stamped(formatLineCountries(data as Record<string, unknown>));
    }
    if (arg !== "on" && arg !== "off") {
      // No arg now LISTS the lines rather than only reporting the switch: the
      // switch is one bit and the lines are the product.
      const { data, error } = await sb.rpc("ops_lines");
      if (error) console.error("ops_lines failed:", error.message);
      return error || !data ? readFail("the lines") : stamped(formatLines(data as Record<string, unknown>));
    }
    const pausing = arg === "off";
    const { data, error } = await sb.rpc("set_lines_paused", { p_paused: pausing });
    const d = (data ?? {}) as { active_lines?: number };
    return error
      ? `⚠️ Couldn't change it: ${esc(error.message)}`
      : `📞 Second numbers ${pausing ? "are now OFF sale" : "are back on sale"}.\n` +
        `${d.active_lines ?? 0} existing line(s) keep working` +
        (pausing
          ? `\n\n<i>Pausing stops NEW rentals only. Live lines keep sending, ` +
            `receiving and calling — and keep costing us rent until they lapse.</i>`
          : "");
  },

  // ── Delivery ─────────────────────────────────────────────────────────────
  failures: async ({ sb, arg }) => {
    const spec = COMMAND_BY_NAME.failures;
    const window = spec.periods![arg]!;
    const { data, error } = await sb.rpc("ops_failures", { p_window: window });
    if (error) console.error("ops_failures failed:", error.message);
    return error || !data
      ? readFail("the failures")
      : stamped(formatFailures(data as Record<string, unknown>,
                               arg === "" ? spec.defaultPeriod! : arg));
  },

  orders: async ({ sb, arg }) => {
    // Same period vocabulary as /revenue, with two deliberate differences:
    //
    //  * the DEFAULT is 24h, not lifetime. This prints one line per order, so
    //    defaulting to "all" would dump the entire history into a chat message.
    //  * a null period (all/lifetime) becomes a very long finite interval,
    //    because orders_recent does `now() - p_window` and a NULL there yields
    //    NULL, which would silently match no rows and read as "no orders".
    const window = arg === "" ? "24 hours" : (PERIODS[arg] ?? "3650 days");
    const { data, error } = await sb.rpc("orders_recent", { p_window: window });
    if (error) console.error("orders_recent failed:", error.message);
    return error || !data
      ? readFail("orders")
      : stamped(formatOrders(data as Record<string, unknown>,
                             arg === "" ? "24h" : (arg || "all")));
  },

  delivery: async ({ sb, arg }) => {
    const { data, error } = await sb.rpc("ops_delivery", {
      p_window: COMMAND_BY_NAME.delivery.periods![arg],
    });
    if (error) console.error("ops_delivery failed:", error.message);
    return error || !data
      ? readFail("delivery")
      : stamped(formatDelivery(data as Record<string, unknown>, arg === "" ? "7d" : arg));
  },

  route: async ({ sb, parts }) => {
    // Both arguments come off the LOWERCASED parts: service ids and country ids
    // are lowercase in the catalog, so "/route Telegram CO" must find the same
    // row as "/route telegram co".
    const service = (parts[1] ?? "").replace(/^[-/]+/, "");
    const country = (parts[2] ?? "").replace(/^[-/]+/, "");
    if (service === "") {
      return "🔎 <b>Which service?</b>\n\n" +
        "<code>/route telegram</code> — every country for that service\n" +
        "<code>/route telegram co</code> — one route, in full";
    }
    const { data, error } = await sb.rpc("ops_route", {
      p_service: service,
      p_country: country === "" ? null : country,
    });
    if (error) console.error("ops_route failed:", error.message);
    return error || !data ? readFail("that route") : stamped(formatRoute(data as Record<string, unknown>));
  },

  // ── Other ────────────────────────────────────────────────────────────────
  support: async ({ sb }) => {
    const { data, error } = await sb.rpc("ops_support");
    if (error) console.error("ops_support failed:", error.message);
    return error || !data ? readFail("support") : stamped(formatSupport(data as Record<string, unknown>));
  },

  // ── Controls ─────────────────────────────────────────────────────────────
  config: async ({ sb }) => {
    // A read-only window on the settings that decide money and gating. Every
    // one of these is a value the owner can change with a single UPDATE and no
    // deploy, which is exactly why there has to be a way to READ them from the
    // phone — several have been changed and then misremembered.
    // The key list is CONFIG_KEYS itself, not a second copy of it. A key added
    // to the formatter alone would render a permanent "— not set", which the
    // footer spells out as "the guard reading it is on its own fallback" — a
    // false alarm about a key that is set; a key added here alone would be
    // invisible. This repo's own "a constant duplicated across files WILL
    // drift" rule, with a wrong assertion rather than a blank as the payload.
    const { data, error } = await sb
      .from("app_config").select("key, value")
      .in("key", CONFIG_KEYS.map((k) => k.key));
    if (error) console.error("config read failed:", error.message);
    return error || !data
      ? readFail("the settings")
      : stamped(formatConfig(data as { key: string; value: unknown }[]));
  },

  announce: async ({ sb, rawBody }) => {
    // Read the RAW body, NOT the parsed one. The parser lowercases every
    // incoming command, and an announcement is shown to users VERBATIM —
    // "eSIMs are back" must not reach them as "esims are back".
    const body = rawBody.trim();
    const { data: cur } = await sb
      .from("app_config").select("value").eq("key", "announcement").maybeSingle();
    const curVal = (cur?.value ?? {}) as { active?: boolean; text?: string; kind?: string };

    if (body === "") {
      return curVal.active
        ? `📣 Live now:\n\n<b>${esc(curVal.text ?? "")}</b>\n\n` +
          `<code>/announce off</code> to clear it.`
        : "📣 Nothing is showing.\n\n" +
          "<code>/announce Your message</code>\n" +
          "<code>/announce warn Your message</code> — amber";
    }
    if (body.toLowerCase() === "off") {
      const { error } = await sb.from("app_config")
        .update({ value: { active: false, text: "", kind: "info", id: "" } })
        .eq("key", "announcement");
      return error ? `⚠️ Couldn't clear it: ${esc(error.message)}` : "📣 Cleared.";
    }
    const warn = /^warn\s+/i.test(body);
    const msg = warn ? body.replace(/^warn\s+/i, "").trim() : body;
    if (msg.length === 0) {
      return "⚠️ Nothing to post — give it some text after <code>warn</code>.";
    }
    if (msg.length > MAX_ANNOUNCE) {
      return `⚠️ Too long: ${msg.length} characters, limit ${MAX_ANNOUNCE}. ` +
        `Truncating would hide the end of your own message, so it is refused instead.`;
    }
    // A fresh `id` per post is what makes a DISMISSED banner come back for the
    // NEXT announcement. Without it the client can only remember "dismissed",
    // and every later message is invisible to whoever waved the first one away
    // — a broadcast channel that quietly stops broadcasting to exactly the
    // people who have used it before.
    const { error } = await sb.from("app_config")
      .update({
        value: {
          active: true,
          text: msg,
          kind: warn ? "warn" : "info",
          id: new Date().toISOString(),
        },
      })
      .eq("key", "announcement");
    return error
      ? `⚠️ Couldn't post it: ${esc(error.message)}`
      : `📣 Live${warn ? " (amber)" : ""}:\n\n<b>${esc(msg)}</b>\n\n` +
        `<i>On Home for everyone running 1.6+. Dismissible — a new one shows again.</i>`;
  },

  esim: async ({ sb, arg }) => {
    if (arg !== "on" && arg !== "off") {
      const { data: p } = await sb
        .from("app_config").select("value").eq("key", "esim_paused").maybeSingle();
      return `🌐 eSIMs are <b>${p?.value === true ? "OFF sale" : "on sale"}</b>.\n\n` +
        `<code>/esim off</code> · <code>/esim on</code>`;
    }
    const pausing = arg === "off";
    // Destructure the error. set_esim_paused reports how many plans it moved,
    // and resuming a catalog whose provider is gone legitimately restores 0 —
    // that has to be shown, not read as success.
    const { data, error } = await sb.rpc("set_esim_paused", { p_paused: pausing });
    const d = (data ?? {}) as { plans_active?: number; plans_changed?: number };
    return error
      ? `⚠️ Couldn't change it: ${esc(error.message)}`
      : `🌐 eSIMs ${pausing ? "are now OFF sale" : "are back on sale"}.\n` +
        `${d.plans_changed ?? 0} plans changed · ${d.plans_active ?? 0} now on sale` +
        (!pausing && (d.plans_active ?? 0) === 0
          ? `\n\n⚠️ Nothing came back — the catalog has not been synced recently, ` +
            `so there is nothing to put on sale. Wire the new provider's sync first.`
          : "");
  },

  metrics: async ({ sb, arg }) => {
    // The user-facing delivery figure is the vendor's network rate rendered
    // as High/Medium/Low; `app_config.delivery_metrics_hidden` blanks it on
    // every screen (client 2.8+). Written directly rather than through an
    // RPC: it is one boolean with no side effects, unlike the two pause
    // switches, which also move catalog rows and report the count.
    if (arg !== "on" && arg !== "off") {
      const { data: p, error } = await sb
        .from("app_config").select("value").eq("key", "delivery_metrics_hidden").maybeSingle();
      if (error) {
        console.error("delivery_metrics_hidden read failed:", error.message);
        return readFail("the metrics switch");
      }
      return `📊 Delivery rate is <b>${p?.value === true ? "HIDDEN" : "shown"}</b> in the app.\n\n` +
        `<code>/metrics off</code> · <code>/metrics on</code>`;
    }
    const hiding = arg === "off";
    const { error } = await sb.from("app_config")
      .upsert({ key: "delivery_metrics_hidden", value: hiding }, { onConflict: "key" });
    return error
      ? `⚠️ Couldn't change it: ${esc(error.message)}`
      : `📊 Delivery rate is now <b>${hiding ? "HIDDEN" : "shown"}</b> in the app.` +
        `\n\n<i>Takes effect on the next cold launch of 2.8 or later. Sorting and the ` +
        `country the app picks for a user still use the rate — only the number is ` +
        `${hiding ? "gone" : "back"}.</i>`;
  },

  help: () => Promise.resolve(helpText()),
};

// ── dispatch ────────────────────────────────────────────────────────────────

/** The "unknown period" reply, built from the spec so it can never advertise a
 *  period the handler would then reject. `args` is the canonical list — the
 *  aliases in `periods` ("week", "month", "quarter") are accepted but not
 *  taught, because a menu of thirteen synonyms is not a menu. */
function unknownPeriod(spec: CommandSpec, arg: string): string {
  const canonical = (spec.args ?? "").split("|").map((s) => s.trim()).filter(Boolean);
  const dflt = spec.defaultPeriod ? ` (${spec.defaultPeriod})` : "";
  const rest = canonical
    .filter((p) => p !== spec.defaultPeriod)
    .map((p) => `<code>${esc(p)}</code>`)
    .join(" · ");
  return `Unknown period <b>${esc(arg)}</b>.\n\n` +
    `Try: <code>/${spec.name}</code>${dflt}` + (rest ? `, or ${rest}` : "");
}

/**
 * Everything that happens AFTER authorisation, for a `/`-command: parse,
 * validate the period, dispatch, stamp. Returns the HTML to send.
 *
 * Pure with respect to Telegram — it never sends anything — which is what lets
 * telegram-setup render a command as a preview.
 */
export async function runCommand(rawText: string): Promise<string> {
  const raw = (rawText ?? "").trim();
  const text = raw.toLowerCase();
  const parts = text.split(/\s+/);
  const cmd = parts[0].replace(/@.*$/, ""); // strip @botname suffix
  const arg = (parts[1] ?? "").replace(/^[-/]+/, ""); // tolerate "-7d" / "/7d"
  // Original case, command word removed. /announce is the reason this exists.
  const rawBody = raw.replace(/^\/\S+\s*/, "");

  // The FALLBACK is a pointer, not the whole help text. Answering a typo with
  // 30 lines buries the typo, and answering plain prose with a command list
  // does not explain why the message went nowhere — which, for the owner
  // half-way through a support conversation, is the thing they need to know.
  let reply: string | HandlerReply;
  if (cmd === "" || cmd === "/help" || cmd === "/start") {
    reply = helpText();
  } else if (!cmd.startsWith("/")) {
    reply = "❓ Not a command — and no support conversation is assigned, so " +
      "this went nowhere.\n\nPress [✅ Accept] on a thread first, or " +
      "reply directly to a relayed message.\n\n/help for the commands.";
  } else {
    const name = cmd.slice(1);
    const spec = COMMAND_BY_NAME[name];
    const handler = handlers[name];
    if (!spec || !handler) {
      reply = `❓ Unknown command <b>${esc(cmd)}</b>.\n\nTry /help`;
    } else if (spec.periods && !Object.hasOwn(spec.periods, arg)) {
      // Object.hasOwn, not `in` and not truthiness: truthiness would reject
      // "all" (a legitimate key whose value is null), while `in` walks the
      // prototype chain — so `/revenue constructor` would pass the guard and
      // hand Object's constructor to the RPC as p_window.
      reply = unknownPeriod(spec, arg);
    } else {
      reply = await handler({ sb: admin(), arg, rawBody, raw, parts });
    }
  }

  // Every reply carries the Paris time it was rendered, so a screenshot is
  // never undatable. The new formatters stamp themselves; appending a second
  // one would print two clocks — so the handler SAYS which it produced. This
  // used to test `reply.includes("🕒 ")`, which meant an /announce body
  // containing that emoji silently suppressed the footer.
  return typeof reply === "string" ? `${reply}\n\n${stamp()}` : reply.html;
}
