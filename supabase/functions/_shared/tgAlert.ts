// One shape for every proactive alert the ops bot sends.
//
// Before this file, each sender invented its own layout: some led with the
// emoji, some with the fact, some printed a raw UTC ISO string, and several
// said what happened without ever saying what to DO about it. Read on a phone
// at 1am — which is when a 🔴 actually arrives — that is the difference between
// acting and going back to sleep.
//
// The contract is four slots, always in this order:
//   title   the verdict, in as few words as carry it
//   what    the facts: numbers, ids, amounts
//   why     (optional) why it costs money / why it matters
//   action  (optional) the imperative next step
// plus a Paris-time footer, because the owner reads this in France and a
// timestamp the reader has to convert in their head is one they get wrong.
//
// Severity vocabulary (design doc, "Alerts — unified shape"):
//   🔴 money leaking or the product is down — act now
//   🟠 becomes 🔴 without action (float runway, trial converting, stuck state)
//   🟡 degraded / an informational failure
//   🟢 recovered, or good news (purchase, conversion)
//   ℹ️ a business event (signup, trial started)

import { esc } from "./telegram.ts";
import { parisFull } from "./tgFormat.ts";

export type Severity = "🔴" | "🟠" | "🟡" | "🟢" | "ℹ️";

export interface Alert {
  sev: Severity;
  title: string;
  /** 1–2 lines of fact. Pre-escaped by the caller ONLY if it contains markup
   *  the caller built (e.g. <code>…</code>); raw DB text must go through esc(). */
  what: string;
  why?: string;
  action?: string;
  at?: Date | string;
}

/** Render one alert. Title is escaped here; `what`/`why`/`action` are passed
 *  through so a caller can embed <b>/<code>, which means a caller putting raw
 *  DB text in them MUST esc() it first. */
export function alertHtml(a: Alert): string {
  const lines = [`${a.sev} <b>${esc(a.title)}</b>`];
  if (a.what) lines.push(a.what);
  if (a.why) lines.push(`<i>${a.why}</i>`);
  if (a.action) lines.push(`→ ${a.action}`);
  lines.push(`🕒 ${parisFull(a.at ?? new Date())} Paris`);
  return lines.join("\n");
}

// ── Watchdog copy ────────────────────────────────────────────────────────────
//
// `run_watchdog()` emits `{check, detail}` pairs whose `detail` is written for
// whoever wrote the SQL: "newest route price is from 2026-08-21 04:17:03+00".
// True, and useless at a glance. This table turns each check into a group, a
// severity, one plain-English sentence and the thing to actually do.
//
// A check missing from here is NOT an error — it falls back to group Jobs, 🟡,
// and the raw detail. That is deliberate: a new SQL check must never be
// swallowed because nobody remembered to write its copy. It just reads plainer
// once someone does.

export type WatchdogGroup = "Money" | "Jobs" | "Lines" | "Delivery";

export interface WatchdogCopy {
  group: WatchdogGroup;
  sev: Severity;
  /** Turns the SQL detail into the operator-facing sentence. */
  what: (detail: string) => string;
  action: string;
}

const raw = (d: string) => esc(d);

export const WATCHDOG_COPY: Record<string, WatchdogCopy> = {
  // ── Jobs: a scheduled job stopped running. ────────────────────────────────
  "poll-active-orders": {
    group: "Jobs", sev: "🔴",
    what: (d) => `The minutely poller is not running. ${esc(d)}`,
    action: "Codes are not being delivered and expired orders are not being refunded — check the relay-poll-active-orders cron and the function logs.",
  },
  "sync-prices": {
    group: "Jobs", sev: "🟠",
    what: (d) => `Route prices are stale. ${esc(d)}`,
    action: "Check relay-sync-prices; stale wholesale means orders fail the margin gate after charging.",
  },
  "sync-5sim": {
    group: "Jobs", sev: "🟠",
    what: (d) => `5sim wholesale costs are stale. ${esc(d)}`,
    action: "Check relay-sync-5sim — a stale cost passes the margin gate and the reservation then fails.",
  },
  "sync-esim-plans": {
    group: "Jobs", sev: "🟡",
    what: (d) => `The eSIM catalog has not refreshed. ${esc(d)}`,
    action: "Check relay-sync-esim-plans (skipped while the line is paused).",
  },
  "telegram-digest": {
    group: "Jobs", sev: "🟠",
    what: (d) => `The 6-hourly digest has not been sent. ${esc(d)}`,
    action: "telegram-notify may be dead — digest silence is the only backstop for it, so treat this as the alert channel itself failing.",
  },
  "sync-smspva-operators": {
    group: "Jobs", sev: "🟡",
    what: (d) => `The SMSPVA premium-carrier sync is stale. ${esc(d)}`,
    action: "SMSPVA is retired — if this is firing, app_config.smspva_retired is not set to 'true'.",
  },
  "sync-smspva-conversions": {
    group: "Jobs", sev: "🟡",
    what: (d) => `The SMSPVA conversion-grade sync is stale. ${esc(d)}`,
    action: "SMSPVA is retired — if this is firing, app_config.smspva_retired is not set to 'true'.",
  },
  "winback": {
    group: "Jobs", sev: "🟡",
    what: (d) => `The daily winback nudge has not run. ${esc(d)}`,
    action: "Check relay-winback; it is cron-gated and must ship --no-verify-jwt.",
  },
  "daily-credit": {
    group: "Jobs", sev: "🟡",
    what: (d) => `The daily-credit grant has not run. ${esc(d)}`,
    action: "This should only fire while app_config.daily_credit_enabled is true — the grant is meant to be off.",
  },
  "expire-esim-orders": {
    group: "Jobs", sev: "🟠",
    what: (d) => `Expired eSIM orders are not being swept. ${esc(d)}`,
    action: "Check the expire-esim-orders pg_cron job — paid orders are not being closed or refunded.",
  },
  "expire-email-orders": {
    group: "Jobs", sev: "🟠",
    what: (d) => `Expired e-mail orders are not being swept. ${esc(d)}`,
    action: "Check the expire-email-orders pg_cron job — paid addresses are not being refunded.",
  },
  "apns": {
    group: "Jobs", sev: "🟠",
    what: (d) => `Push delivery is failing. ${esc(d)}`,
    action: "Check the APNs key and aps-environment — a delivered code reaches nobody while this is broken.",
  },
  "relay-http": {
    group: "Jobs", sev: "🟠",
    what: (d) => `Cron relays are returning errors. ${esc(d)}`,
    action: "Usually CRON_SECRET drift between the edge secret and the vault entry — rotate both together, or a function was redeployed without --no-verify-jwt.",
  },
  watchdog_stale: {
    group: "Jobs", sev: "🔴",
    what: (d) => `The watchdog itself has stopped. ${esc(d)}`,
    action: "Every other check on this list is now meaningless — check the pg_cron 'watchdog' job first.",
  },

  // ── Delivery: the SMS product is not delivering. ──────────────────────────
  "delivery-collapse": {
    group: "Delivery", sev: "🔴",
    what: (d) => `SMS delivery has collapsed. ${esc(d)}`,
    action: "Check provider float and /delivery — uncancelled orders are getting no codes at all.",
  },
  "delivery-degraded": {
    group: "Delivery", sev: "🟠",
    what: (d) => `SMS delivery is well below baseline. ${esc(d)}`,
    action: "Compare per-provider rates with /delivery; the baseline on settled orders is ~73%.",
  },

  // ── Lines: the rented second-number product. ─────────────────────────────
  "reclaim-lapsed-lines": {
    group: "Lines", sev: "🔴",
    what: (d) => `Lapsed numbers are not being reclaimed. ${esc(d)}`,
    action: "We pay rent per number, per month, forever until this drains — check the reclaim-lapsed-lines pg_cron job.",
  },
  "release-lines": {
    group: "Lines", sev: "🔴",
    what: (d) => `Numbers are stuck in 'releasing'. ${esc(d)}`,
    action: "Each one is still billing at Telnyx — check relay-release-lines and the Telnyx API key.",
  },
  "line-provisioning-stuck": {
    group: "Lines", sev: "🟠",
    what: (d) => `Line provisioning is stuck. ${esc(d)}`,
    action: "A stuck row also bars that user from renting again (one-live-line index) — resolve or release it by hand.",
  },
  "sync-telnyx-cdr": {
    group: "Lines", sev: "🟠",
    what: (d) => `Call minutes are not being settled. ${esc(d)}`,
    action: "Check relay-sync-telnyx-cdr — without a CDR every call bills its full reservation via the 6h backstop.",
  },
  "telnyx-webhook": {
    group: "Lines", sev: "🔴",
    what: (d) => `Telnyx webhooks are being rejected. ${esc(d)}`,
    action: "Inbound texts may be dropped — check the Telnyx public signing key against TELNYX_PUBLIC_KEY.",
  },
  "apple-line-lapse": {
    group: "Lines", sev: "🔴",
    what: (d) => `Apple-billed lines are live past their paid period. ${esc(d)}`,
    action: "No EXPIRED notification arrived and the reclaim backstop did not fire — we are paying rent on a cancelled subscription.",
  },
  "unreleased-line-numbers": {
    group: "Lines", sev: "🔴",
    what: (d) => `Deleted accounts left Telnyx numbers behind. ${esc(d)}`,
    action: "Release them by hand at Telnyx, then clear app_config.unreleased_line_numbers — nothing else can name them.",
  },

  // ── Money: float and rent. ───────────────────────────────────────────────
  "5sim-float": {
    group: "Money", sev: "🟠",
    what: (d) => `5sim float is running out. ${esc(d)}`,
    action: "Top up 5sim — at zero every order is refused as provider_unreachable.",
  },
  "herosms-float": {
    group: "Money", sev: "🟠",
    what: (d) => `HeroSMS float is running out. ${esc(d)}`,
    action: "Top up HeroSMS — it funds SMS routes AND the whole temp-e-mail line.",
  },
  "debit-credit-lines": {
    group: "Money", sev: "🔴",
    what: (d) => `Credit-billed line rent is not being charged. ${esc(d)}`,
    action: "Those numbers are running free at the provider — check the rent sweep and app_config.line_rent_heartbeat.",
  },
};

/** `{provider}-float` is generated per provider in SQL, so a provider added
 *  later has no entry above. Fall back to the same Money/🟠 shape rather than
 *  to the generic Jobs default. */
function copyFor(check: string): WatchdogCopy {
  const known = WATCHDOG_COPY[check];
  if (known) return known;
  if (check.endsWith("-float")) {
    const p = check.slice(0, -"-float".length);
    return {
      group: "Money", sev: "🟠",
      what: (d) => `${esc(p)} float is running out. ${esc(d)}`,
      action: `Top up ${esc(p)} — at zero every order on it is refused.`,
    };
  }
  return {
    group: "Jobs", sev: "🟡",
    what: raw,
    action: "No copy for this check yet — add it to WATCHDOG_COPY in _shared/tgAlert.ts.",
  };
}

const SEV_RANK: Record<Severity, number> = { "🔴": 4, "🟠": 3, "🟡": 2, "🟢": 1, "ℹ️": 0 };
const GROUP_ORDER: WatchdogGroup[] = ["Money", "Delivery", "Lines", "Jobs"];

export interface FailingCheck { check?: string; detail?: string }

/**
 * The watchdog page: one message, grouped Money → Delivery → Lines → Jobs,
 * headline severity = the worst individual check.
 *
 * `sinceMap` carries when each check first entered the failing set (from the
 * SEPARATE `app_config.watchdog_since` key — NOT a field on the `watchdog`
 * value, which `run_watchdog` rebuilds from scratch every 10 minutes and would
 * therefore drop), so a re-alert can say how long it has been broken
 * rather than repeating the same paragraph every six hours. Missing entries are
 * simply omitted — an unknown duration must never be rendered as "0m".
 */
export function formatWatchdogPage(
  failing: FailingCheck[],
  opts: { sinceMap?: Record<string, string>; now?: Date } = {},
): string {
  const now = opts.now ?? new Date();
  const sinceMap = opts.sinceMap ?? {};
  const items = failing.map((f) => {
    const name = f.check ?? "?";
    return { name, detail: f.detail ?? "", copy: copyFor(name) };
  });

  const worst = items.reduce<Severity>(
    (acc, it) => (SEV_RANK[it.copy.sev] > SEV_RANK[acc] ? it.copy.sev : acc),
    "🟡",
  );

  const n = items.length;
  const byGroup = new Map<WatchdogGroup, typeof items>();
  for (const it of items) {
    const arr = byGroup.get(it.copy.group) ?? [];
    arr.push(it);
    byGroup.set(it.copy.group, arr);
  }

  const blocks: string[] = [];
  for (const g of GROUP_ORDER) {
    const arr = byGroup.get(g);
    if (!arr || arr.length === 0) continue;
    const lines = [`<b>${g}</b>`];
    for (const it of arr) {
      const since = sinceMap[it.name];
      const dur = since ? ` <i>(${downFor(since, now)})</i>` : "";
      lines.push(`${it.copy.sev} <b>${esc(it.name)}</b>${dur}`);
      lines.push(`  ${it.copy.what(it.detail)}`);
      lines.push(`  → ${it.copy.action}`);
    }
    blocks.push(lines.join("\n"));
  }

  return [
    `${worst} <b>Watchdog: ${n} check${n === 1 ? "" : "s"} failing</b>`,
    "",
    blocks.join("\n\n"),
    "",
    "<i>runbook: docs/autopilot-runbook.md</i>",
    `🕒 ${parisFull(now)} Paris`,
  ].join("\n");
}

/** "down 2h 14m" from an ISO timestamp. */
function downFor(sinceIso: string, now: Date): string {
  const t = new Date(sinceIso).getTime();
  if (!Number.isFinite(t)) return "";
  const s = Math.max(0, (now.getTime() - t) / 1000);
  const m = Math.floor(s / 60);
  if (m < 60) return `down ${m}m`;
  const h = Math.floor(m / 60);
  if (h < 24) return `down ${h}h ${String(m % 60).padStart(2, "0")}m`;
  return `down ${Math.floor(h / 24)}d ${h % 24}h`;
}

/**
 * The all-clear. It NAMES what recovered and how long each thing was down —
 * "all clear" on its own is not information, and after a 6-hourly re-alert
 * ladder the reader has usually lost track of what was failing in the first
 * place.
 *
 * `downFor` maps check name → the ISO time it started failing.
 */
export function formatWatchdogRecovered(
  recovered: string[],
  downForMap: Record<string, string> = {},
  now: Date = new Date(),
): string {
  const lines = recovered.map((c) => {
    const since = downForMap[c];
    const d = since ? ` — ${downFor(since, now)}` : "";
    return ` • <b>${esc(c)}</b>${d}`;
  });
  return alertHtml({
    sev: "🟢",
    title: `Watchdog: all clear (${recovered.length} recovered)`,
    what: lines.join("\n"),
    at: now,
  });
}
