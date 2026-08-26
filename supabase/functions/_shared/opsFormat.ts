// Rendering for every Telegram ops-bot reply. Shared by the 6-hourly digest
// (telegram-notify) and the on-demand commands (telegram-webhook) so the two
// can never disagree about what a number means.
//
// HOUSE STYLE (2026-08-21 overhaul). The owner reads this on a phone, in
// France, often at 1am:
//   line 1  = the answer — one bold headline carrying the verdict/number
//   middle  = compact sections, "·" as the separator
//   caveats = LAST, in <i>italics</i>
//   footer  = stamp() — every command reply ends with the Paris time it was
//             rendered, so a screenshot is never undatable.
// Every timestamp goes through tgFormat (Europe/Paris). Never format one any
// other way; until this overhaul the bot printed raw UTC ISO strings and bare
// HH:MM whose "UTC" existed only in a source comment.

import { esc } from "./telegram.ts";
import {
  ago, bar, duration, n, parisDay, parisFull, parisSmart, parisTime,
  pct as pctOf, ratio, stamp, until, usd,
} from "./tgFormat.ts";

// ── shared constants ────────────────────────────────────────────────────────

/** Roughly what a credit is worth in gross revenue, for a readable estimate
 *  only. The packs run $0.598/cr (5-pack) down to $0.333/cr (150-pack); this
 *  is deliberately the middle of that range and is never presented as exact
 *  (every figure derived from it is prefixed "~"). */
const USD_PER_CREDIT = 0.45;

/** Warn below ~5x the wholesale ceiling of a single order, matching the
 *  low-balance threshold poll-active-orders alerts on. Keep in lockstep with
 *  MAX_ORDER_COST_USD there — this said 20 while the pager fired at 37.50, so
 *  between the two the pager screamed and the owner's only standing view
 *  rendered the balance with no warning at all. */
const LOW_BALANCE_USD = 37.5;

/** What each provider currently pays for. Displayed next to the balance so a
 *  low reading is actionable ("which product just died?") rather than an
 *  anonymous number. */
const ROLE: Record<string, string> = {
  // 5sim serves every SMS order since the 2026-08-03 cutover. HeroSMS is NOT
  // retired — it runs the temp-EMAIL line on the same account and balance.
  "5sim": "SMS",
  herosms: "e-mail",
  // RETIRED 2026-08-17. Kept in this map ONLY so historical rows still render
  // with a name — labelled so a pre-cutover figure is never read as live.
  smspva: "retired",
  smspool: "retired",
  // Rent for the second-number line. $1 up front + $1/month per subscriber,
  // paid ~45 days ahead of Apple's payout, so this is a float number.
  telnyx: "second numbers",
  esimaccess: "eSIM",
};

/** Providers whose balance line is NOISE on a channel that has to stay
 *  readable: they serve nothing, so their reading can only ever be ignored.
 *  /balance already drops them; /delivery used to print them every time from a
 *  hardcoded CTE, so the two commands disagreed about which providers matter. */
const RETIRED_PROVIDERS = new Set(["smspva", "smspool", "virtualsms"]);

/** A balance reading is only a fact while the poller that wrote it is alive.
 *  "no reading" and "a 4-hour-old reading" are different problems and are said
 *  differently. (`/balance` in telegram-webhook carries its own copy of this
 *  window; keep the two numbers equal.) */
const BALANCE_FRESH_MS = 10 * 60 * 1000;

/** Low-water mark for the Telnyx float, SEPARATE from LOW_BALANCE_USD. The SMS
 *  threshold ($37.50) is sized to single-order wholesale that can reach tens of
 *  dollars; Telnyx rent is $1/number/month, so $37.50 would print a permanent
 *  "top up" and train the owner to ignore the one warning that matters. */
export const TELNYX_LOW_USD = 5;

/** Apple's commission. 15% is the Small Business Program rate (under $1M/yr);
 *  the standard rate is 30%. Deliberately a named constant, and the rate is
 *  PRINTED next to every figure derived from it so the number can never be
 *  read without its assumption. */
const APPLE_COMMISSION = 0.15;

/** FX into USD, used only to total a mixed-currency gross. A hand-set rate, not
 *  a live quote — an ops bot must not depend on a third-party FX API to answer
 *  "how much did I make". The rate used is printed next to the converted
 *  figure, and any currency missing from this map is listed UNCONVERTED rather
 *  than folded in at 1.0: silently treating 149 SEK as $149 overstates revenue
 *  10x, and a silently wrong total is worse than an obviously incomplete one. */
const FX_TO_USD: Record<string, number> = {
  USD: 1, EUR: 1.08, GBP: 1.27, CHF: 1.12, CAD: 0.73,
  AUD: 0.66, JPY: 0.0064, PLN: 0.25, SEK: 0.092, NOK: 0.091, DKK: 0.145,
};

/** List price of the Second Number subscription, per month, USA base. */
const LINE_PRICE_USD = 9.99;

/** Telegram hard-limits a message at 4096 chars. Cap every list well under that
 *  and SAY SO when rows are dropped — a silently truncated list reads as "that
 *  was everything". */
const MAX_ROWS = 30;

// ── small local helpers ─────────────────────────────────────────────────────

/** "+1 438 795 1134" for NANP; anything else is left exactly as it arrived
 *  (guessing a grouping for an unfamiliar numbering plan mangles it). */
function e164Pretty(v: unknown): string {
  const s = String(v ?? "").trim();
  const m = /^\+1(\d{3})(\d{3})(\d{4})$/.exec(s);
  return m ? `+1 ${m[1]} ${m[2]} ${m[3]}` : s;
}

/** e164 escaped and pretty, for direct interpolation. */
const num = (v: unknown) => esc(e164Pretty(v));

/** A list capped with an explicit "… and N more", never silently truncated. */
function capped<T>(rows: T[], max = MAX_ROWS): { shown: T[]; hidden: number } {
  return { shown: rows.slice(0, max), hidden: Math.max(0, rows.length - max) };
}

const arr = (v: unknown): Record<string, unknown>[] =>
  Array.isArray(v) ? v as Record<string, unknown>[] : [];
const obj = (v: unknown): Record<string, unknown> =>
  (v && typeof v === "object" && !Array.isArray(v)) ? v as Record<string, unknown> : {};
const num0 = (v: unknown): number => (typeof v === "number" && Number.isFinite(v)) ? v : 0;
const str = (v: unknown): string => (v == null ? "" : String(v));
/** Narrow an unknown JSONB field to something the tgFormat time helpers accept.
 *  Anything else becomes null, which every helper renders as an empty string —
 *  a malformed timestamp must never reach the reader as "Invalid Date". */
const ts = (v: unknown): string | number | Date | null =>
  (typeof v === "string" || typeof v === "number" || v instanceof Date) ? v : null;

/** Right-aligned money column inside a <pre> block. */
function row(label: string, amount: string, width = 20, col = 11): string {
  return esc(label.padEnd(width) + amount.padStart(col));
}

/** "Last 7 days", not "Last 168h". 168h/720h are exactly the windows nobody
 *  converts in their head. */
function windowWords(hours: number): string {
  if (hours < 1) return "Last hour";
  if (hours < 24) return `Last ${Math.round(hours)}h`;
  const days = Math.round(hours / 24);
  if (days === 1) return "Last 24h";
  if (days === 7) return "Last 7 days";
  if (days === 30 || days === 31) return "Last 30 days";
  return `Last ${days} days`;
}

export interface BalanceReading {
  provider?: string;
  balance_usd?: number | null;
  checked_at?: string | null;
}

/** balanceLine for a reading that carries its own timestamp. A stale reading is
 *  rendered as absent and SAID to be stale — never printed as current, which is
 *  how a dead poller produced confidently wrong "all is well" digests. */
export function balanceLineFrom(r: BalanceReading, lowUsd?: number): string {
  const name = r.provider ?? "?";
  const ageMs = r.checked_at ? Date.now() - new Date(r.checked_at).getTime() : Infinity;
  if (typeof r.balance_usd !== "number") return balanceLine(name, undefined, lowUsd);
  if (ageMs > BALANCE_FRESH_MS) {
    return `${balanceLine(name, undefined, lowUsd)} <i>(last read ` +
           `${esc(ago(ts(r.checked_at)))} — poller may be dead)</i>`;
  }
  return balanceLine(name, r.balance_usd, lowUsd);
}

export function balanceLine(
  name: string, amount: number | null | undefined,
  lowUsd: number = LOW_BALANCE_USD,
): string {
  const role = ROLE[name.toLowerCase()] ?? "";
  const label = `${esc(name)}${role ? ` (${role})` : ""}`;
  // A missing reading is not the same as a healthy one: if nothing has written
  // a balance we say so, rather than omitting the line and implying all is well.
  if (typeof amount !== "number") return `❔ ${label}: <i>no reading</i>`;
  const low = amount < lowUsd;
  return `${low ? "⚠️" : "💰"} ${label}: <b>${esc(usd(amount))}</b>` +
         (low ? " — <b>top up</b>" : "");
}

/** Balance plus runway, for /now. Runway is what turns a balance into a
 *  decision: "$3.23" means nothing, "~2 days" means top up tonight. */
function balanceRunwayLine(
  name: string, b: Record<string, unknown>, lowUsd?: number,
): string {
  const base = balanceLineFrom({
    provider: name,
    balance_usd: typeof b.usd === "number" ? b.usd : (b.balance_usd as number | null),
    checked_at: (b.checked_at as string | null) ?? null,
  }, lowUsd);
  const days = b.runway_days;
  if (typeof days !== "number" || !Number.isFinite(days)) return base;
  const warn = days < 3 ? " ⚠️" : "";
  const shown = days >= 10 ? `${Math.round(days)}` : `${days.toFixed(1)}`;
  return `${base} · ~${esc(shown)} days${warn}`;
}


// ── /revenue and /profit ────────────────────────────────────────────────────

interface CurrencyRow { currency?: string; gross_milli?: number; count?: number }
interface ProductRow { product?: string; count?: number; credits?: number }

interface RevenueSnapshot {
  lifetime?: boolean;
  window_hours?: number | null;
  revenue?: {
    by_currency?: CurrencyRow[]; by_product?: ProductRow[];
    purchases?: number; buyers?: number; credits?: number; unpriced?: number;
  };
  cost?: {
    sms_cents?: number; sms_tracked?: number; sms_untracked?: number;
    esim_cents?: number; esim_tracked?: number; esim_untracked?: number;
    dev_cents?: number;
  };
}

interface LinesMoney {
  by_currency?: CurrencyRow[];
  /** Paid events in the window: first charges PLUS renewals. Derived from the
   *  notification stream, never from line_subscriptions — that table holds one
   *  row per subscription, so a renewal updates it instead of adding, and
   *  summing it would silently drop the entire renewal history. */
  payments?: number;
  first_buys?: number;
  renewals?: number;
  trials?: number;
  active?: number;
  renewing?: number;
  mrr_milli?: number;
  mrr_currency?: string | null;
  numbers_live?: number;
  rent_run_rate_cents?: number;
  credit_rented?: number;
}

function periodLabel(s: RevenueSnapshot): string {
  if (s.lifetime) return "lifetime";
  const h = s.window_hours ?? 0;
  if (h <= 24) return `last ${Math.round(h)}h`;
  const d = Math.round(h / 24);
  return d === 7 ? "last 7 days" : d === 30 ? "last 30 days" : `last ${d} days`;
}

/** Convert a per-currency list to USD, collecting the native amounts and any
 *  currency we have no rate for. Never folds an unknown currency in at 1.0 —
 *  silently treating 149 SEK as $149 overstates revenue 10x, and a silently
 *  wrong total is worse than an obviously incomplete one. */
function convert(
  rows: CurrencyRow[] | undefined, native: string[], unconverted: string[],
): number {
  let total = 0;
  for (const cur of rows ?? []) {
    const code = (cur.currency ?? "?").toUpperCase();
    const amount = (cur.gross_milli ?? 0) / 1000;   // Apple prices are milliunits
    native.push(`${esc(code)} ${amount.toFixed(2)}`);
    const rate = FX_TO_USD[code];
    if (rate == null) unconverted.push(`${esc(code)} ${amount.toFixed(2)}`);
    else total += amount * rate;
  }
  return total;
}

/** `/revenue` — what customers actually PAID, in USD. Nothing derived.
 *
 *  Deliberately separate from formatRevenue (`/profit`), which nets off Apple's
 *  cut and provider wholesale to reach a profit figure. Those are estimates
 *  built on a fixed 15% commission and partially-recorded costs; this is not.
 *  Every number here is the price Apple reports for the transaction.
 *
 *  ⚠️ Does NOT end with stamp(): the caller appends formatLinesMoney() after
 *  it, so the footer would land mid-message. formatLinesMoney carries the stamp
 *  for this pair. */
export function formatGross(
  raw: Record<string, unknown>,
  linesRaw?: Record<string, unknown> | null,
): string {
  const s = (raw ?? {}) as RevenueSnapshot;
  const r = s.revenue ?? {};
  const native: string[] = [];
  const unconverted: string[] = [];

  const grossUsd = convert(r.by_currency, native, unconverted);
  // 🔴 SUBSCRIPTION MONEY IS REVENUE AND BELONGS IN THE HEADLINE. It used to sit
  // in a block below, so the big number at the top was wrong — a $9.99
  // subscription is $9.99 taken, exactly like a credit pack, and a renewal is
  // another $9.99.
  const lm = (linesRaw ?? {}) as LinesMoney;
  const subsUsd = convert(lm.by_currency, [], unconverted);
  const subPayments = lm.payments ?? 0;
  const purchases = r.purchases ?? 0;

  if (purchases === 0 && subPayments === 0) {
    return `💵 <b>No money in — ${esc(periodLabel(s))}</b>`;
  }

  const lines: string[] = [];
  lines.push(`💵 <b>${esc(usd(grossUsd + subsUsd))} taken — ${esc(periodLabel(s))}</b>`);
  lines.push("");
  // The split, so the headline is auditable rather than asserted — and so
  // "how much of this recurs" is answerable at a glance.
  if (subPayments > 0) {
    lines.push(`${esc(usd(grossUsd))} credits · ${esc(usd(subsUsd))} subscriptions`);
  }
  lines.push(`${esc(purchases + subPayments)} payments · ` +
             `${esc(r.buyers ?? 0)} buyers · ${esc(r.credits ?? 0)} credits`);

  const packs = (r.by_product ?? [])
    .map((p) => `${esc(p.product ?? "?")} ×${esc(p.count ?? 0)}`).join(" · ");
  if (packs) lines.push(`📦 ${packs}`);

  // Always show what was actually billed, so the USD figure is auditable rather
  // than a number the bot asserts — and print the FX rate beside it.
  if (native.length) {
    lines.push(`💱 ${native.join(" + ")}` +
               (native.length > 1 ? ` <i>@ EUR ${esc(FX_TO_USD.EUR)}</i>` : ""));
  }
  if (unconverted.length) {
    lines.push(`⚠️ <b>NOT included</b> (no FX rate): ${unconverted.join(" + ")}`);
  }
  if ((r.unpriced ?? 0) > 0) {
    lines.push(`<i>⚠️ ${esc(r.unpriced)} receipt(s) had no readable price — ` +
               `gross is understated.</i>`);
  }

  return lines.join("\n");
}

/** `/profit` — the P&L. Leads with the MARGIN, because "how are we doing" is a
 *  percentage, not a fourteen-line financial statement; the statement follows
 *  for anyone who wants to audit it.
 *
 *  ⚠️ Does NOT end with stamp() — see formatGross. */
export function formatRevenue(
  raw: Record<string, unknown>,
  linesRaw?: Record<string, unknown> | null,
): string {
  const s = (raw ?? {}) as RevenueSnapshot;
  const r = s.revenue ?? {};
  const c = s.cost ?? {};
  const native: string[] = [];
  const unconverted: string[] = [];

  const grossUsd = convert(r.by_currency, native, unconverted);
  // Apple takes its cut of a subscription exactly as it does of a credit pack.
  // Counted per PAYMENT EVENT, so renewals accumulate.
  const lm = (linesRaw ?? {}) as LinesMoney;
  const subsUsd = convert(lm.by_currency, [], unconverted);
  const subPayments = lm.payments ?? 0;
  const purchases = r.purchases ?? 0;

  if (purchases === 0 && subPayments === 0) {
    return `💵 <b>No money in — ${esc(periodLabel(s))}</b>`;
  }

  const totalGross = grossUsd + subsUsd;
  const commission = totalGross * APPLE_COMMISSION;
  const net = totalGross - commission;
  const smsUsd = (c.sms_cents ?? 0) / 100;
  const esimUsd = (c.esim_cents ?? 0) / 100;
  const devUsd = (c.dev_cents ?? 0) / 100;
  // Telnyx rent for the numbers we hold. A RUN RATE — we cannot confirm from
  // here what was actually charged — so it is shown but NOT subtracted.
  // Folding an unverified cost into a P&L is how a profit figure becomes
  // something you cannot defend.
  const rentUsd = (lm.rent_run_rate_cents ?? 0) / 100;
  const profit = net - smsUsd - esimUsd - devUsd;
  const margin = totalGross > 0 ? Math.round((profit / totalGross) * 100) : 0;
  const untracked = (c.sms_untracked ?? 0) + (c.esim_untracked ?? 0);

  const lines: string[] = [];
  lines.push(`${profit >= 0 ? "📈" : "📉"} <b>${esc(margin)}% margin · ` +
             `${esc(usd(profit))} profit — ${esc(periodLabel(s))}</b>`);
  // An upper bound must be flagged WHERE THE NUMBER IS, not in a footnote
  // nobody scrolls to.
  if (untracked > 0) {
    lines.push(`<i>upper bound — ${esc(untracked)} order(s) have no recorded cost</i>`);
  }
  lines.push("");
  lines.push("<pre>");
  lines.push(row("Gross", usd(totalGross)));
  if (subPayments > 0) {
    lines.push(row("  credits", usd(grossUsd)));
    lines.push(row("  subscriptions", usd(subsUsd)));
  }
  lines.push(row(`Apple (${Math.round(APPLE_COMMISSION * 100)}%)`, usd(-commission)));
  lines.push(esc("".padEnd(20) + "-----------"));
  lines.push(row("Net revenue", usd(net)));
  lines.push("");
  lines.push(row("SMS wholesale", usd(-smsUsd)));
  lines.push(row("eSIM wholesale", usd(-esimUsd)));
  if (devUsd > 0) lines.push(row("Test/dev orders", usd(-devUsd)));
  lines.push(esc("".padEnd(20) + "-----------"));
  lines.push(row("PROFIT", usd(profit)));
  lines.push("</pre>");

  lines.push(`${esc(purchases + subPayments)} payments · ` +
             `${esc(r.buyers ?? 0)} buyers · ${esc(r.credits ?? 0)} credits`);
  if (native.length > 1) {
    lines.push(`💱 ${native.join(" + ")} <i>@ EUR ${esc(FX_TO_USD.EUR)}</i>`);
  }
  const packs = (r.by_product ?? [])
    .map((p) => `${esc(p.product ?? "?")} ×${esc(p.count ?? 0)}`).join(" · ");
  if (packs) lines.push(`📦 ${packs}`);

  // Caveats LAST, italic. Each of these makes the profit figure an
  // OVERSTATEMENT, so they are warnings, not footnotes. The commission rate is
  // printed so the margin can never be read without its assumption.
  const warn: string[] = [
    `<i>Apple ${Math.round(APPLE_COMMISSION * 100)}% assumes the Small Business ` +
    `Program — the standard rate is 30%.</i>`,
  ];
  if (rentUsd > 0) {
    warn.push(`<i>Excludes Telnyx number rent, ~${esc(usd(rentUsd))}/mo — a run ` +
              `rate we cannot confirm was charged.</i>`);
  }
  if (untracked > 0) {
    warn.push(`<i>⚠️ ${esc(untracked)} order(s) held a number but have no recorded ` +
              `cost (tracking began 13 Jul) — real spend is higher.</i>`);
  }
  if ((r.unpriced ?? 0) > 0) {
    warn.push(`<i>⚠️ ${esc(r.unpriced)} receipt(s) had no readable price — gross is ` +
              `understated.</i>`);
  }
  if (unconverted.length > 0) {
    warn.push(`<i>⚠️ NOT converted (no FX rate): ${unconverted.join(", ")}</i>`);
  }
  lines.push("");
  lines.push(...warn);

  return lines.join("\n");
}

/** The line's money, appended to `/revenue` and `/profit`.
 *
 *  ⚠️ COLLECTED AND RECURRING ARE REPORTED SEPARATELY, and that separation is
 *  the whole point. Every subscriber so far switched auto-renew off within
 *  minutes of paying, so "collected $19.98" without "renews: $0" would be true
 *  and badly misleading.
 *
 *  This is the TAIL of the /revenue and /profit replies, so it is the piece
 *  that carries stamp() for that pair. */
export function formatLinesMoney(raw: Record<string, unknown>): string {
  const s = (raw ?? {}) as LinesMoney;
  const active = s.active ?? 0;
  const trials = s.trials ?? 0;
  const payments = s.payments ?? 0;
  const numbers = s.numbers_live ?? 0;

  if (active === 0 && payments === 0 && numbers === 0) {
    return `\n\n📞 <b>Second numbers</b> — nothing sold yet.\n\n${stamp()}`;
  }

  const out = ["", "", "📞 <b>Second numbers</b>"];
  if (payments > 0) {
    out.push(`Payments: <b>${esc(payments)}</b> — ${esc(s.first_buys ?? 0)} new · ` +
             `${esc(n("renewal", s.renewals ?? 0))}`);
  }

  // The number the owner actually needs. A subscription that will not renew is
  // a one-off sale wearing a subscription's clothes.
  const mrr = (s.mrr_milli ?? 0) / 1000;
  const renewing = s.renewing ?? 0;
  if (renewing === 0) {
    out.push(`Recurring: <b>$0.00</b> — none of the ${esc(active)} active ` +
             `sub${active === 1 ? "" : "s"} will renew`);
  } else {
    const cur = (s.mrr_currency ?? "USD").toUpperCase();
    out.push(`Recurring: <b>${esc(usd(mrr * (FX_TO_USD[cur] ?? 1)))}/mo</b> ` +
             `from ${esc(renewing)} renewing`);
  }
  if (trials > 0) {
    out.push(`<i>${esc(n("free trial", trials))} — paid nothing yet · see /trials</i>`);
  }

  // Cost, stated as a RUN RATE, never folded into a profit figure.
  if (numbers > 0) {
    const credit = s.credit_rented ?? 0;
    const suffix = credit > 0 ? ` (${esc(credit)} rented with credits)` : "";
    out.push(`Numbers live: <b>${esc(numbers)}</b>${suffix} · ` +
             `rent <b>${esc(usd((s.rent_run_rate_cents ?? 0) / 100))}/mo</b>`);
  }
  out.push("");
  out.push(stamp());
  return out.join("\n");
}

// ── /stats, /today, /week (and the 6-hourly digest) ─────────────────────────

interface ProviderRow {
  provider?: string;
  placed?: number;
  /** The rate cohort: numbered, not cancelled, not default-landed. */
  settled?: number;
  received?: number;
  failed?: number;
  cancelled?: number;
  pct?: number | null;
}

interface Snapshot {
  window_hours?: number;
  signups?: number;
  purchases?: {
    count?: number; credits?: number;
    /** Sandbox/Xcode receipts. Apple-signed, genuine, worth $0 — counted as
     *  sales here until 2026-08-08. Excluded from `count` and reported on
     *  their own line, because several in one window means somebody switched
     *  their Apple ID to Sandbox and is taking packs for free. */
    sandbox?: number;
  };
  orders?: {
    /** Orders that actually reserved a number. */
    placed?: number;
    /** THE RATE DENOMINATOR: numbered AND not cancelled by the user AND not
     *  landed on the app's own pre-selection. Cancels measure impatience (they
     *  land at a median 57s against a median 58s arrival and deliver ~1%), and
     *  a default-landed order measures our steering — the user never chose that
     *  service and never entered the number anywhere. */
    settled?: number;
    received?: number; failed?: number; pct?: number | null;
    cancelled?: number;
    /** Codes that arrived AFTER a cancel. The refund stands and the code is
     *  given away free, so it is a delivery we made and deliberately not part
     *  of the rate. */
    rescued?: number;
    waiting?: number;
    default_landed?: number;
    /** Charged-and-refunded attempts that never reserved a number. Excluded
     *  from `placed` so they cannot masquerade as delivery failures. */
    numberless?: number;
    /** Dev-account orders. Excluded from every figure here, as always —
     *  reported so an empty Numbers line can say why it is empty rather than
     *  reading as "the product is dead". */
    dev_hidden?: number;
    by_provider?: ProviderRow[];
  };
  /** Temp-EMAIL line. Same evidence shape as `orders`: `placed` counts only
   *  orders that got a usable mailbox, `settled` is the rate cohort, and
   *  `unprovisioned` is reported separately for the same reason `numberless`
   *  is — it is not a delivery failure. */
  emails?: {
    placed?: number; settled?: number; received?: number; failed?: number;
    pct?: number | null; cancelled?: number;
    unprovisioned?: number; free?: number; credits?: number;
  };
  esims?: { count?: number; credits?: number };
  herosms_usd?: number | null;
  fivesim_usd?: number | null;
}

/** `/stats` `/today` `/week` and the 6-hourly digest.
 *
 *  HEADLINE FIRST: delivery rate, purchases and money on line 1. The old
 *  version buried "9 of 14 delivered" six lines down under signups and
 *  caveats — it is the one number the owner opens this for.
 *
 *  Two money concepts stay APART, and the caveat line says so: credit revenue
 *  here is an ESTIMATE (ops_snapshot counts credits, not receipts, so it is
 *  credits × a mid-range USD_PER_CREDIT and wears a "~"), while subscription
 *  revenue is EXACT, read from the signed price on each payment event. Adding
 *  an exact figure to an estimate and printing one total would launder the
 *  approximation into something that looks precise. */
export function formatDigest(
  raw: Record<string, unknown>,
  linesRaw?: Record<string, unknown> | null,
): string {
  const s = (raw ?? {}) as Snapshot;
  const hours = s.window_hours ?? 6;
  const o = s.orders ?? {};
  const m = s.emails ?? {};
  const e = s.esims ?? {};
  const buys = s.purchases ?? {};
  const lm = (linesRaw ?? {}) as LinesMoney;

  const placed = o.placed ?? 0;
  const settled = o.settled ?? 0;
  const received = o.received ?? 0;
  const purchases = buys.count ?? 0;
  const credits = buys.credits ?? 0;
  const subPayments = lm.payments ?? 0;
  let subUsd = 0;
  for (const cur of lm.by_currency ?? []) {
    const rate = FX_TO_USD[(cur.currency ?? "?").toUpperCase()];
    if (rate != null) subUsd += ((cur.gross_milli ?? 0) / 1000) * rate;
  }
  const creditUsd = credits * USD_PER_CREDIT;

  // ── line 1: the answer ────────────────────────────────────────────────────
  const head: string[] = [];
  if (settled > 0) head.push(`${esc(ratio(received, settled))} delivered`);
  else if (placed > 0) head.push(`${esc(placed)} numbered, none settled`);
  const paying = purchases + subPayments;
  if (paying > 0) {
    head.push(esc(n("payment", paying)));
    const money = creditUsd + subUsd;
    // "~" because the credit half is an estimate. Never dropped.
    head.push(`${credits > 0 ? "~" : ""}${esc(usd(money))}`);
  }
  if (head.length === 0) {
    head.push((s.signups ?? 0) > 0
      ? `quiet — ${esc(n("signup", s.signups ?? 0))}, no orders`
      : "nothing happened");
  }

  const lines: string[] = [];
  lines.push(`📊 <b>${esc(windowWords(hours))} — ${head.join(" · ")}</b>`);
  lines.push("");

  // ── activity, one product per line ────────────────────────────────────────
  if (placed > 0) {
    const rateBit = settled > 0
      ? `✅ ${esc(ratio(received, settled))} ${esc(bar(received / settled))}`
      : `⏳ nothing settled yet`;
    lines.push(`📱 <b>Numbers</b> ${esc(placed)} numbered · ${rateBit}`);
    // ⚠️ NO SUBTRACTED COUNT. `placed - settled` looks like it should equal the
    // cancelled + app-picked figures and does not — an order can be both, so
    // the categories overlap and the arithmetic visibly fails. Name the
    // reasons, never a number the reader can try to reconcile and can't.
    const bits: string[] = [];
    if ((o.cancelled ?? 0) > 0) bits.push(`✖ ${o.cancelled} cancelled`);
    if ((o.waiting ?? 0) > 0) bits.push(`⏳ ${o.waiting} waiting`);
    // A delivery we made that is deliberately outside the rate: the refund
    // stood and the code was given away free.
    if ((o.rescued ?? 0) > 0) bits.push(`🎁 ${o.rescued} rescued`);
    // The app's own pre-selection. Settled by hand 2026-08-04: a cancelled
    // deliveroo/us number was used manually and the code arrived, so these say
    // nothing about delivery — nobody ever submitted the number.
    if ((o.default_landed ?? 0) > 0) bits.push(`↩︎ ${o.default_landed} app-picked`);
    // Charged and instantly refunded: price cleared the ceiling, route dry, or
    // the provider errored. NOT delivery failures, but they must be visible —
    // a provider drifting above our margin gate produces them in volume and it
    // looks like nothing at all.
    if ((o.numberless ?? 0) > 0) bits.push(`⚠️ ${o.numberless} never got a number`);
    if (bits.length) lines.push(`   ${bits.join(" · ")}`);

    // Only worth the extra lines when providers actually differ — a blended
    // rate averages a dead provider with a live one and describes neither.
    const rows = (o.by_provider ?? []).filter((p) => (p.placed ?? 0) > 0);
    if (rows.length > 1) {
      lines.push(`   <i>` + rows.map((p) => {
        const st = p.settled ?? 0;
        return `${esc(p.provider ?? "?")} ` +
               (st > 0 ? esc(ratio(p.received ?? 0, st)) : `${p.placed ?? 0} numbered`);
      }).join(" · ") + `</i>`);
    }
  } else {
    // Say WHY it is empty when the dev account was the only thing ordering.
    // Reported 2026-08-05 as "I see people ordering numbers yet I don't see
    // that on the telegram stats" — it was one dev order behaving correctly.
    const dev = o.dev_hidden ?? 0;
    lines.push(`📱 <b>Numbers</b> none ordered` +
               (dev > 0 ? ` · <i>${esc(n("dev order", dev))} hidden</i>` : ""));
  }
  // dev_hidden is now stated whenever it is non-zero, not only on an empty
  // window: the dev account ordering alongside real customers used to be
  // completely invisible.
  if (placed > 0 && (o.dev_hidden ?? 0) > 0) {
    lines.push(`   <i>${esc(n("dev order", o.dev_hidden ?? 0))} hidden from every figure</i>`);
  }

  const mailPlaced = m.placed ?? 0;
  const unprovisioned = m.unprovisioned ?? 0;
  if (mailPlaced > 0 || unprovisioned > 0) {
    // `free` is always shown when non-zero: 28 of the first 29 orders were the
    // free tier, so an order count alone reads as revenue when it is nearly
    // all cost.
    const freeNote = (m.free ?? 0) > 0 ? ` (${esc(m.free ?? 0)} free)` : "";
    const mailSettled = m.settled ?? 0;
    const rateBit = mailSettled > 0
      ? ` · ✅ ${esc(ratio(m.received ?? 0, mailSettled))}`
      : ` · ⏳ nothing settled yet`;
    lines.push(`📧 <b>E-mails</b> ${esc(mailPlaced)} ordered${freeNote}${rateBit}`);
    const mb: string[] = [];
    if ((m.cancelled ?? 0) > 0) mb.push(`✖ ${m.cancelled} cancelled`);
    // The mailbox was never issued — the e-mail analogue of a numberless SMS
    // order, deliberately outside the rate. Five in one 7-minute burst is what
    // exposed the free tier running dry.
    if (unprovisioned > 0) mb.push(`⚠️ ${unprovisioned} never got an address`);
    if (mb.length) lines.push(`   ${mb.join(" · ")}`);
  } else {
    lines.push(`📧 <b>E-mails</b> none ordered`);
  }

  if ((e.count ?? 0) > 0) {
    lines.push(`🌍 <b>eSIMs</b> ${esc(e.count ?? 0)} sold · ${esc(e.credits ?? 0)} credits`);
  }

  // ── money and people ──────────────────────────────────────────────────────
  lines.push("");
  const money: string[] = [`👤 ${esc(n("signup", s.signups ?? 0))}`];
  money.push(purchases > 0
    ? `💳 ${esc(n("purchase", purchases))} · ${esc(credits)} cr ~${esc(usd(creditUsd))}`
    : `💳 no purchases`);
  lines.push(money.join(" · "));
  if ((buys.sandbox ?? 0) > 0) {
    lines.push(`   ⚠️ ${esc(buys.sandbox ?? 0)} Sandbox receipt(s) — $0 paid, not counted`);
  }
  if (subPayments > 0) {
    const renewals = lm.renewals ?? 0;
    lines.push(`📞 ${esc(n("subscription payment", subPayments))} · ` +
               `<b>${esc(usd(subUsd))}</b>` +
               (renewals > 0 ? ` · ${esc(n("renewal", renewals))}` : ""));
  }
  // A free trial takes no money but DOES rent a number — a cost with no
  // revenue, invisible if only paid events were reported.
  if ((lm.trials ?? 0) > 0) {
    lines.push(`   <i>${esc(n("free trial", lm.trials ?? 0))} — $0 · see /trials</i>`);
  }

  // ── float ─────────────────────────────────────────────────────────────────
  lines.push("");
  lines.push(balanceLine("5sim", s.fivesim_usd));
  lines.push(balanceLine("HeroSMS", s.herosms_usd));

  // ── caveats, last and italic ──────────────────────────────────────────────
  lines.push("");
  if (settled > 0 && placed > settled) {
    lines.push(`<i>Rate is over settled orders — cancels and app-picked ` +
               `numbers aren't judged.</i>`);
  }
  if (credits > 0) {
    lines.push(`<i>Credit money is an estimate at ~$${USD_PER_CREDIT.toFixed(2)}/credit; ` +
               `subscription money is exact.</i>`);
  }
  lines.push(stamp());
  return lines.join("\n");
}

// ── /orders ─────────────────────────────────────────────────────────────────

interface OrderRow {
  created_at?: string;
  status?: string;
  service_id?: string;
  country_id?: string;
  provider?: string;
  tier?: string;
  cost_credits?: number;
  actual_cost_cents?: number | null;
  got_code?: boolean;
  got_number?: boolean;
  from_default?: boolean;
  is_dev?: boolean;
  held_s?: number;
}

/** Time for a list row: bare Paris time when it happened today, the fuller
 *  "Sat 22 Aug, 01:16" otherwise. Bare HH:MM on a row from three days ago is
 *  the same mislabelling problem as bare UTC. */
function rowTime(v: unknown, now: Date = new Date()): string {
  const d = v == null ? null : new Date(String(v));
  if (!d || Number.isNaN(d.getTime())) return "";
  return parisDay(d) === parisDay(now) ? parisTime(d) : parisSmart(d, now);
}

/** `/orders` — one order per line: outcome, Paris time, route, provider, what
 *  the customer paid in credits and what we paid in wholesale.
 *
 *  Outcome is driven by `got_code` (i.e. `otp is not null`), never by
 *  `status = 'received'` — a code rescued after a cancel lives on a `canceled`
 *  row, and reading status would report a delivered code as a failure.
 *
 *  `held_s` is on every line because it is the most diagnostic number here:
 *  cancels cluster far below the p90 arrival, and seeing "✖ … 8s" next to
 *  "✅ … 58s" makes the difference legible at a glance. It goes through
 *  duration() so "4200s" reads as "1h 10m".
 *
 *  The dev account is INCLUDED and flagged, unlike every analytics surface —
 *  this is an operational view and "did my test order work" is precisely the
 *  question; hiding it would look like the order vanished. */
export function formatOrders(raw: Record<string, unknown>, windowLabel: string): string {
  const s = (raw ?? {}) as {
    total?: number; numbered?: number; delivered?: number; waiting?: number;
    cancelled?: number; expired?: number; no_number?: number;
    settled?: number; settled_codes?: number; rescued?: number;
    default_landed?: number;
    spend_cents?: number; rows?: OrderRow[];
    email?: { total?: number; received?: number };
    esim?: { total?: number };
  };
  const rows = s.rows ?? [];
  const total = s.total ?? 0;
  const lines: string[] = [];

  if (total === 0) {
    lines.push(`📋 <b>No SMS orders — last ${esc(windowLabel)}</b>`);
  } else {
    const numbered = s.numbered ?? 0;
    const settled = s.settled ?? 0;
    const settledCodes = s.settled_codes ?? 0;
    const delivered = s.delivered ?? 0;

    lines.push(`📋 <b>${esc(n("order", total))} · ${esc(numbered)} numbered · ` +
               (settled > 0 ? `${esc(ratio(settledCodes, settled))} delivered` : "nothing settled") +
               ` — last ${esc(windowLabel)}</b>`);
    lines.push("");

    const bits: string[] = [];
    if ((s.cancelled ?? 0) > 0) bits.push(`${s.cancelled} cancelled`);
    if ((s.expired ?? 0) > 0) bits.push(`${s.expired} expired`);
    if ((s.waiting ?? 0) > 0) bits.push(`${s.waiting} still waiting`);
    if ((s.no_number ?? 0) > 0) bits.push(`${s.no_number} never got a number`);
    if ((s.default_landed ?? 0) > 0) bits.push(`${s.default_landed} our own pick`);
    if ((s.rescued ?? 0) > 0) bits.push(`${s.rescued} rescued after a cancel`);
    if (bits.length) lines.push(esc(bits.join(" · ")));
    lines.push(`💸 Wholesale paid: <b>${esc(usd((s.spend_cents ?? 0) / 100))}</b>`);
    lines.push("");

    const { shown, hidden } = capped(rows, MAX_ROWS);
    for (const r of shown) {
      const mark = r.got_code ? "✅" : r.status === "waiting" ? "⏳" : "✖";
      const route = `${r.service_id ?? "?"}·${r.country_id ?? "?"}`;
      // Provider on the row: /delivery only rolls up per provider, so before
      // this there was no way to tell WHICH provider served a failed order.
      const prov = r.provider ? `·${r.provider}` : "";
      const paid = r.actual_cost_cents != null
        ? ` → ${usd(r.actual_cost_cents / 100)}` : "";
      const extra: string[] = [];
      if (!r.got_number) extra.push("no number");
      else if (!r.got_code) extra.push(r.status === "canceled" ? "cancelled" : (r.status ?? ""));
      if (r.tier === "premium") extra.push("real SIM");
      // Flagged because it changes what the row MEANS: the user did not pick
      // this route, so a missing code here says nothing about the pool.
      if (r.from_default) extra.push("our pick");
      if (r.is_dev) extra.push("dev");
      const tail = extra.filter(Boolean).join(", ");
      lines.push(`${mark} <code>${esc(rowTime(r.created_at))}</code> ${esc(route)}${esc(prov)} · ` +
                 `${esc(r.cost_credits ?? 0)}cr${esc(paid)} · ${esc(duration(r.held_s))}` +
                 (tail ? ` · <i>${esc(tail)}</i>` : ""));
    }
    if (hidden > 0) lines.push(`<i>… and ${esc(hidden)} older, not shown</i>`);

    lines.push("");
    lines.push(`<i>service·country·provider · credits charged → wholesale paid · ` +
               `time the number was held</i>`);
    // Say what the rate leaves out, but only when it actually left something
    // out — otherwise it is a caveat about nothing.
    if (settled > 0 && (settled !== numbered || delivered !== settledCodes)) {
      lines.push(`<i>Rate excludes cancels and our own pre-selection ` +
                 `(${esc(delivered)} code${delivered === 1 ? "" : "s"} in total).</i>`);
    }
  }

  // Other product lines get a count, not a row list — they have no route and no
  // delivery semantics comparable to a number, and folding them into the rate
  // above would blend three products into one figure.
  const em = s.email ?? {}, es = s.esim ?? {};
  const otherBits: string[] = [];
  if ((em.total ?? 0) > 0) otherBits.push(`📧 e-mail ${em.total} (${em.received ?? 0} received)`);
  if ((es.total ?? 0) > 0) otherBits.push(`📶 eSIM ${es.total}`);
  if (otherBits.length) lines.push(esc(otherBits.join(" · ")));

  lines.push("");
  lines.push(stamp());
  return lines.join("\n");
}

// ── /funnel ─────────────────────────────────────────────────────────────────

interface FunnelDay {
  d?: string; signups?: number; users_ordering?: number; orders?: number;
  numbered?: number; codes?: number; buys?: number; credits?: number;
}

/** `/funnel` — per-day activity plus the two rates that decide whether the
 *  product works.
 *
 *  Both percentages are COHORT rates over the signups inside the window (of the
 *  people who arrived, how many ordered / paid), never ratio-of-totals: a
 *  window holding yesterday's buyers and today's signups would produce a figure
 *  describing nobody.
 *
 *  The signup grant is printed because it is the thing that most changes these
 *  numbers and it moves with no release — it has been 5, 0, 1, 3, 2 and 0
 *  within days. A MISSING row is printed as missing, never as zero. */
export function formatFunnel(raw: Record<string, unknown>): string {
  const s = (raw ?? {}) as {
    days?: number; rows?: FunnelDay[];
    totals?: {
      signups?: number; activated?: number; buyers?: number; orders?: number;
      numbered?: number; codes?: number; buys?: number; credits?: number;
      default_landed?: number;
    };
    signup_grant?: number | null;
  };
  const rows = s.rows ?? [];
  const t = s.totals ?? {};
  const signups = t.signups ?? 0;
  const share = (v: number) => signups > 0 ? pctOf(v / signups) : "—";

  const lines: string[] = [];
  lines.push(`📈 <b>${esc(signups)} signups → ${esc(t.activated ?? 0)} ordered ` +
             `(${esc(share(t.activated ?? 0))}) → ${esc(t.buyers ?? 0)} bought ` +
             `(${esc(share(t.buyers ?? 0))}) — last ${esc(s.days ?? 7)} days</b>`);
  lines.push("");

  // LEGEND FIRST. The six-letter header needs the reader to already know the
  // vocabulary; /delivery prints its legend and this did not.
  lines.push(`<i>sgn signups · usr users who ordered · ord orders · ` +
             `num got a number · cod codes · buy purchases</i>`);
  // <pre> so the columns line up in Telegram's monospace font. Six narrow
  // columns fit a phone; anything wider wraps and stops being a table.
  lines.push("<pre>");
  lines.push(esc("date  sgn usr ord num cod buy"));
  const todayKey = new Date().toISOString().slice(0, 10);
  let partial = false;
  for (const r of rows) {
    const key = String(r.d ?? "");
    // The last row is TODAY SO FAR. Unmarked it always looks like a collapse,
    // and a reader unfamiliar with the code reads it as a falling trend.
    const isToday = key.slice(0, 10) === todayKey;
    if (isToday) partial = true;
    lines.push(esc(
      (key.slice(5) + (isToday ? "*" : "")).padEnd(5) +
      String(r.signups ?? 0).padStart(4) +
      String(r.users_ordering ?? 0).padStart(4) +
      String(r.orders ?? 0).padStart(4) +
      String(r.numbered ?? 0).padStart(4) +
      String(r.codes ?? 0).padStart(4) +
      String(r.buys ?? 0).padStart(4),
    ));
  }
  lines.push("</pre>");
  if (partial) lines.push(`<i>* today so far — a partial day, not a trend</i>`);

  lines.push(`📱 ${esc(t.orders ?? 0)} orders · ${esc(t.numbered ?? 0)} got a number · ` +
             `${esc(t.codes ?? 0)} codes`);
  lines.push(`💳 ${esc(t.buys ?? 0)} purchases · ${esc(t.credits ?? 0)} credits`);

  // The grant decides WHICH single route new users land on, not just how much
  // they can buy, so it belongs next to the activation rate.
  lines.push(typeof s.signup_grant === "number"
    ? `🎁 Signup grant: <b>${esc(s.signup_grant)}</b> credit${s.signup_grant === 1 ? "" : "s"}`
    : `🎁 Signup grant: <i>no reading</i> — app_config.signup_bonus_credits missing`);

  lines.push("");
  lines.push(`<i>Both % are of the ${esc(signups)} who signed up in this window. ` +
             `Days are UTC calendar days, not Paris.</i>`);
  // Orders on the app's own pre-selection: the user never chose the service and
  // never submitted the number, so they are excluded from every delivery rate.
  if ((t.default_landed ?? 0) > 0) {
    lines.push(`<i>↩︎ ${esc(t.default_landed ?? 0)} default-landed — our own ` +
               `pre-selection, not delivery evidence.</i>`);
  }
  lines.push(stamp());
  return lines.join("\n");
}

// ── /delivery ───────────────────────────────────────────────────────────────

interface DeliveryProvider {
  provider?: string; numbered?: number; settled?: number; codes?: number;
  cancelled?: number; rescued?: number; waiting?: number;
  default_landed?: number; refusals?: number; pct?: number | null;
}

/** `/delivery` — per provider, because a blended rate averages a dead provider
 *  with a live one and describes neither (it once read 10% while the live
 *  provider was at 43%).
 *
 *  Every rate here is `codes / settled`, where settled = held a number AND was
 *  not cancelled by the user AND was not the app's own pre-selection. Cancels
 *  and refusals get their own columns so the sample the rate uses is always
 *  visible beside the sample it does not.
 *
 *  Leads with the rate. The old version opened on a seven-column monospace
 *  table, so "is delivery fine?" needed parsing before it could be answered. */
export function formatDelivery(raw: Record<string, unknown>, windowLabel: string): string {
  const s = (raw ?? {}) as {
    by_provider?: DeliveryProvider[];
    totals?: DeliveryProvider;
    watchdog?: { failing?: { check?: string; detail?: string }[]; checked_at?: string | null };
    smspva_hidden_routes?: number;
    balances?: BalanceReading[];
  };
  const rows = (s.by_provider ?? []).filter(
    (r) => (r.numbered ?? 0) > 0 || (r.refusals ?? 0) > 0,
  );
  const tot = s.totals ?? {};
  const tSettled = tot.settled ?? 0;
  const tCodes = tot.codes ?? 0;

  const lines: string[] = [];
  lines.push(`📶 <b>` +
    (rows.length === 0
      ? "No SMS orders"
      : tSettled > 0
        ? `${esc(ratio(tCodes, tSettled))} delivered`
        : `${esc(tot.numbered ?? 0)} numbered, nothing settled`) +
    ` — last ${esc(windowLabel)}</b>`);
  lines.push("");

  if (rows.length > 0) {
    lines.push("<pre>");
    lines.push(esc("prov      num set cod   % can ref"));
    const line = (r: DeliveryProvider, name: string) => esc(
      name.slice(0, 8).padEnd(9) +
      String(r.numbered ?? 0).padStart(4) +
      String(r.settled ?? 0).padStart(4) +
      String(r.codes ?? 0).padStart(4) +
      (r.pct == null ? "—" : String(r.pct)).padStart(4) +
      String(r.cancelled ?? 0).padStart(4) +
      String(r.refusals ?? 0).padStart(4),
    );
    for (const r of rows) lines.push(line(r, r.provider ?? "?"));
    if (rows.length > 1) lines.push(line(tot, "ALL"));
    lines.push("</pre>");
    lines.push(`<i>num got a number · set settled (not cancelled, not our own ` +
               `pick) · cod codes · can cancelled · ref refused before a number</i>`);

    const extra: string[] = [];
    if ((tot.waiting ?? 0) > 0) extra.push(`${tot.waiting} still waiting`);
    if ((tot.rescued ?? 0) > 0) extra.push(`${tot.rescued} rescued after a cancel`);
    if ((tot.default_landed ?? 0) > 0) {
      extra.push(`${tot.default_landed} on our own pre-selection`);
    }
    if (extra.length) lines.push(esc(extra.join(" · ")));
  }

  // The watchdog verdict, because "is delivery bad" and "is a JOB dead" look
  // identical from a delivery rate alone.
  lines.push("");
  const wd = s.watchdog ?? {};
  const failing = [...(wd.failing ?? [])];
  const wdAgeMs = wd.checked_at ? Date.now() - new Date(wd.checked_at).getTime() : Infinity;
  // A frozen verdict is not health — the same rule telegram-notify enforces.
  if (wdAgeMs > 30 * 60 * 1000) {
    failing.push({ check: "watchdog_stale", detail: "the watchdog itself is not running" });
  }
  if (failing.length === 0) {
    lines.push(`🟢 Watchdog: all jobs healthy` +
               (wd.checked_at ? ` <i>(${esc(ago(ts(wd.checked_at)))})</i>` : ""));
  } else {
    for (const f of failing) {
      lines.push(`🚨 <b>${esc(f.check ?? "?")}</b> — ${esc(f.detail ?? "")}`);
    }
  }

  // One line per LIVE provider. An omitted balance reads as healthy, which is
  // exactly the failure that hid SMSPVA having no monitoring at all while it
  // served 100% of SMS — but a RETIRED provider's reading can only ever be
  // ignored, so it is dropped here exactly as /balance drops it. The two
  // commands used to disagree about which providers matter.
  for (const b of s.balances ?? []) {
    if (RETIRED_PROVIDERS.has(String(b.provider ?? "").toLowerCase())) continue;
    lines.push(balanceLineFrom(b, String(b.provider ?? "").toLowerCase() === "telnyx"
      ? TELNYX_LOW_USD : undefined));
  }

  // Held shut by the reservation-collapse guard. Printed because "the catalog
  // looks small" needs a legible cause, and because a resync could reopen them.
  const hidden = s.smspva_hidden_routes;
  if (typeof hidden === "number" && hidden > 0) {
    lines.push(`<i>🙈 ${esc(hidden)} retired-provider routes held shut ` +
               `(reservation-collapse guard).</i>`);
  }

  lines.push(stamp());
  return lines.join("\n");
}

// ── /subs ───────────────────────────────────────────────────────────────────

/** `/subs` — subscriptions against lines, summary first.
 *
 *  It renders all-zero on a bad day and that is the point. This is the product
 *  whose lifecycle shipped with `reclaim_lapsed_lines()` scheduled in no cron
 *  job and `release-lines` never written: an ordinary Apple cancellation left
 *  the number rented at $1/month forever, discoverable only on the Telnyx
 *  invoice. Subscription state and LINE state are shown side by side and any
 *  divergence is called out rather than left to be noticed.
 *
 *  Three sections, no more: Second Number · Temp-mail · Money & health. The
 *  old version stacked five with nothing but blank lines between them. */
export function formatSubs(raw: Record<string, unknown>): string {
  const s = (raw ?? {}) as {
    subs_total?: number; subs_active?: number;
    subs_by_state?: { state?: string; n?: number }[];
    lines_total?: number;
    lines_by_status?: { status?: string; n?: number }[];
    lines_by_billing?: { billing?: string; n?: number }[];
    monthly_cost_cents?: number;
    trials_tracked?: boolean;
    subs_list?: {
      product?: string; state?: string; auto_renew?: boolean;
      price_milli?: number; currency?: string; expires_at?: string;
      environment?: string; created_at?: string;
    }[];
    subs_not_shown?: number;
    active_billed?: { currency?: string; milli?: number; n?: number }[];
    notifications_7d?: {
      type?: string; subtype?: string; n?: number;
      unprocessed?: number; errored?: number;
    }[];
    telnyx?: BalanceReading;
    dev_hidden?: { lines?: number; subs?: number; mail_subs?: number };
    mail?: {
      total?: number; active?: number;
      by_state?: { state?: string; n?: number }[];
      auto_renew_on?: number;
      enforced?: boolean;
    };
  };

  const active = s.subs_active ?? 0;
  const mail = s.mail ?? {};
  const activeLines = (s.lines_by_status ?? [])
    .filter((r) => ["active", "grace", "past_due"].includes(r.status ?? ""))
    .reduce((a, r) => a + (r.n ?? 0), 0);
  const net = LINE_PRICE_USD * (1 - APPLE_COMMISSION);
  const renewing = (s.subs_list ?? []).filter(
    (r) => r.auto_renew !== false && (r.state === "active" || r.state === "grace"),
  ).length;

  const lines: string[] = [];
  lines.push(`📞 <b>${esc(n("subscription", active))} active · ` +
             `${esc(n("line", activeLines))} live · ` +
             `~${esc(usd(active * net))}/mo net</b>`);
  // The divergence warning is LED WITH, not buried mid-list: a live line whose
  // subscription is gone is rent we pay for nothing; a live subscription with
  // no line is a customer paying for nothing. Both are silent, both happened.
  if (active !== activeLines) {
    lines.push(`⚠️ <b>${esc(active)} active sub(s) vs ${esc(activeLines)} live ` +
               `line(s)</b> — these must match.`);
  }
  if (renewing === 0 && active > 0) {
    lines.push(`⚠️ <b>none of them will renew</b> — auto-renew is off on every one`);
  }
  lines.push("");

  // ── 1. Second Number ──────────────────────────────────────────────────────
  if ((s.subs_total ?? 0) === 0) {
    lines.push("<b>Second Number</b> — <i>no subscribers yet</i>");
  } else {
    const states = (s.subs_by_state ?? [])
      .map((r) => `${esc(r.state ?? "?")} ${esc(r.n ?? 0)}`).join(" · ");
    lines.push(`<b>Second Number</b> ${esc(s.subs_total ?? 0)} subs — ${states}`);
    // One row per subscription: plan, running vs cancelled, expiry in Paris.
    // auto_renew is ASSN-authoritative (20260815100000); "cancelled" means
    // auto-renew off — the line stays live until the period ends, so state
    // stays 'active'. A zero billed price is rendered as a free period: an
    // INFERENCE from price_milli = 0 (offerType is not persisted anywhere),
    // never a tracked fact.
    const { shown, hidden } = capped(s.subs_list ?? [], 12);
    for (const r of shown) {
      const pid = r.product ?? "";
      const plan = pid.endsWith(".monthly") ? "monthly"
        : pid.endsWith(".yearly") ? "yearly" : (pid || "?");
      const free = r.price_milli === 0 ? " · free period" : "";
      const env = r.environment && r.environment !== "Production"
        ? ` · ${esc(r.environment)}` : "";
      const when = r.expires_at ? parisSmart(ts(r.expires_at)) : "?";
      const status = r.state === "active"
        ? (r.auto_renew !== false
            ? `▶️ renews ${esc(when)}`
            : `🔕 cancelled — ends ${esc(when)}`)
        : `${esc(r.state ?? "?")} — ${esc(when)}`;
      lines.push(`   • ${esc(plan)}${free}${env} · ${status}`);
    }
    if (hidden > 0) lines.push(`   <i>… and ${esc(hidden)} more, not shown</i>`);
  }
  if ((s.lines_total ?? 0) > 0) {
    const st = (s.lines_by_status ?? [])
      .map((r) => `${esc(r.status ?? "?")} ${esc(r.n ?? 0)}`).join(" · ");
    const bill = (s.lines_by_billing ?? [])
      .map((r) => `${esc(r.billing ?? "?")} ${esc(r.n ?? 0)}`).join(" · ");
    lines.push(`   📱 ${esc(s.lines_total ?? 0)} lines — ${st}` +
               (bill ? ` · billed ${bill}` : "") +
               ` · rent <b>${esc(usd((s.monthly_cost_cents ?? 0) / 100))}/mo</b>`);
  } else {
    lines.push(`   📱 <i>no numbers rented</i>`);
  }

  // ── 2. Temp-mail ──────────────────────────────────────────────────────────
  //
  // 🔴 THE ENFORCEMENT STATE IS READ, NEVER ASSERTED. This block used to print
  // "enforcement is OFF" as literal text — true when written, and a lie from
  // the instant the switch is flipped, which is exactly the moment somebody
  // opens /subs to check the flip landed.
  lines.push("");
  const enforced = mail.enforced === true;
  lines.push(`<b>Temp-mail</b> ${esc(mail.total ?? 0)} subs · ` +
             `${esc(mail.active ?? 0)} entitled · paywall ` +
             (enforced ? "<b>ON</b>" : "<b>OFF</b>"));
  if (!enforced) {
    lines.push(`   <i>the pre-2.2 daily free cap still applies</i>`);
  }
  if ((mail.total ?? 0) > 0) {
    const mstates = (mail.by_state ?? [])
      .map((r) => `${esc(r.state ?? "?")} ${esc(r.n ?? 0)}`).join(" · ");
    lines.push(`   ${mstates} · auto-renew on ${esc(mail.auto_renew_on ?? 0)}`);
    // "entitled" uses has_email_subscription()'s own predicate (greatest of
    // expires_at / grace_expires_at); by_state is the RAW state count with no
    // expiry filter. Same table, so they must match — a gap means a row is
    // stuck in active/grace past its own expiry, i.e. an ASSN notification
    // that has not landed or has not been processed.
    const stateActive = (mail.by_state ?? [])
      .filter((r) => r.state === "active" || r.state === "grace")
      .reduce((a, r) => a + (r.n ?? 0), 0);
    if ((mail.active ?? 0) !== stateActive) {
      lines.push(`   ⚠️ <b>${esc(mail.active ?? 0)} entitled vs ${esc(stateActive)} ` +
                 `in an active/grace state</b> — an ASSN notification has not landed.`);
    }
  }

  // ── 3. Money and health ───────────────────────────────────────────────────
  lines.push("");
  lines.push(`<b>Money &amp; health</b>`);
  const billed = (s.active_billed ?? [])
    .map((b) => `${esc((b.currency ?? "?").toUpperCase())} ` +
                `${((b.milli ?? 0) / 1000).toFixed(2)} ×${esc(b.n ?? 0)}`).join(" + ");
  if (billed) lines.push(`💱 actually billed: ${billed}`);
  const notifs = s.notifications_7d ?? [];
  if (notifs.length === 0) {
    lines.push(`🔔 ASSN last 7d: <i>none</i>`);
  } else {
    lines.push(`🔔 ASSN last 7d: ` + notifs.map((x) =>
      `${esc(x.type ?? "?")}${x.subtype ? `/${esc(x.subtype)}` : ""} ×${esc(x.n ?? 0)}`,
    ).join(" · "));
    const stuck = notifs.reduce((a, x) => a + (x.unprocessed ?? 0), 0);
    const bad = notifs.reduce((a, x) => a + (x.errored ?? 0), 0);
    if (stuck > 0 || bad > 0) {
      lines.push(`   ⚠️ ${esc(stuck)} unprocessed · ${esc(bad)} errored — a dropped ` +
                 `notification is a lapse the state machine never sees`);
    }
  }
  lines.push(balanceLineFrom({ provider: "Telnyx", ...(s.telnyx ?? {}) }, TELNYX_LOW_USD));

  // ── caveats ───────────────────────────────────────────────────────────────
  lines.push("");
  lines.push(`<i>MRR = ${esc(active)} × $${LINE_PRICE_USD.toFixed(2)} list − Apple ` +
             `${Math.round(APPLE_COMMISSION * 100)}% (Small Business Program) = ` +
             `${esc(usd(net))} each.</i>`);
  // ⚠️ Reported as untracked, never as "0 trials". line_sub_state has no trial
  // member and ASSN's offerType is not persisted, so a zero would be an
  // assertion we cannot make.
  if (s.trials_tracked !== true) {
    lines.push(`<i>"free period" is inferred from a $0 billed price — no ` +
               `offer-type column exists. /trials for the conversion timeline.</i>`);
  }
  const dev = s.dev_hidden ?? {};
  if ((dev.lines ?? 0) > 0 || (dev.subs ?? 0) > 0) {
    lines.push(`<i>dev account hidden: ${esc(dev.lines ?? 0)} line(s), ` +
               `${esc(dev.subs ?? 0)} sub(s) — they cost real rent.</i>`);
  }
  lines.push(stamp());
  return lines.join("\n");
}

// ── /trials ─────────────────────────────────────────────────────────────────

/** Money in a specific currency. USD goes through usd(); anything else keeps
 *  its own code rather than being silently converted — the same rule /revenue
 *  follows, one screen smaller. */
function money(milli: unknown, currency: unknown): string {
  const amount = num0(milli) / 1000;
  const code = String(currency ?? "USD").toUpperCase();
  return code === "USD" ? usd(amount) : `${code} ${amount.toFixed(2)}`;
}

/** Plan word out of a product id, without hardcoding the bundle prefix. */
function planWord(product: unknown): string {
  const p = String(product ?? "");
  if (p.endsWith(".yearly")) return "yearly";
  if (p.endsWith(".monthly")) return "monthly";
  return p || "?";
}

/** `/trials` — THE conversion timeline. "When will the free trials convert,
 *  and for how much" was unanswerable before this: `ops_subs` hardcodes
 *  `trials_tracked = false` and the nearest proxy (a $0 billed price) was shown
 *  per-row with no aggregate and no time.
 *
 *  Three groups, in the order that matters to money:
 *    1. Converting — auto-renew ON, Apple bills at `expires_at`.
 *    2. Lapsing    — auto-renew OFF, the trial just ends.
 *    3. Paid, running — already billed at least once.
 *  Everything else (already lapsed, in the 30-day tail) gets a short fourth
 *  block rather than being dropped, because a silently missing subscriber is
 *  the failure mode this whole product line keeps paying for.
 *
 *  ⚠️ auto_renew is a LIVE flag, not a promise: every subscriber so far has
 *  flipped it off within minutes of paying, so the caveat line says outright
 *  that it can still change before each time shown. */
export function formatTrials(raw: Record<string, unknown>): string {
  const s = obj(raw);
  const now = s.now ? new Date(String(s.now)) : new Date();
  const summary = obj(s.summary);
  const subs = arr(s.subs);

  // What to call the subscriber on a row. A MAIL subscription has no phone
  // number, so falling back to the plan keeps the row identifiable instead of
  // rendering a bare " · ".
  const who = (r: Record<string, unknown>) => str(r.line_e164)
    ? num(r.line_e164)
    : `${esc(planWord(r.product))} <i>(${esc(str(r.family) || "sub")})</i>`;

  const converting: Record<string, unknown>[] = [];
  const lapsing: Record<string, unknown>[] = [];
  const paid: Record<string, unknown>[] = [];
  const other: Record<string, unknown>[] = [];
  for (const r of subs) {
    const isTrial = r.is_trial === true;
    // A row that has already left active/grace is HISTORY, whatever its
    // auto_renew flag still says — the RPC keeps 30 days of lapsed rows so a
    // churn is visible, and telling the owner a dead trial "ends after grace"
    // would be a forecast about the past.
    const live = str(r.state) === "active" || str(r.state) === "grace";
    if (!live) other.push(r);
    else if (isTrial && r.auto_renew === false) lapsing.push(r);
    else if (isTrial && r.converts === true) converting.push(r);
    else if (!isTrial) paid.push(r);
    else other.push(r);
  }

  const lines: string[] = [];

  // ── headline ──────────────────────────────────────────────────────────────
  if (converting.length > 0) {
    let gross = 0;
    let last = 0;
    for (const r of converting) {
      gross += num0(r.expected_gross_milli) / 1000;
      const t = new Date(String(r.expires_at ?? "")).getTime();
      if (Number.isFinite(t) && t > last) last = t;
    }
    const span = last > 0
      ? duration((last - now.getTime()) / 1000)
      : "";
    lines.push(`⏳ <b>${esc(n("trial", converting.length))} convert` +
               (span ? ` in the next ${esc(span)}` : "") +
               ` → ~${esc(usd(gross))} gross</b>`);
  } else if (lapsing.length > 0) {
    lines.push(`⏳ <b>No trial will convert — ${esc(n("trial", lapsing.length))} ` +
               `lapsing, auto-renew off</b>`);
  } else if (paid.length > 0) {
    lines.push(`⏳ <b>No trials running · ${esc(n("paid subscription", paid.length))}</b>`);
  } else {
    lines.push(`⏳ <b>No trials and no subscriptions</b>`);
    lines.push("");
    lines.push(stamp());
    return lines.join("\n");
  }
  lines.push("");

  // ── 1. converting ─────────────────────────────────────────────────────────
  if (converting.length > 0) {
    lines.push(`<b>Converting (auto-renew ON)</b>`);
    const { shown, hidden } = capped(converting, 12);
    for (const r of shown) {
      lines.push(`${esc(parisFull(ts(r.expires_at)))} · ${who(r)} · ` +
                 `${esc(money(r.expected_gross_milli, r.currency))} · ` +
                 `${esc(until(ts(r.expires_at), now))}`);
    }
    if (hidden > 0) lines.push(`<i>… and ${esc(hidden)} more, not shown</i>`);
  }

  // ── 2. lapsing ────────────────────────────────────────────────────────────
  if (lapsing.length > 0) {
    lines.push(`<b>Lapsing (auto-renew OFF)</b>`);
    const { shown, hidden } = capped(lapsing, 12);
    for (const r of shown) {
      lines.push(`${esc(parisFull(ts(r.expires_at)))} · ${who(r)} · ` +
                 `trial ends, number released after grace`);
    }
    if (hidden > 0) lines.push(`<i>… and ${esc(hidden)} more, not shown</i>`);
  }

  // ── 3. paid ───────────────────────────────────────────────────────────────
  if (paid.length > 0) {
    lines.push(`<b>Paid, running</b>`);
    const { shown, hidden } = capped(paid, 12);
    for (const r of shown) {
      const renews = r.auto_renew === false
        ? `auto-renew OFF → ends ${esc(parisSmart(ts(r.expires_at), now))}`
        : `renews ${esc(parisSmart(ts(r.expires_at), now))}`;
      lines.push(`${who(r)} · ${esc(planWord(r.product))} · ${renews}`);
    }
    if (hidden > 0) lines.push(`<i>… and ${esc(hidden)} more, not shown</i>`);
  }

  // ── 4. everything else, never dropped ─────────────────────────────────────
  if (other.length > 0) {
    lines.push(`<b>Lapsed in the last 30 days</b>`);
    const { shown, hidden } = capped(other, 8);
    for (const r of shown) {
      lines.push(`${who(r)} · ${esc(str(r.state) || "?")} · ` +
                 `${esc(parisSmart(ts(r.expires_at), now))}`);
    }
    if (hidden > 0) lines.push(`<i>… and ${esc(hidden)} more, not shown</i>`);
  }

  lines.push("");
  const sandbox = num0(summary.sandbox_hidden ?? s.sandbox_hidden);
  if (sandbox > 0) {
    // A Sandbox subscription is Apple-signed and worth $0. Shown, never folded
    // into the forecast.
    lines.push(`<i>${esc(sandbox)} Sandbox subscription(s) hidden — $0, not counted.</i>`);
  }
  if (num0(summary.expected_gross_milli_7d) > 0) {
    lines.push(`<i>Next 7 days: ~${esc(usd(num0(summary.expected_gross_milli_7d) / 1000))} ` +
               `expected gross.</i>`);
  }
  lines.push(`<i>auto-renew can still flip before each time; Apple bills at the ` +
             `minute shown.</i>`);
  lines.push(stamp());
  return lines.join("\n");
}

// ── /failures ───────────────────────────────────────────────────────────────

/** `/failures` — "what failed today, and on which route". Nothing in the bot
 *  could answer this: /delivery aggregates to the provider, and route-level
 *  detail existed only as up-to-35 raw rows in /orders that the owner had to
 *  eyeball.
 *
 *  TWO KINDS OF FAILURE, kept apart on purpose because they have different
 *  causes and different fixes:
 *    "no number"  — the order died inside create-order (dry route, price over
 *                   the ceiling, provider fault). Charged and refunded; NOT a
 *                   delivery failure, and never counted in a delivery rate.
 *    "no code"    — a number was held and nothing arrived. This one IS about
 *                   the pool. */
export function formatFailures(raw: Record<string, unknown>, windowLabel: string): string {
  const s = obj(raw);
  const noNumber = obj(s.no_number);
  const noCode = obj(s.no_code);
  const email = obj(s.email);
  const esim = obj(s.esim);
  const calls = obj(s.calls);
  const blocked = arr(s.blocked_routes).length
    ? arr(s.blocked_routes) as unknown as string[]
    : (Array.isArray(s.blocked_routes) ? s.blocked_routes as string[] : []);

  const nnTotal = num0(noNumber.total);
  const ncTotal = num0(noCode.total);
  const otherTotal = num0(email.failed) + num0(email.expired_no_code) +
                     num0(esim.failed) + num0(calls.failed) + num0(calls.unreached);

  const lines: string[] = [];
  if (nnTotal === 0 && ncTotal === 0 && otherTotal === 0) {
    lines.push(`✅ <b>No failures in the last ${esc(windowLabel)}</b>`);
    lines.push("");
    lines.push(stamp());
    return lines.join("\n");
  }

  lines.push(`❌ <b>${esc(nnTotal)} orders got no number · ${esc(ncTotal)} numbered ` +
             `but no code (${esc(windowLabel)})</b>`);
  lines.push("");

  if (nnTotal > 0) {
    const users = num0(noNumber.users);
    lines.push(`<b>No number — by route</b>` +
               (users > 0 ? ` <i>(${esc(n("user", users))})</i>` : ""));
    const { shown, hidden } = capped(arr(noNumber.by_route), 15);
    for (const r of shown) {
      // ⚠️ `reasons` is NOT rendered. `orders` has no close-reason column, so
      // the RPC derives a single bucket and a stockout, a margin_too_low
      // refusal and a provider fault are indistinguishable in it. Printing
      // "no_numbers_available" beside a provider name would read as a verdict
      // on that provider's stock, which is a claim the data cannot support.
      // The footer says where the exact reason lives instead.
      const bits = [
        esc(str(r.service_id) || "?"),
        esc(str(r.country_id) || "?"),
        esc(str(r.provider) || "?"),
        `${esc(num0(r.n))}×`,
      ];
      if (num0(r.users) > 0) bits.push(esc(n("user", num0(r.users))));
      if (r.last_at) bits.push(`last ${esc(rowTime(r.last_at))}`);
      if (r.blocked === true) bits.push("🚫 blocked");
      else if (str(r.route_status) && str(r.route_status) !== "active") {
        bits.push(`route ${esc(str(r.route_status))}`);
      }
      lines.push(bits.join(" · "));
    }
    if (hidden > 0) lines.push(`<i>… and ${esc(hidden)} more routes, not shown</i>`);
    lines.push("");
  }

  if (ncTotal > 0) {
    const parts: string[] = [];
    if (num0(noCode.settled_expired) > 0) parts.push(`${num0(noCode.settled_expired)} expired`);
    if (num0(noCode.canceled) > 0) parts.push(`${num0(noCode.canceled)} cancelled`);
    lines.push(`<b>No code — by route</b>` +
               (parts.length ? ` <i>(${esc(parts.join(" · "))})</i>` : ""));
    const { shown, hidden } = capped(arr(noCode.by_route), 15);
    for (const r of shown) {
      const bits = [
        esc(str(r.service_id) || "?"),
        esc(str(r.country_id) || "?"),
        esc(str(r.provider) || "?"),
        `${esc(num0(r.n))}×`,
        `${esc(num0(r.codes))} codes`,
      ];
      if (r.median_held_s != null) bits.push(`median held ${esc(duration(num0(r.median_held_s)))}`);
      lines.push(bits.join(" · "));
    }
    if (hidden > 0) lines.push(`<i>… and ${esc(hidden)} more routes, not shown</i>`);
    // The app's own pre-selection. The user never chose the service and never
    // submitted the number anywhere, so a missing code says nothing about the
    // pool — counted here, excluded from every rate.
    if (num0(noCode.default_landed) > 0) {
      lines.push(`<i>${esc(num0(noCode.default_landed))} were the app's own default ` +
                 `pick, excluded from the rate</i>`);
    }
    lines.push("");
  }

  const other: string[] = [];
  if (num0(email.failed) > 0 || num0(email.expired_no_code) > 0) {
    const domains = arr(email.by_domain)
      .map((d) => `${esc(str(d.domain) || "?")} ${esc(num0(d.n))}`).join(" · ");
    other.push(`📧 e-mail: ${esc(num0(email.failed))} never got an address · ` +
               `${esc(num0(email.expired_no_code))} no code` +
               (domains ? ` · ${domains}` : ""));
  }
  if (num0(esim.failed) > 0) other.push(`🌍 eSIM: ${esc(num0(esim.failed))} failed`);
  if (num0(calls.failed) > 0 || num0(calls.unreached) > 0) {
    // "unreached" = neither a session nor a leg id, i.e. the call never got to
    // the provider at all. Billed nothing, but it is the shape of a product
    // that is simply not working.
    other.push(`📞 calls: ${esc(num0(calls.failed))} failed · ` +
               `${esc(num0(calls.unreached))} never reached the provider`);
  }
  if (other.length) { lines.push(...other); lines.push(""); }

  if (blocked.length) {
    lines.push(`🚫 blocked routes: ${esc(blocked.slice(0, 12).join(" · "))}` +
               (blocked.length > 12 ? ` <i>… and ${blocked.length - 12} more</i>` : ""));
  }
  const early = obj(s.refusals).cancel_too_early_429;
  if (typeof early === "number" && early > 0) {
    lines.push(`<i>${esc(early)} cancel(s) refused under the minimum hold — the ` +
               `guard working, not a failure.</i>`);
  }

  lines.push("");
  lines.push(`<i>no number = the order was refused or the pool was empty before ` +
             `any number was reserved; the app's logs hold the exact reason. ` +
             `Charged and refunded, never counted as a delivery failure. ` +
             `Try /route &lt;service&gt; &lt;country&gt;.</i>`);
  lines.push(stamp());
  return lines.join("\n");
}

// ── /now ────────────────────────────────────────────────────────────────────

/** `/now` — one screen, "is anything on fire and what happened today".
 *
 *  The headline is the WORST live fact, not a greeting: a failing watchdog
 *  check beats a thin float beats a quiet day. Everything below it is one line
 *  per subject so the whole reply fits a phone screen without scrolling. */
export function formatNow(raw: Record<string, unknown>): string {
  const s = obj(raw);
  const now = s.now ? new Date(String(s.now)) : new Date();
  const balances = obj(s.balances);
  const wd = obj(s.watchdog);
  const failing = arr(wd.failing);
  const paused = obj(s.paused);
  const today = obj(s.today);
  const linesInfo = obj(s.lines);
  const support = obj(s.support);
  const alerts = Array.isArray(s.alerts_active) ? s.alerts_active as unknown[] : [];

  // Anything under three days of runway is the thing to act on tonight — but
  // runway alone is not the whole test, and two floats have none:
  //   * an EMPTY balance has no burn, so runway_days is null. $0.00 must never
  //     sit underneath "All healthy".
  //   * Telnyx is rent, not per-order wholesale: the question is "can we pay
  //     next month", which its own line already answers. The headline has to
  //     agree with the line underneath it.
  const thin: string[] = [];
  for (const [name, v] of Object.entries(balances)) {
    const b = obj(v);
    const days = b.runway_days;
    const bal = typeof b.usd === "number"
      ? b.usd
      : (typeof b.balance_usd === "number" ? b.balance_usd : null);
    const rent = b.rent_per_month_usd;
    if (typeof days === "number" && Number.isFinite(days) && days < 3) {
      thin.push(`${name} ~${days.toFixed(1)}d`);
    } else if (bal !== null && bal <= 0) {
      thin.push(`${name} ${usd(bal)}`);
    } else if (bal !== null && typeof rent === "number" && rent > 0 && bal < rent) {
      thin.push(`${name} ${usd(bal)} < ${usd(rent)}/mo rent`);
    }
  }

  // A frozen verdict is not health — the same 30-minute rule /balance,
  // /alerts and telegram-notify all apply. Without it `/now`, which is also
  // the morning brief, renders a dead watchdog as "all jobs healthy".
  const wdAgeMs = wd.checked_at
    ? now.getTime() - new Date(String(wd.checked_at)).getTime()
    : Infinity;
  const wdStale = !(wdAgeMs <= 30 * 60 * 1000);
  const wdAgeWords = wd.checked_at ? ago(ts(wd.checked_at), now) : "an unknown time";

  const out: string[] = [];
  if (wdStale) {
    out.push(`🚨 <b>Watchdog has not run for ${esc(wdAgeWords)}` +
             (thin.length ? ` · float thin: ${esc(thin.join(" · "))}` : "") + `</b>`);
  } else if (failing.length > 0) {
    out.push(`🚨 <b>${esc(n("check", failing.length))} failing` +
             (thin.length ? ` · float thin: ${esc(thin.join(" · "))}` : "") + `</b>`);
  } else if (thin.length > 0) {
    out.push(`🟠 <b>Float thin — ${esc(thin.join(" · "))}</b>`);
  } else {
    const orders = num0(today.orders);
    const codes = num0(today.codes);
    out.push(`🟢 <b>All healthy — ${esc(n("order", orders))} today, ` +
             `${esc(n("code", codes))}</b>`);
  }
  out.push("");

  // ── float ─────────────────────────────────────────────────────────────────
  for (const [name, v] of Object.entries(balances)) {
    const b = obj(v);
    const isTelnyx = name.toLowerCase() === "telnyx";
    let line = balanceRunwayLine(name, b, isTelnyx ? TELNYX_LOW_USD : undefined);
    // Telnyx is rent, not per-order wholesale, so its runway is "can we pay
    // next month's rent" — a different question, and the one that matters when
    // a lapsed number keeps billing.
    const rent = b.rent_per_month_usd;
    if (isTelnyx && typeof rent === "number" && rent > 0) {
      const bal = typeof b.usd === "number" ? b.usd : num0(b.balance_usd);
      line += bal < rent
        ? ` · ⚠️ <b>under one month of rent</b> (${esc(usd(rent))}/mo)`
        : ` · rent ${esc(usd(rent))}/mo`;
    }
    out.push(line);
  }

  // ── watchdog ──────────────────────────────────────────────────────────────
  out.push("");
  if (wdStale) {
    out.push(`🚨 <b>watchdog_stale</b> — the watchdog itself is not running ` +
             `<i>(last verdict ${esc(wdAgeWords)}` +
             (failing.length ? `, ${esc(n("check", failing.length))} failing in it` : "") +
             `)</i>`);
  } else if (failing.length === 0) {
    out.push(`🟢 Watchdog: all jobs healthy` +
             (wd.checked_at ? ` <i>(${esc(ago(ts(wd.checked_at), now))})</i>` : ""));
  } else {
    for (const f of capped(failing, 8).shown) {
      out.push(`🚨 <b>${esc(str(f.check) || "?")}</b> — ${esc(str(f.detail))}`);
    }
    const extra = capped(failing, 8).hidden;
    if (extra > 0) out.push(`<i>… and ${esc(extra)} more, not shown</i>`);
    if (wd.checked_at) out.push(`<i>watchdog last ran ${esc(ago(ts(wd.checked_at), now))}</i>`);
  }

  // ── pauses, ONLY when something is paused ─────────────────────────────────
  const pausedBits: string[] = [];
  if (paused.lines === true) pausedBits.push("second numbers");
  if (paused.esim === true) pausedBits.push("eSIM");
  if (paused.email_sub_enforced === false) pausedBits.push("mail paywall off");
  if (pausedBits.length) out.push(`⏸ Paused: <b>${esc(pausedBits.join(" · "))}</b>`);

  // ── today (Paris midnight) ────────────────────────────────────────────────
  const t: string[] = [
    `${esc(num0(today.signups))} signups`,
    `${esc(num0(today.orders))} orders`,
    `${esc(num0(today.numbered))} numbered`,
    esc(n("code", num0(today.codes))),
  ];
  if (num0(today.purchases) > 0) {
    t.push(`${esc(n("purchase", num0(today.purchases)))} ` +
           `(${esc(num0(today.purchase_credits))}cr)`);
  }
  if (num0(today.emails) > 0) {
    t.push(`${esc(n("e-mail", num0(today.emails)))} (${esc(n("code", num0(today.email_codes)))})`);
  }
  out.push(`📊 Today: ${t.join(" · ")}`);

  // ── lines ─────────────────────────────────────────────────────────────────
  const lineBits: string[] = [`${esc(num0(linesInfo.live))} live`];
  if (num0(linesInfo.trials_converting_24h) > 0) {
    lineBits.push(`${esc(num0(linesInfo.trials_converting_24h))} converting in 24h`);
  }
  if (linesInfo.next_conversion_at) {
    lineBits.push(`next ${esc(parisFull(ts(linesInfo.next_conversion_at)))}` +
                  // Spelled out rather than via num(), so the esc() on a
                  // provider-supplied string is visible at the call site — a
                  // non-NANP number skips the pretty-printer's regex entirely
                  // and reaches the reply exactly as the provider wrote it.
                  (linesInfo.next_conversion_e164
                    ? ` ${esc(e164Pretty(linesInfo.next_conversion_e164))}` : ""));
  }
  // Each of these is money leaking quietly: a swap whose old number was never
  // released, a rental stuck half-provisioned, a release that never drained.
  if (num0(linesInfo.swaps_pending_release) > 0) {
    lineBits.push(`⚠️ ${esc(num0(linesInfo.swaps_pending_release))} swap(s) not released`);
  }
  if (num0(linesInfo.stuck_provisioning) > 0) {
    lineBits.push(`⚠️ ${esc(num0(linesInfo.stuck_provisioning))} stuck provisioning`);
  }
  if (num0(linesInfo.releasing_stale) > 0) {
    lineBits.push(`⚠️ ${esc(num0(linesInfo.releasing_stale))} stale releasing`);
  }
  out.push(`📞 Lines: ${lineBits.join(" · ")}`);

  // ── support ───────────────────────────────────────────────────────────────
  const openN = num0(support.open);
  const assignedN = num0(support.assigned);
  if (openN > 0 || assignedN > 0) {
    const oldest = support.oldest_unanswered_at
      // `ago()` already ends in "ago"; "oldest waiting 11d 4h ago" reads as a
      // time in the past rather than a duration still elapsing.
      ? ` · oldest waiting ${esc(duration(
          (now.getTime() - new Date(String(support.oldest_unanswered_at)).getTime()) / 1000))}`
      : "";
    out.push(`📬 Support: ${esc(openN)} open · ${esc(assignedN)} assigned${oldest}`);
  } else {
    out.push(`📬 Support: nothing open`);
  }

  if (alerts.length) {
    out.push(`🔔 Active alerts: ${esc(alerts.map((a) => String(a)).join(" · "))}`);
  }

  out.push("");
  out.push(`<i>Today is since midnight Paris.</i>`);
  out.push(stamp(now));
  return out.join("\n");
}

// ── /support ────────────────────────────────────────────────────────────────

/** `/support` — the queue. Nothing in the bot aggregated `support_threads`, so
 *  "what is open and how long has it waited" was only answerable by scrolling
 *  back to the original push notification.
 *
 *  WAITING, not OPEN, is the headline number: a thread can sit in `assigned`
 *  with the customer's message still unanswered, which is exactly the state
 *  that looks handled and is not. */
export function formatSupport(raw: Record<string, unknown>): string {
  const s = obj(raw);
  const threads = arr(s.threads);
  const now = new Date();
  const waiting = threads.filter((t) => str(t.last_sender) === "user");

  const out: string[] = [];
  if (waiting.length > 0) {
    let oldest = Infinity;
    for (const t of waiting) {
      const w = new Date(String(t.waiting_since ?? t.last_message_at ?? "")).getTime();
      if (Number.isFinite(w) && w < oldest) oldest = w;
    }
    const wait = Number.isFinite(oldest)
      ? ` waiting ${duration((now.getTime() - oldest) / 1000)}` : "";
    out.push(`📬 <b>${esc(n("thread", waiting.length))}${esc(wait)}</b>`);
  } else if (threads.length > 0) {
    out.push(`📬 <b>Nothing waiting on us — ${esc(num0(s.open))} open · ` +
             `${esc(num0(s.assigned))} assigned</b>`);
  } else {
    out.push(`📬 <b>Support queue empty</b>` +
             (num0(s.closed_7d) > 0
               ? ` — ${esc(num0(s.closed_7d))} closed in the last 7d` : ""));
    out.push("");
    out.push(stamp(now));
    return out.join("\n");
  }
  out.push("");

  const { shown, hidden } = capped(threads, 10);
  for (const t of shown) {
    // A user id is unusable at full length on a phone; the first 8 chars are
    // what every other ops surface in this repo quotes.
    const who = str(t.display_name) || `${str(t.user_id).slice(0, 8)}…`;
    const mark = str(t.last_sender) === "user" ? "🔴" : "✅";
    const since = t.waiting_since ?? t.last_message_at;
    const head = [
      `<b>${esc(who)}</b>`,
      esc(str(t.status) || "?"),
      `${esc(num0(t.messages))} msg`,
    ];
    if (since) head.push(`${esc(parisSmart(ts(since), now))} (${esc(ago(ts(since), now))})`);
    out.push(`${mark} ${head.join(" · ")}`);
    // The body is user-written text — esc() is not optional here.
    const body = str(t.last_body).replace(/\s+/g, " ").trim();
    if (body) out.push(`   <i>${esc(body.slice(0, 120))}${body.length > 120 ? "…" : ""}</i>`);
  }
  if (hidden > 0) out.push(`<i>… and ${esc(hidden)} more, not shown</i>`);

  out.push("");
  out.push(`<i>Answer by replying to the relayed message, or press ✅ Accept ` +
           `and type — a plain message goes to the assigned thread.</i>`);
  out.push(stamp(now));
  return out.join("\n");
}

// ── /lines ──────────────────────────────────────────────────────────────────

/** `/lines` (no argument) — the fleet. One row per rented number with its
 *  allowance, its subscription state and whether voice is actually attached.
 *
 *  `voice_attached` is on every row because our own database recorded
 *  `provider_voice_attached = true` for twelve days while Telnyx held no
 *  outbound profile at all, and the symptom was silent: calls simply never
 *  connected. A flag that has lied once is a flag worth printing.
 *
 *  A `suspended` line is rent we are still paying — it is listed with the
 *  others, never filtered out. */
export function formatLines(raw: Record<string, unknown>): string {
  const s = obj(raw);
  const rows = arr(s.lines);
  const swaps = obj(s.swaps);
  const now = new Date();
  const live = num0(s.live) || rows.filter(
    (r) => ["active", "grace", "past_due"].includes(str(r.status)),
  ).length;
  // Real provider rent from phone_lines.monthly_cost_cents (PR/VI numbers cost
  // more than the $1 US/CA rate, so a per-row count would understate it);
  // falls back to $1/row only when the RPC predates the field.
  const rentFromRpc = (raw as { rent_per_month_usd?: number }).rent_per_month_usd;
  const rent = typeof rentFromRpc === "number" ? rentFromRpc : rows.length;

  const out: string[] = [];
  out.push(`📱 <b>${esc(n("line", live))} live` +
           (rows.length > live ? ` · ${esc(rows.length - live)} not live but still rented` : "") +
           (s.paused === true ? ` · <b>RENTALS PAUSED</b>` : "") + `</b>`);
  if (rows.length === 0) {
    out.push("");
    out.push("<i>No numbers rented.</i>");
    out.push("");
    out.push(stamp(now));
    return out.join("\n");
  }
  out.push("");

  const { shown, hidden } = capped(rows, 15);
  for (const r of shown) {
    const bits: string[] = [`<b>${num(r.e164)}</b>`, esc(str(r.status) || "?")];
    if (str(r.billing) && str(r.billing) !== "apple") bits.push(esc(str(r.billing)));
    const subState = str(r.sub_state);
    if (subState) {
      bits.push(`sub ${esc(subState)}` +
                (r.sub_is_trial === true ? " (trial)" : "") +
                (r.sub_auto_renew === false ? " 🔕" : ""));
    }
    if (r.sub_expires_at) bits.push(esc(parisSmart(ts(r.sub_expires_at), now)));
    if (r.voice_attached === false) bits.push("⚠️ no voice profile");
    out.push(bits.join(" · "));

    // Usage on its own line: allowances are hard stops, so "3/200" is the
    // thing that tells you whether the product is being used at all. Eight
    // inbound messages across the whole fleet is the finding, not the meter.
    const usage = [
      `SMS ${esc(num0(r.sms_used))}/${esc(num0(r.sms_allowance))}`,
      `voice ${esc(duration(num0(r.voice_used_seconds)))}/` +
        `${esc(duration(num0(r.voice_allowance_seconds)))}`,
      `${esc(num0(r.inbound_msgs_30d))} in · ${esc(n("call", num0(r.calls_30d)))} (30d)`,
    ];
    if (num0(r.swaps) > 0) usage.push(`${esc(num0(r.swaps))} swap(s)`);
    out.push(`   <i>${usage.join(" · ")}</i>`);
  }
  if (hidden > 0) out.push(`<i>… and ${esc(hidden)} more, not shown</i>`);

  out.push("");
  const swapBits: string[] = [`${esc(num0(swaps.total))} total`];
  // A swap whose old number was never released is the newest version of the
  // "silent rent forever" failure this product line already paid for once.
  if (num0(swaps.pending_release) > 0) {
    swapBits.push(`⚠️ <b>${esc(num0(swaps.pending_release))} old number(s) not released</b>`);
  }
  if (num0(swaps.failed) > 0) swapBits.push(`${esc(num0(swaps.failed))} failed`);
  out.push(`🔁 Swaps: ${swapBits.join(" · ")}`);
  out.push(`💸 Rent run rate: <b>${esc(usd(rent))}/mo</b> <i>(provider rate per number)</i>`);

  out.push("");
  out.push(`<i>Pausing stops NEW rentals only — existing lines keep receiving ` +
           `and keep costing rent until they lapse.</i>`);
  out.push(stamp(now));
  return out.join("\n");
}

// ── /lines countries ────────────────────────────────────────────────────────

/** A country's capability strip. PRESENT-OR-ABSENT, never red: absence is not
 *  an error, it is what the country sells. A voice-only country is an honest
 *  "call out" line, not a broken one — that is the whole reason the catalog
 *  exists, so it must not be rendered as a fault. */
function capStrip(r: Record<string, unknown>): string {
  const glyph = (on: unknown, yes: string) => on === true ? yes : "·";
  return [
    glyph(r.supports_voice, "📞"),
    glyph(r.supports_sms, "💬"),
    glyph(r.supports_mms, "🖼"),
    glyph(r.supports_emergency, "🚑"),
  ].join("");
}

/** Wholesale sample. `sample_cost_known === false` means we quoted a number
 *  Telnyx did not price — printing it as money would make a guess look
 *  measured, which is this repo's oldest standing rule. */
function wholesaleBit(r: Record<string, unknown>): string {
  if (r.sample_cost_known !== true) return "no quote";
  const cur = str(r.sample_currency) || "USD";
  const monthly = num0(r.sample_monthly_cents) / 100;
  const upfront = num0(r.sample_upfront_cents) / 100;
  const m = cur === "USD" ? usd(monthly) : `${monthly.toFixed(2)} ${cur}`;
  const u = upfront > 0
    ? ` +${cur === "USD" ? usd(upfront) : `${upfront.toFixed(2)} ${cur}`} once`
    : "";
  return `${m}/mo${u}`;
}

/** `/lines countries` — what the second-number product can actually sell, and
 *  why the rest is blocked.
 *
 *  Wholesale is printed HERE and nowhere else: it is the ops chat, and the
 *  client never sees a cost. The blocked half prints its `sell_reason` and, for
 *  a document-gated country, how many documents Telnyx wants — that number is
 *  the difference between "file two forms" and "never".
 *
 *  Counts come from the RPC (`total` / `sellable`), never from the array: the
 *  list below is capped, and a headline computed over a capped array is an
 *  artifact of the LIMIT (ops_route once read "25 of 69 bookable" against 54). */
export function formatLineCountries(raw: Record<string, unknown>): string {
  const s = obj(raw);
  const rows = arr(s.countries);
  const now = new Date();
  const total = num0(s.total);
  const sellable = num0(s.sellable);
  const sync = obj(s.sync);
  const checkedAt = ts(sync.checked_at);

  const out: string[] = [];
  // `n()` pluralises by appending "s" — "countrys" — so the plural is given.
  out.push(`🌍 <b>${esc(sellable)} sellable of ` +
           `${esc(n("country", total, "countries"))} probed</b>`);

  if (rows.length === 0) {
    out.push("");
    out.push("<i>Nothing probed yet — sync-line-countries has never written a row.</i>");
    out.push("");
    out.push(stamp(now));
    return out.join("\n");
  }

  const sell = rows.filter((r) => str(r.sell_state) === "sellable");
  const blocked = rows.filter((r) => str(r.sell_state) !== "sellable");

  if (sell.length > 0) {
    out.push("");
    out.push("<b>On sale</b>");
    const { shown, hidden } = capped(sell, 20);
    for (const r of shown) {
      const bits = [
        `✅ <b>${esc(str(r.code).toUpperCase())}</b>`,
        esc(str(r.name) || "?"),
        capStrip(r),
        esc(wholesaleBit(r)),
      ];
      if (str(r.number_type) && str(r.number_type) !== "local") {
        bits.splice(2, 0, esc(str(r.number_type)));
      }
      if (num0(r.live_lines) > 0) bits.push(`${esc(n("line", num0(r.live_lines)))} live`);
      // stock_seen is false only when a search came back empty — a country we
      // are willing to sell and cannot fill is worth seeing before a customer
      // finds it.
      if (r.stock_seen === false) bits.push("⚠️ no stock seen");
      out.push(bits.join(" · "));
    }
    if (hidden > 0) out.push(`<i>… and ${esc(hidden)} more, not shown</i>`);
  }

  if (blocked.length > 0) {
    out.push("");
    out.push(`<b>Blocked (${esc(blocked.length)})</b>`);
    const { shown, hidden } = capped(blocked, 15);
    for (const r of shown) {
      const bits = [
        `🚫 <b>${esc(str(r.code).toUpperCase())}</b>`,
        esc(str(r.name) || "?"),
        capStrip(r),
        esc(str(r.sell_reason) || "no reason recorded"),
      ];
      const docs = r.document_count;
      if (typeof docs === "number" && docs > 0) bits.push(`${esc(n("document", docs))}`);
      if (str(r.requirement_group_status)) {
        bits.push(`group ${esc(str(r.requirement_group_status))}`);
      }
      if (num0(r.live_lines) > 0) {
        // Rent we are paying in a country we will not sell again.
        bits.push(`⚠️ ${esc(n("line", num0(r.live_lines)))} still live`);
      }
      out.push(bits.join(" · "));
    }
    if (hidden > 0) out.push(`<i>… and ${esc(hidden)} more, not shown</i>`);
  }

  out.push("");
  out.push(checkedAt
    ? `<i>Probed ${esc(parisSmart(checkedAt, now))} (${esc(ago(checkedAt, now))}).</i>`
    : `<i>No sync heartbeat yet — these rows have never been refreshed.</i>`);
  out.push(`<i>📞 call · 💬 text · 🖼 MMS · 🚑 emergency; “·” means the country ` +
           `does not offer it. Wholesale is ops-only and is never shown in the app.</i>`);
  out.push(stamp(now));
  return out.join("\n");
}

// ── /route ──────────────────────────────────────────────────────────────────

/** `/route <service> [country]` — "why is X unavailable?".
 *
 *  `routes` is never queried by any other ops command, so the answer to the
 *  single most common support question ("why does this say Unavailable") lived
 *  only in a SQL console. Ordered active-first, then by the published pool rate.
 *
 *  A route reads Unavailable for one of four reasons and they are checked in
 *  this order: blocked · no price · hidden · no stock. The row prints whichever
 *  applies rather than making the reader infer it. */
export function formatRoute(raw: Record<string, unknown>): string {
  const s = obj(raw);
  const now = new Date();

  if (str(s.error) === "unknown_service") {
    const sugg = (Array.isArray(s.suggestions) ? s.suggestions : [])
      .map((x) => String(x)).slice(0, 12);
    const out = [`❓ <b>No such service</b>`];
    out.push("");
    out.push(sugg.length
      ? `Did you mean: ${esc(sugg.join(" · "))}`
      : `<i>Nothing in the catalog matches. Try a shorter word.</i>`);
    out.push("");
    out.push(stamp(now));
    return out.join("\n");
  }

  const svc = obj(s.service);
  const rows = arr(s.routes);
  const total = num0(s.routes_total) || rows.length;
  // Counted in SQL over EVERY route for the service, never over the rows this
  // reply happens to carry: `ops_route` returns at most 25, so counting the
  // rows made the headline an artifact of the LIMIT (59 active read as 25).
  const activeN = typeof s.routes_active === "number"
    ? s.routes_active
    : rows.filter((r) => str(r.status) === "active").length;

  const out: string[] = [];
  out.push(`🧭 <b>${esc(str(svc.name) || str(svc.id) || "?")} — ` +
           `${esc(activeN)} of ${esc(total)} routes bookable</b>`);
  if (svc.visible === false) {
    out.push(`⚠️ <b>the service itself is hidden</b> — no route can be booked`);
  }
  out.push("");

  if (rows.length === 0) {
    out.push(`<i>No routes at all for this service.</i>`);
    out.push("");
    out.push(stamp(now));
    return out.join("\n");
  }

  // The rows are ALREADY capped by the RPC, so `capped()` here would compute
  // hidden = 0 from a list that is itself the truncation — the "and N more"
  // line could never print. Compare against the true total instead.
  const shown = rows;
  const hidden = Math.max(0, total - rows.length);
  for (const r of shown) {
    const bits: string[] = [`<b>${esc(str(r.country_id) || "?")}</b>`,
                            esc(str(r.provider) || "?")];
    const price = r.retail_credits;
    bits.push(typeof price === "number" ? `${esc(price)}cr` : "<i>no price</i>");
    if (typeof r.premium_credits === "number") bits.push(`real SIM ${esc(r.premium_credits)}cr`);
    if (r.real_sim_only === true) bits.push("real SIM only");
    // The vendor's published rate for the exact pool this route buys from —
    // a third party's aggregate, never our own measurement.
    if (typeof r.pool_rate_pct === "number") {
      bits.push(`pool ${esc(r.pool_rate_pct)}%` +
                (str(r.pool_operator) ? ` (${esc(str(r.pool_operator))})` : ""));
    }
    // Whichever stock column this provider populates.
    const stock = [r.stock, r.fivesim_stock, r.herosms_total_count]
      .find((v) => typeof v === "number");
    if (typeof stock === "number") bits.push(`stock ${esc(stock)}`);
    if (typeof r.herosms_physical_count === "number") {
      bits.push(`real SIMs ${esc(r.herosms_physical_count)}`);
    }
    // OUR measurement, and it is stated as a raw pair. A percentage off a
    // 7-order sample wears the confidence of a 700-order one.
    if (num0(r.success_sample) > 0) {
      bits.push(`worked ${esc(num0(r.success_codes))} of ${esc(num0(r.success_sample))}` +
                (str(r.rate_source) === "seeded" ? " <i>(vendor estimate)</i>" : ""));
    }
    if (num0(r.orders_7d) > 0) {
      bits.push(`7d ${esc(num0(r.codes_7d))}/${esc(num0(r.orders_7d))}`);
    }

    // Why it cannot be booked, in the order the server checks.
    let mark = "✅";
    if (r.blocked === true) { mark = "🚫"; bits.push("<b>blocked</b>"); }
    else if (typeof price !== "number") { mark = "❌"; bits.push("<b>unpriced</b>"); }
    else if (str(r.status) !== "active") { mark = "🙈"; bits.push(`<b>${esc(str(r.status) || "hidden")}</b>`); }
    else if (typeof stock === "number" && stock === 0) { mark = "❌"; bits.push("<b>no stock</b>"); }

    if (r.last_checked_at) bits.push(`<i>${esc(ago(ts(r.last_checked_at), now))}</i>`);
    out.push(`${mark} ${bits.join(" · ")}`);
  }
  if (hidden > 0) out.push(`<i>… and ${esc(hidden)} more routes, not shown</i>`);

  out.push("");
  out.push(`<i>pool % is the supplier's own network-wide rate for that pool — ` +
           `not our delivery record. "worked N of M" is ours.</i>`);
  out.push(stamp(now));
  return out.join("\n");
}

// ── /alerts ─────────────────────────────────────────────────────────────────

/** Plain-English gloss for the watchdog check names. A check id is a grep key,
 *  not an instruction — "5sim-float" tells the owner nothing about what to do,
 *  and at 1am that is the difference between acting and ignoring. Unknown ids
 *  render with their detail alone rather than being dropped. */
const WATCHDOG_GLOSS: Record<string, string> = {
  "5sim-float": "top up 5sim or SMS orders start being refused",
  "herosms-float": "top up HeroSMS — it funds e-mail AND some SMS routes",
  "telnyx-float": "top up Telnyx or rented numbers stop being renewable",
  "esimaccess-float": "top up eSIM Access",
  "poller": "poll-active-orders is not running — no code will ever be delivered",
  "relay-http": "a cron relay is getting non-2xx — the secret may be rotated",
  "delivery-collapse": "orders are settling with zero codes",
  "delivery-degraded": "delivery rate is below the floor",
  "lines-releasing-stale": "a released number never drained — we are still paying rent",
  "lines-lapse": "a subscription lapsed and the line was not reclaimed",
  "watchdog_stale": "the watchdog itself is not running",
};

/** Render one app_config alert-state blob generically. The keys differ per
 *  alert and are added without warning (each new alert invents its own shape),
 *  so this prints what is there rather than assuming a schema: anything that
 *  parses as a time becomes Paris + age, everything else prints as key value. */
function stateLine(key: string, value: unknown, now: Date): string {
  if (value == null) return `<b>${esc(key)}</b> — <i>not set</i>`;
  if (typeof value !== "object") return `<b>${esc(key)}</b> ${esc(String(value))}`;
  const v = obj(value);
  const bits: string[] = [];
  for (const [k, raw] of Object.entries(v).slice(0, 8)) {
    if (raw == null) continue;
    const looksLikeTime = typeof raw === "string" &&
      /^\d{4}-\d{2}-\d{2}([T ]|$)/.test(raw);
    if (looksLikeTime) {
      bits.push(`${esc(k)} ${esc(parisSmart(raw, now))} <i>(${esc(ago(raw, now))})</i>`);
    } else if (typeof raw === "object") {
      bits.push(`${esc(k)} ${esc(JSON.stringify(raw).slice(0, 60))}`);
    } else {
      bits.push(`${esc(k)} ${esc(String(raw))}`);
    }
  }
  return `<b>${esc(key)}</b>` + (bits.length ? ` · ${bits.join(" · ")}` : " <i>empty</i>");
}

/** `/alerts` — what is firing RIGHT NOW, and what the alert machinery is
 *  currently sitting on.
 *
 *  Both halves are needed and neither is enough alone: the watchdog says what
 *  is broken, and the `app_config` alert states say whether the owner has
 *  already been paged about it or whether a cooldown is swallowing it. A guard
 *  reading a key nobody writes fails OPEN and SILENT — that pinned the watchdog
 *  red for three days in August — so a MISSING state is printed as missing. */
export function formatAlerts(
  input: { watchdog: unknown; states: Record<string, unknown> },
): string {
  const now = new Date();
  const wd = obj(input?.watchdog);
  const failing = arr(wd.failing);
  const states = obj(input?.states);

  const wdAgeMs = wd.checked_at ? now.getTime() - new Date(String(wd.checked_at)).getTime() : Infinity;
  const stale = wdAgeMs > 30 * 60 * 1000;

  const out: string[] = [];
  if (failing.length === 0 && !stale) {
    out.push(`🟢 <b>Nothing firing</b>` +
             (wd.checked_at ? ` — watchdog ran ${esc(ago(ts(wd.checked_at), now))}` : ""));
  } else if (stale && failing.length === 0) {
    out.push(`🚨 <b>The watchdog itself is not running</b>` +
             (wd.checked_at ? ` — last ran ${esc(ago(ts(wd.checked_at), now))}` : ""));
  } else {
    out.push(`🚨 <b>${esc(n("check", failing.length))} failing</b>` +
             (stale ? ` · <b>watchdog itself is stale</b>` : ""));
  }
  out.push("");

  if (failing.length > 0) {
    out.push(`<b>Failing now</b>`);
    for (const f of capped(failing, 12).shown) {
      const id = str(f.check) || "?";
      const gloss = WATCHDOG_GLOSS[id];
      out.push(`🚨 <b>${esc(id)}</b> — ${esc(str(f.detail))}`);
      if (gloss) out.push(`   → ${esc(gloss)}`);
    }
    const extra = capped(failing, 12).hidden;
    if (extra > 0) out.push(`<i>… and ${esc(extra)} more, not shown</i>`);
    if (wd.checked_at) {
      out.push(`<i>watchdog verdict from ${esc(parisSmart(ts(wd.checked_at), now))} ` +
               `(${esc(ago(ts(wd.checked_at), now))})</i>`);
    }
    out.push("");
  }

  const keys = Object.keys(states);
  out.push(`<b>Alert state &amp; cooldowns</b>`);
  if (keys.length === 0) {
    out.push(`<i>no alert state recorded — nothing has paged yet, or the keys ` +
             `are missing (a guard reading a key nobody writes fails open).</i>`);
  } else {
    for (const k of keys.sort()) out.push(stateLine(k, states[k], now));
  }

  out.push("");
  out.push(`<i>A cooldown suppresses a repeat page; it does not mean the ` +
           `problem cleared.</i>`);
  out.push(stamp(now));
  return out.join("\n");
}

// ── /config ─────────────────────────────────────────────────────────────────

/** The operational levers the owner turns without a deploy, in the order they
 *  cost money. Each entry: the app_config key, a human label, and how to read
 *  its value. Anything not in this list is ignored — /config is a curated view,
 *  not a table dump, and app_config also holds balances and sync cursors. */
/** `invert` exists because the KEY and the LABEL have opposite senses:
 *  `lines_paused = false` means rentals are ON. Rendering the raw flag under a
 *  product-shaped label reads as "second numbers are OFF" — the exact opposite
 *  of the truth, on the screen whose whole job is answering "what is switched
 *  on right now". */
/** Exported so `tgHandlers` queries EXACTLY these keys. It used to keep its own
 *  copy of the list; a key added here alone renders a permanent "not set",
 *  which the footer reads out as "the guard is on its own fallback" — a false
 *  alarm about a key that is set. */
export const CONFIG_KEYS: {
  key: string; label: string; kind: "n" | "bool" | "text"; invert?: boolean;
}[] = [
  { key: "signup_bonus_credits", label: "Signup grant", kind: "n" },
  { key: "email_free_daily_cap", label: "Free e-mail / day", kind: "n" },
  { key: "email_free_lifetime_grants", label: "Free e-mail / lifetime", kind: "n" },
  { key: "email_sub_daily_cap", label: "Subscriber e-mail / day", kind: "n" },
  { key: "email_subscription_enforced", label: "Mail paywall", kind: "bool" },
  { key: "lines_paused", label: "Second-number rentals", kind: "bool", invert: true },
  { key: "esim_paused", label: "eSIM line", kind: "bool", invert: true },
  { key: "line_swap_credits", label: "Number swap price", kind: "n" },
  { key: "line_swap_cooldown_days", label: "Swap cooldown", kind: "n" },
  { key: "line_orphan_release_enabled", label: "Orphan number sweep", kind: "bool" },
  { key: "maintenance", label: "Maintenance screen", kind: "text" },
  { key: "announcement", label: "Announcement", kind: "text" },
];

/** Unwrap the value shapes app_config uses. Some keys store a bare JSON scalar,
 *  some an object with the real value under `value`/`enabled`/`paused`/`n`. */
function configValue(raw: unknown): unknown {
  if (raw == null) return null;
  if (typeof raw !== "object") return raw;
  const v = obj(raw);
  // "active" is on this list because `maintenance` is `{"active": …}` and
  // NOTHING else unwrapped it: both states fell through to the object branch
  // and rendered as "empty", i.e. the flag that blanks the whole app for every
  // user read identically whether it was on or off.
  for (const k of ["value", "enabled", "paused", "active", "credits", "n", "days", "on"]) {
    if (k in v) return v[k];
  }
  return raw;
}

/** `/config` — the read-only view of every flag that changes behaviour with no
 *  release. Nine of these had NO read command at all: the only way to see them
 *  was a SQL console, which is exactly the moment you cannot get to one.
 *
 *  A MISSING key renders "not set", never a default. Several guards in this
 *  codebase read a key that nothing writes and fail open in silence; printing
 *  an assumed default here would hide precisely that. */
export function formatConfig(rows: { key: string; value: unknown }[]): string {
  const now = new Date();
  const map = new Map<string, unknown>();
  for (const r of Array.isArray(rows) ? rows : []) {
    if (r && typeof r.key === "string") map.set(r.key, r.value);
  }

  const out: string[] = [];
  const paused: string[] = [];
  if (configValue(map.get("lines_paused")) === true) paused.push("second numbers");
  if (configValue(map.get("esim_paused")) === true) paused.push("eSIM");
  out.push(`⚙️ <b>${esc(map.size)} of ${esc(CONFIG_KEYS.length)} flags set` +
           (paused.length ? ` · paused: ${esc(paused.join(" · "))}` : " · nothing paused") +
           `</b>`);
  out.push("");

  for (const spec of CONFIG_KEYS) {
    if (!map.has(spec.key)) {
      out.push(`<b>${esc(spec.label)}</b> — <i>not set</i> ` +
               `<code>${esc(spec.key)}</code>`);
      continue;
    }
    const v = configValue(map.get(spec.key));
    let rendered: string;
    if (spec.kind === "bool") {
      const on = spec.invert ? v === false : v === true;
      const off = spec.invert ? v === true : v === false;
      rendered = on ? "<b>ON</b>" : off ? "<b>OFF</b>" : `<i>${esc(String(v))}</i>`;
    } else if (spec.kind === "n") {
      rendered = typeof v === "number" ? `<b>${esc(v)}</b>` : `<i>${esc(String(v))}</i>`;
    } else {
      const raw = obj(map.get(spec.key));
      const text = str(raw.text ?? raw.message ?? (typeof v === "string" ? v : ""));
      // `active: false` WINS over leftover text. Both these keys carry a flag
      // and a body, and the body is not cleared by every path that turns the
      // flag off — rendering the text alone would show a cleared announcement
      // as if it were still on Home.
      const off = raw.active === false || v === false;
      // Owner-written text and provider text alike: esc() is mandatory.
      rendered = off
        ? `<b>OFF</b>${text ? " <i>(text still stored)</i>" : ""}`
        : text
        ? `<i>${esc(text.slice(0, 120))}${text.length > 120 ? "…" : ""}</i>`
        : (v === true ? "<b>ON</b>" : "<i>empty</i>");
      if (raw.id) rendered += ` <i>(${esc(parisSmart(ts(raw.id), now))})</i>`;
    }
    out.push(`<b>${esc(spec.label)}</b> ${rendered} <code>${esc(spec.key)}</code>`);
  }

  out.push("");
  out.push(`<i>Read-only. Change these with /esim, /lines, /announce or a ` +
           `migration — a missing key means the guard reading it is running ` +
           `on its own fallback.</i>`);
  out.push(stamp(now));
  return out.join("\n");
}
