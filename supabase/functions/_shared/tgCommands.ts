// The ops bot's command REGISTRY — the single source of truth for three things
// that used to be maintained by hand and drifted apart:
//
//   1. the `/` autocomplete popup (Telegram `setMyCommands`),
//   2. `/help`,
//   3. dispatch in telegram-webhook (`handlers` is keyed on these names).
//
// Before this file, `/help` was a hardcoded 30-line string literal and the
// autocomplete menu did not exist at all — so a command could be added, work
// perfectly, and be invisible to the only person who uses the bot. Anything
// that is not in COMMANDS is not in the menu, not in /help, and not reachable.
//
// METADATA ONLY. No Supabase client, no formatters, no handlers — telegram-setup
// imports this to build setMyCommands and must not pull the whole ops stack (and
// its secrets) in behind it. The handlers live in `tgHandlers.ts`.

export interface CommandSpec {
  /** Without the leading slash. Telegram requires lowercase, ≤ 32 chars. */
  name: string;
  /** Human-readable argument grammar. For period commands this doubles as the
   *  CANONICAL period list (split on "|") shown when an unknown period is
   *  given — `periods` itself carries aliases nobody needs to be told about. */
  args?: string;
  /** Accepted period token -> the interval handed to the RPC. `null` means
   *  lifetime. Membership is tested with Object.hasOwn by the dispatcher — see
   *  the note on PERIODS below for why that matters. */
  periods?: Record<string, string | null>;
  /** The period label used when none is given, e.g. "24h". Display only. */
  defaultPeriod?: string;
  /** ≤ 60 chars. This is the line Telegram shows in the `/` popup, where the
   *  name is already visible — so it says what the answer IS, not "shows the". */
  summary: string;
  /** Extra line(s) under the command in /help, for anything the 60-char
   *  summary cannot carry. Telegram HTML is allowed here (the popup is plain
   *  text, /help is not). */
  help?: string;
  group: "Status" | "Money" | "Lines" | "Delivery" | "Controls" | "Other";
  /** This command can WRITE. telegram-setup's `{"preview": "/…"}` refuses any
   *  command carrying this flag, so CRON_SECRET alone can never publish a
   *  banner on Home or flip a product kill switch.
   *
   *  It is marked per COMMAND, not per argument form: `/lines` and `/esim`
   *  with no argument are read-only, and refusing those in preview is an
   *  accepted cost — the alternative is a preview path that parses arguments
   *  to decide whether it is safe, which is the sort of guard that is one
   *  refactor away from being wrong. Use `/lines` from the chat instead. */
  mutates?: true;
}

/** Accepted `/revenue` `/profit` `/orders` periods -> the interval passed to the
 *  RPC. null means lifetime (the function reads p_window null as no lower bound).
 *
 *  Membership is tested with Object.hasOwn, NOT `in` and NOT truthiness:
 *  truthiness would reject "all" (a legitimate key whose value is null), while
 *  `in` walks the prototype chain — so `/revenue constructor` would pass the
 *  guard and hand Object's constructor to the RPC as p_window. */
export const PERIODS: Record<string, string | null> = {
  "": null, "all": null, "lifetime": null, "total": null, "ever": null,
  "24h": "24 hours", "today": "24 hours", "day": "24 hours",
  "7d": "7 days", "week": "7 days",
  "30d": "30 days", "month": "30 days",
  "90d": "90 days", "quarter": "90 days",
};

/** `/funnel` accepts only DAY windows, because it prints one row per day: a
 *  "24h" funnel would be a single line and "all" would be a wall of them. */
export const FUNNEL_PERIODS: Record<string, string> = {
  "": "7 days", "7d": "7 days", "week": "7 days",
  "14d": "14 days", "2w": "14 days",
  "30d": "30 days", "month": "30 days",
};

/** `/delivery` windows. 24h is offered because a provider outage has to be
 *  visible the same day; 30d is the longest window over which a rate here is
 *  still about the provider currently serving the route (providers have changed
 *  four times, and evidence does not carry across a switch). */
export const DELIVERY_PERIODS: Record<string, string> = {
  "": "7 days", "24h": "24 hours", "today": "24 hours", "day": "24 hours",
  "7d": "7 days", "week": "7 days",
  "30d": "30 days", "month": "30 days",
};

/** `/failures` is a triage view — "what broke and on which route". Only short
 *  windows: at 30d the route list is a month of noise and the question stops
 *  being answerable at a glance. */
export const FAILURE_PERIODS: Record<string, string> = {
  "": "24 hours", "24h": "24 hours", "today": "24 hours", "day": "24 hours",
  "7d": "7 days", "week": "7 days",
};

/** THE MENU ORDER IS THIS ARRAY'S ORDER. Telegram renders setMyCommands in the
 *  order given, so the first few entries are what the owner actually sees
 *  without scrolling: the status question first, then money, then the two
 *  product lines, then diagnostics, then the controls. */
export const COMMANDS: CommandSpec[] = [
  {
    name: "now",
    summary: "One screen: money, float, jobs, today so far",
    help: "Balances with runway · watchdog · what happened since midnight Paris.",
    group: "Status",
  },
  {
    name: "today",
    summary: "Last 24 hours — signups, orders, codes, money",
    group: "Status",
  },
  {
    name: "week",
    summary: "Last 7 days — signups, orders, codes, money",
    group: "Status",
  },
  {
    name: "trials",
    summary: "Which subscriptions convert to money, and when",
    help: "Free trials and paid subs, soonest first, with what will bill.",
    group: "Lines",
  },
  {
    name: "failures",
    args: "24h|7d",
    periods: FAILURE_PERIODS,
    defaultPeriod: "24h",
    summary: "What failed, on which route, and why",
    help: "No number, no code, e-mail, eSIM and call failures, grouped by route.",
    group: "Delivery",
  },
  {
    name: "orders",
    args: "24h|7d|30d|90d|all",
    periods: PERIODS,
    defaultPeriod: "24h",
    summary: "Every order, one line each, with its route",
    group: "Delivery",
  },
  {
    name: "delivery",
    args: "24h|7d|30d",
    periods: DELIVERY_PERIODS,
    defaultPeriod: "7d",
    summary: "Per-provider delivery, cancels and refusals",
    group: "Delivery",
  },
  {
    name: "route",
    args: "<service> [country]",
    summary: "Why a service or route is unavailable",
    help: "<code>/route telegram</code> · <code>/route telegram co</code>",
    group: "Delivery",
  },
  {
    name: "balance",
    summary: "Provider float and the watchdog verdict",
    group: "Status",
  },
  {
    name: "revenue",
    args: "24h|7d|30d|90d|all",
    periods: PERIODS,
    defaultPeriod: "all",
    summary: "Money customers actually paid, in USD",
    group: "Money",
  },
  {
    name: "profit",
    args: "24h|7d|30d|90d|all",
    periods: PERIODS,
    defaultPeriod: "all",
    summary: "Revenue minus Apple's cut and wholesale",
    group: "Money",
  },
  {
    name: "subs",
    summary: "Subscriptions and lines, and where they disagree",
    group: "Money",
  },
  {
    name: "lines",
    mutates: true,
    args: "countries|on|off",
    summary: "Second numbers: the fleet, the countries, on/off sale",
    help: "<code>/lines</code> lists them · <code>/lines countries</code> what we can " +
      "sell where, with wholesale · <code>/lines off</code> stops NEW rentals only.",
    group: "Lines",
  },
  {
    name: "support",
    summary: "Open conversations, oldest unanswered first",
    group: "Other",
  },
  {
    name: "alerts",
    summary: "What is firing right now, and what to do",
    group: "Status",
  },
  {
    name: "funnel",
    args: "7d|14d|30d",
    periods: FUNNEL_PERIODS,
    defaultPeriod: "7d",
    summary: "Signup → order → code → purchase, per day",
    group: "Status",
  },
  {
    name: "stats",
    summary: "Last 6 hours — the digest, on demand",
    group: "Status",
  },
  {
    name: "config",
    summary: "The money and gate settings, read-only",
    help: "Signup grant, e-mail caps, pause switches, swap price.",
    group: "Controls",
  },
  {
    name: "announce",
    mutates: true,
    args: "message",
    summary: "Post the banner on Home for everyone",
    help: "<code>/announce warn …</code> amber · <code>/announce off</code> clears\n" +
      "     <code>/announce</code> alone shows what is live",
    group: "Controls",
  },
  {
    name: "esim",
    mutates: true,
    args: "on|off",
    summary: "Put eSIMs on or off sale",
    group: "Controls",
  },
  {
    name: "help",
    summary: "Every command, grouped",
    group: "Other",
  },
];

/** O(1) lookup by name, without a leading slash. */
export const COMMAND_BY_NAME: Record<string, CommandSpec> = Object.fromEntries(
  COMMANDS.map((c) => [c.name, c]),
);

/** Payload for Telegram's setMyCommands.
 *
 *  Telegram validates BOTH fields and rejects the whole call on one bad entry:
 *  command must be lowercase [a-z0-9_] ≤ 32, description 3–256 chars. The
 *  description is rendered as PLAIN TEXT in the popup, so it must carry no HTML
 *  — a `<b>` there shows up literally. */
export function botCommands(): { command: string; description: string }[] {
  return COMMANDS.map((c) => ({ command: c.name, description: c.summary }));
}

/** The order groups appear in /help. Deliberately not alphabetical: the same
 *  reading order as the menu — what is happening, then money, then the lines,
 *  then diagnostics, then the switches. */
const GROUP_ORDER: CommandSpec["group"][] = [
  "Status", "Money", "Lines", "Delivery", "Controls", "Other",
];

/** /help, generated from COMMANDS so it can never omit a live command.
 *
 *  The footer is not decoration: every delivery rate in this bot excludes user
 *  cancels (≈60% of numbered orders, cancelled at a median 57s against codes
 *  arriving at a median 58s) and the app's own pre-selected routes, and every
 *  purchase figure is Production receipts only. A rate quoted without those
 *  three caveats is a different number, and the owner has already made
 *  decisions off the un-caveated version. */
/** 🔴 `args` and `summary` are AUTHOR-written plain text and they contain
 *  angle brackets — `<service> [country]` is the whole grammar of /route. Sent
 *  through Telegram's HTML parse_mode unescaped, that is an unsupported start
 *  tag, and Telegram rejects the ENTIRE message with 400 `can't parse
 *  entities`. The visible symptom is not a broken line: it is `/help`
 *  answering with NOTHING AT ALL, and the unknown-command fallback pointing at
 *  a /help that also says nothing.
 *
 *  `help` is deliberately NOT escaped — its doc comment declares Telegram HTML
 *  allowed, and it carries <code> spans on purpose.
 *
 *  Local, so this file keeps its "metadata only, no imports" property. */
function escHtml(v: string): string {
  return v.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

export function helpText(): string {
  const lines: string[] = ["🤖 <b>vSMS ops</b> — every command", ""];
  for (const group of GROUP_ORDER) {
    const inGroup = COMMANDS.filter((c) => c.group === group);
    if (inGroup.length === 0) continue;
    lines.push(`<b>${group}</b>`);
    for (const c of inGroup) {
      const args = c.args ? ` <i>${escHtml(c.args)}</i>` : "";
      lines.push(`/${escHtml(c.name)}${args} — ${escHtml(c.summary)}`);
      if (c.periods && c.defaultPeriod) {
        lines.push(`     <i>default: ${escHtml(c.defaultPeriod)}</i>`);
      }
      if (c.help) lines.push(`     ${c.help}`);
    }
    lines.push("");
  }
  lines.push(
    "<i>Every delivery rate here excludes user cancels and the app's own " +
      "pre-selection. Purchases are Production receipts only.</i>",
  );
  return lines.join("\n");
}
