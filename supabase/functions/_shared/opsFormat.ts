// Rendering for the ops snapshot, shared by the 6-hourly digest
// (telegram-notify) and the on-demand /stats command (telegram-webhook) so the
// two can never disagree about what a number means.

import { esc } from "./telegram.ts";

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
    /** Sandbox/Xcode receipts. Apple-signed, genuine, and worth $0 — they were
     *  counted as purchases here until 2026-08-08. Now excluded from `count`
     *  and reported on their own line, because a burst of them means somebody
     *  is buying credit packs for free. */
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
    /** Dev-account orders in the window. Excluded from every figure here, as
     *  always — reported only so an empty Numbers line can say why it is empty
     *  rather than reading as "the product is dead". */
    dev_hidden?: number;
    by_provider?: ProviderRow[];
  };
  /** Temp-EMAIL line. Same evidence shape as `orders`: `placed` counts only
   *  orders that got a usable mailbox, `settled` is the rate cohort, and
   *  `unprovisioned` (status='failed', create-email-order never provisioned
   *  one) is reported separately for the same reason `numberless` is — it is
   *  not a delivery failure. */
  emails?: {
    placed?: number; settled?: number; received?: number; failed?: number;
    pct?: number | null; cancelled?: number;
    unprovisioned?: number; free?: number; credits?: number;
  };
  esims?: { count?: number; credits?: number };
  herosms_usd?: number | null;
  fivesim_usd?: number | null;
}

/** Roughly what a credit is worth in gross revenue, for a readable estimate
 *  only. The packs run $0.598/cr (5-pack) down to $0.333/cr (150-pack); this
 *  is deliberately the middle of that range and is never presented as exact. */
const USD_PER_CREDIT = 0.45;

/** Warn below ~5x the wholesale ceiling of a single order, matching the
 *  low-balance threshold poll-active-orders alerts on.
 *
 *  This said 20 while poll-active-orders derived 7.50 * 5 = 37.50, so between
 *  $20 and $37.50 the pager fired "balance low" while the digest and /balance —
 *  the owner's only standing view — rendered the balance with no warning at all.
 *  Keep in lockstep with MAX_ORDER_COST_USD in poll-active-orders. */
const LOW_BALANCE_USD = 37.5;

/** What each provider currently pays for. Displayed next to the balance so a
 *  low reading is actionable ("which product just died?") rather than an
 *  anonymous number — the migration of 2026-07-21 swapped these roles and the
 *  digest silently kept reporting the old one. */
const ROLE: Record<string, string> = {
  // 5sim serves every SMS order since the 2026-08-03 cutover. HeroSMS is NOT
  // retired — it runs the temp-EMAIL line on the same account and balance, so
  // its reading is still load-bearing, just for a different product.
  "5sim": "SMS",
  herosms: "e-mail",
  // RETIRED 2026-08-17 — it took 7 orders in 14 days and reserved ZERO
  // numbers, so every order routed to it was a charge-and-refund. Its 5,099
  // routes are hidden, its crons are unscheduled and `providerOrder()` no
  // longer returns it. Kept in this map ONLY so historical rows in `/delivery`
  // and `/orders` still render with a name rather than a bare code — labelled
  // "retired" so a figure from before the cutover is never read as live.
  smspva: "retired",
  // Rent for the second-number line. $1 up front + $1/month per subscriber,
  // paid ~45 days ahead of Apple's payout, so this is a float number.
  telnyx: "second numbers",
  // eSIM Access funds the eSIM line (provider since 2026-08-10; line paused
  // until the account is topped up — the reading is how the owner watches the
  // deposit land).
  esimaccess: "eSIM",
};

/** A balance reading is only a fact while the poller that wrote it is alive.
 *  ops_snapshot nulls stale readings in SQL; the newer commands get the raw
 *  reading plus its timestamp so they can say WHICH failure it is — "no
 *  reading" and "a 4-hour-old reading" are different problems.
 *  (`/balance` in telegram-webhook carries its own copy of this window for its
 *  stale-poller banner; keep the two numbers equal.) */
const BALANCE_FRESH_MS = 10 * 60 * 1000;

/** Low-water mark for the Telnyx float, SEPARATE from LOW_BALANCE_USD. The
 *  SMS threshold ($37.50) is sized to single-order wholesale that can reach
 *  tens of dollars; Telnyx rent is $1/number/month + $1 upfront, so $37.50
 *  would print a permanent "top up" and train the owner to ignore the one
 *  warning that matters. $5 covers a couple of new rentals plus a month of
 *  rent on the current fleet. */
export const TELNYX_LOW_USD = 5;

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
           `${Math.round(ageMs / 60000)} min ago — poller may be dead)</i>`;
  }
  return balanceLine(name, r.balance_usd, lowUsd);
}

export function balanceLine(
  name: string, usd: number | null | undefined,
  lowUsd: number = LOW_BALANCE_USD,
): string {
  const role = ROLE[name.toLowerCase()] ?? "";
  const label = `${esc(name)}${role ? ` (${role})` : ""}`;
  // A missing reading is not the same as a healthy one: if nothing has written
  // a balance we say so, rather than omitting the line and implying all is well.
  if (typeof usd !== "number") return `❔ ${label}: <i>no reading</i>`;
  const low = usd < lowUsd;
  return `${low ? "⚠️" : "💰"} ${label}: <b>$${esc(usd.toFixed(2))}</b>` +
         (low ? " — <b>top up</b>" : "");
}

// ── /revenue ────────────────────────────────────────────────────────────────

/** Apple's commission. 15% is the Small Business Program rate (under $1M/yr);
 *  the standard rate is 30%. If vSMS is NOT enrolled in the SBP, change this to
 *  0.30 — at 24 lifetime purchases the difference is ~$24, which is a third of
 *  the profit line. Deliberately a named constant rather than a silent 0.15 in
 *  an expression, and the rate is PRINTED in the output so the number can never
 *  be read without its assumption. */
const APPLE_COMMISSION = 0.15;

/** FX into USD, used only to total a mixed-currency gross. Purchases so far
 *  arrive in USD and EUR (storefronts USA/FRA/ESP/SVK/BGR).
 *
 *  This is a hand-set rate, not a live quote — an ops bot must not depend on a
 *  third-party FX API to answer "how much did I make". The rate used is printed
 *  next to the converted figure, and any currency missing from this map is
 *  listed UNCONVERTED rather than being folded in at 1.0, because a silently
 *  wrong total is worse than an obviously incomplete one. */
const FX_TO_USD: Record<string, number> = {
  USD: 1, EUR: 1.08, GBP: 1.27, CHF: 1.12, CAD: 0.73,
  AUD: 0.66, JPY: 0.0064, PLN: 0.25, SEK: 0.092, NOK: 0.091, DKK: 0.145,
};

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

const usd = (n: number) => `$${n.toFixed(2)}`;

/** Right-aligned money column inside a <pre> block. */
function row(label: string, amount: string, width = 20, col = 11): string {
  return esc(label.padEnd(width) + amount.padStart(col));
}

function periodLabel(s: RevenueSnapshot): string {
  if (s.lifetime) return "lifetime";
  const h = s.window_hours ?? 0;
  if (h <= 24) return `last ${Math.round(h)}h`;
  const d = Math.round(h / 24);
  return d === 7 ? "last 7 days" : d === 30 ? "last 30 days" : `last ${d} days`;
}

/** `/revenue` — what customers actually PAID, in USD. Nothing derived.
 *
 *  Deliberately separate from formatRevenue (`/profit`), which nets off Apple's
 *  cut and provider wholesale to reach a profit figure. Those are estimates
 *  built on a fixed 15% commission and partially-recorded costs; this is not.
 *  Every number here comes from `iap_receipts.raw_jws` — the price Apple
 *  reports for the transaction — summed per currency.
 *
 *  The ONE piece of arithmetic that cannot be avoided is FX: Apple bills each
 *  buyer in their own storefront currency, and there is no single "total in
 *  USD" without converting. So the native amounts are always printed alongside,
 *  and any currency missing from FX_TO_USD is listed rather than folded in at
 *  1.0 — silently treating 149 SEK as $149 would overstate revenue by 10x. */
export function formatGross(
  raw: Record<string, unknown>,
  linesRaw?: Record<string, unknown> | null,
): string {
  const s = raw as RevenueSnapshot;
  const r = s.revenue ?? {};

  let grossUsd = 0;
  const native: string[] = [];
  const unconverted: string[] = [];
  for (const cur of r.by_currency ?? []) {
    const code = (cur.currency ?? "?").toUpperCase();
    const amount = (cur.gross_milli ?? 0) / 1000;
    native.push(`${esc(code)} ${amount.toFixed(2)}`);
    const rate = FX_TO_USD[code];
    if (rate == null) unconverted.push(`${esc(code)} ${amount.toFixed(2)}`);
    else grossUsd += amount * rate;
  }

  // 🔴 SUBSCRIPTION MONEY IS REVENUE AND BELONGS IN THE HEADLINE. It was shown
  // only as a separate block below, which meant the big number at the top was
  // still wrong — a $9.99 subscription is $9.99 taken, exactly like a credit
  // pack, and a renewal is another $9.99. Counted per PAYMENT EVENT from the
  // notification stream, so renewals accumulate.
  const lm = (linesRaw ?? {}) as LinesMoney;
  let subsUsd = 0;
  for (const cur of lm.by_currency ?? []) {
    const code = (cur.currency ?? "?").toUpperCase();
    const amount = (cur.gross_milli ?? 0) / 1000;
    const rate = FX_TO_USD[code];
    if (rate == null) unconverted.push(`${esc(code)} ${amount.toFixed(2)}`);
    else subsUsd += amount * rate;
  }
  const subPayments = lm.payments ?? 0;

  const purchases = r.purchases ?? 0;
  if (purchases === 0 && subPayments === 0) {
    return `💵 <b>Revenue — ${esc(periodLabel(s))}</b>\n\nNo purchases in this period.`;
  }

  const lines: string[] = [];
  lines.push(`💵 <b>Revenue — ${esc(periodLabel(s))}</b>`);
  lines.push("");
  lines.push(`<b>${esc(usd(grossUsd + subsUsd))}</b> paid by customers`);
  // The split, so the headline is auditable rather than asserted — and so
  // "how much of this recurs" is answerable at a glance.
  if (subPayments > 0) {
    lines.push(`   ${esc(usd(grossUsd))} credits · ${esc(usd(subsUsd))} subscriptions`);
  }
  lines.push("");
  lines.push(`${esc(purchases)} purchases · ${esc(r.buyers ?? 0)} buyers · ` +
             `${esc(r.credits ?? 0)} credits`);

  // Always show what was actually billed, so the USD figure is auditable
  // rather than a number the bot asserts.
  if (native.length) lines.push(`💱 ${native.join(" + ")}`);

  if (unconverted.length) {
    lines.push(`⚠️ <b>NOT included</b> (no FX rate): ${unconverted.join(" + ")}`);
  }

  const packs = (r.by_product ?? [])
    .map((p) => `${esc(p.product ?? "?")} ×${esc(p.count ?? 0)}`).join(" · ");
  if (packs) lines.push(`📦 ${packs}`);

  return lines.join("\n");
}

export function formatRevenue(
  raw: Record<string, unknown>,
  linesRaw?: Record<string, unknown> | null,
): string {
  const s = raw as RevenueSnapshot;
  const r = s.revenue ?? {};
  const c = s.cost ?? {};

  // Gross, converted. Unknown currencies are held back, never folded in at 1.0.
  let grossUsd = 0;
  const native: string[] = [];
  const unconverted: string[] = [];
  for (const cur of r.by_currency ?? []) {
    const code = (cur.currency ?? "?").toUpperCase();
    const amount = (cur.gross_milli ?? 0) / 1000;   // Apple prices are milliunits
    native.push(`${esc(code)} ${amount.toFixed(2)}`);
    const rate = FX_TO_USD[code];
    if (rate == null) unconverted.push(`${esc(code)} ${amount.toFixed(2)}`);
    else grossUsd += amount * rate;
  }

  // Subscription payments are revenue too, and Apple takes its cut of them
  // exactly as it does on a credit pack. Counted per PAYMENT EVENT, so a
  // renewal adds — summing `line_subscriptions` would have counted one row per
  // subscriber no matter how many times they renewed.
  const lm = (linesRaw ?? {}) as LinesMoney;
  let subsUsd = 0;
  for (const cur of lm.by_currency ?? []) {
    const code = (cur.currency ?? "?").toUpperCase();
    const amount = (cur.gross_milli ?? 0) / 1000;
    const rate = FX_TO_USD[code];
    if (rate == null) unconverted.push(`${esc(code)} ${amount.toFixed(2)}`);
    else subsUsd += amount * rate;
  }
  const subPayments = lm.payments ?? 0;

  const purchases = r.purchases ?? 0;
  if (purchases === 0 && subPayments === 0) {
    return `💵 <b>Revenue — ${esc(periodLabel(s))}</b>\n\nNo purchases in this period.`;
  }

  const totalGross = grossUsd + subsUsd;
  const commission = totalGross * APPLE_COMMISSION;
  const net = totalGross - commission;
  const smsUsd = (c.sms_cents ?? 0) / 100;
  const esimUsd = (c.esim_cents ?? 0) / 100;
  const devUsd = (c.dev_cents ?? 0) / 100;
  // Telnyx rent for the numbers we are holding. A RUN RATE — we cannot confirm
  // from here what was actually charged — so it is shown but NOT subtracted
  // from profit. Folding an unverified cost into a P&L is how a profit figure
  // becomes something you cannot defend.
  const rentUsd = (lm.rent_run_rate_cents ?? 0) / 100;
  const profit = net - smsUsd - esimUsd - devUsd;
  const margin = totalGross > 0 ? Math.round((profit / totalGross) * 100) : 0;

  const lines: string[] = [];
  lines.push(`💵 <b>Revenue — ${esc(periodLabel(s))}</b>`);
  lines.push("");
  lines.push("<pre>");
  lines.push(row("Gross", usd(totalGross)));
  if (subPayments > 0) {
    lines.push(row("  credits", usd(grossUsd)));
    lines.push(row("  subscriptions", usd(subsUsd)));
  }
  lines.push(row(`Apple (${Math.round(APPLE_COMMISSION * 100)}%)`, `-${usd(commission)}`));
  lines.push(esc("".padEnd(20) + "-----------"));
  lines.push(row("Net revenue", usd(net)));
  lines.push("");
  lines.push(row("SMS wholesale", `-${usd(smsUsd)}`));
  lines.push(row("eSIM wholesale", `-${usd(esimUsd)}`));
  if (devUsd > 0) lines.push(row("Test/dev orders", `-${usd(devUsd)}`));
  lines.push(esc("".padEnd(20) + "-----------"));
  lines.push(row("PROFIT", usd(profit)));
  lines.push("</pre>");
  if (rentUsd > 0) {
    lines.push(`<i>Excludes Telnyx number rent, ~${esc(usd(rentUsd))}/mo — a run ` +
               `rate we cannot confirm was charged, so it is not in the figure above.</i>`);
  }

  lines.push(`${profit >= 0 ? "📈" : "📉"} <b>${esc(margin)}% margin</b> · ` +
             `${esc(purchases)} purchases · ${esc(r.buyers ?? 0)} buyers · ` +
             `${esc(r.credits ?? 0)} credits`);

  // Show what was actually billed, so the converted total above is auditable.
  if (native.length > 1) {
    lines.push(`💱 ${native.join(" + ")} @ EUR ${esc(FX_TO_USD.EUR)}`);
  }

  const packs = (r.by_product ?? [])
    .map((p) => `${esc(p.product ?? "?")} ×${esc(p.count ?? 0)}`).join(" · ");
  if (packs) lines.push(`📦 ${packs}`);

  // Honesty lines. Each of these makes the profit figure an OVERSTATEMENT, so
  // they are warnings, not footnotes.
  const warn: string[] = [];
  const untracked = (c.sms_untracked ?? 0) + (c.esim_untracked ?? 0);
  if (untracked > 0) {
    warn.push(`⚠️ ${esc(untracked)} order(s) held a number but have no recorded ` +
              `cost (cost tracking began 13 Jul) — real spend is higher, so ` +
              `profit is an <b>upper bound</b>.`);
  }
  if ((r.unpriced ?? 0) > 0) {
    warn.push(`⚠️ ${esc(r.unpriced)} receipt(s) had no readable price — gross is understated.`);
  }
  if (unconverted.length > 0) {
    warn.push(`⚠️ NOT converted (no FX rate): ${unconverted.join(", ")}`);
  }
  if (warn.length > 0) { lines.push(""); lines.push(...warn); }

  return lines.join("\n");
}

export function formatDigest(
  raw: Record<string, unknown>,
  linesRaw?: Record<string, unknown> | null,
): string {
  const s = raw as Snapshot;
  const hours = s.window_hours ?? 6;
  const o = s.orders ?? {};
  const placed = o.placed ?? 0;

  const lines: string[] = [];
  lines.push(`📊 <b>${esc(windowWords(hours))}</b>`);
  lines.push("");
  lines.push(`👤 Signups: <b>${s.signups ?? 0}</b>`);

  const buys = s.purchases ?? {};
  if ((buys.count ?? 0) > 0) {
    const usd = ((buys.credits ?? 0) * USD_PER_CREDIT).toFixed(2);
    lines.push(`💳 Purchases: <b>${buys.count}</b> · ${buys.credits} credits · ~$${esc(usd)}`);
  } else {
    lines.push(`💳 Purchases: <b>0</b>`);
  }
  // Production-only above. A Sandbox receipt is a genuine Apple-signed
  // transaction that moved $0, and this digest counted them as sales until
  // 2026-08-08. Shown rather than dropped: several in a window means somebody
  // switched their Apple ID to a Sandbox account and is taking packs for free.
  if ((buys.sandbox ?? 0) > 0) {
    lines.push(`   ⚠️ ${buys.sandbox} Sandbox receipt(s) — $0 paid, not counted`);
  }

  // Subscription money, on its own line rather than folded into the one above.
  //
  // ⚠️ THE TWO FIGURES ARE NOT THE SAME KIND OF NUMBER. The credits line is an
  // ESTIMATE — `ops_snapshot` counts credits, not receipts, so it multiplies by
  // a mid-range USD_PER_CREDIT and marks itself with a `~`. Subscription
  // revenue is EXACT, read from the signed price on each payment event. Adding
  // an exact figure to an estimate and printing one total would launder the
  // approximation into something that looks precise, so they stay apart.
  const lm = (linesRaw ?? {}) as LinesMoney;
  const subPayments = lm.payments ?? 0;
  if (subPayments > 0) {
    let subUsd = 0;
    for (const cur of lm.by_currency ?? []) {
      const rate = FX_TO_USD[(cur.currency ?? "?").toUpperCase()];
      if (rate != null) subUsd += ((cur.gross_milli ?? 0) / 1000) * rate;
    }
    const renewals = lm.renewals ?? 0;
    const renewNote = renewals > 0
      ? ` · ${renewals} renewal${renewals === 1 ? "" : "s"}`
      : "";
    lines.push(`📞 Subscriptions: <b>${subPayments}</b> · ` +
               `<b>$${esc(subUsd.toFixed(2))}</b>${renewNote}`);
  }
  // A free trial takes no money but DOES rent a number, so it is a cost with no
  // revenue — invisible if only paid events were reported.
  if ((lm.trials ?? 0) > 0) {
    lines.push(`   <i>${lm.trials} free trial${lm.trials === 1 ? "" : "s"} — $0</i>`);
  }

  lines.push("");
  if (placed > 0) {
    const settled = o.settled ?? 0;
    lines.push(`📱 <b>Numbers</b> — ${placed} got a number`);
    // The rate is over SETTLED orders, never over every numbered one. A user
    // cancel measures impatience: cancels land at a median 57s while codes land
    // at a median 58s, and cancelled orders deliver ~1%. Denominator stated
    // explicitly so the figure cannot be read without its sample.
    if (settled > 0) {
      // RECONCILE THE DENOMINATOR. "92 got a number" followed by "16/47" makes
      // the reader hunt for where 47 came from, and the honest answer — that
      // cancels and default-landed orders are excluded because neither measures
      // delivery — is exactly what the line should say out loud.
      lines.push(`   ✅ <b>${o.received ?? 0} of ${settled}</b> delivered ` +
                 `(<b>${o.pct ?? 0}%</b>)`);
      // ⚠️ NO SUBTRACTED COUNT HERE. `placed - settled` looks like it should
      // equal the cancelled + app-picked lines below, and it does not: an order
      // can be BOTH, so the categories overlap and the arithmetic visibly fails.
      // Printing a number the reader can try to reconcile and can't is worse
      // than the bare "16/47" this replaced. Name the reason, not a figure.
      if (placed > settled) {
        lines.push(`   <i>of ${placed} numbered — cancels and app-picked ` +
                   `numbers aren't judged</i>`);
      }
    } else {
      lines.push(`   ⏳ nothing settled yet — no rate to report`);
    }
    if ((o.cancelled ?? 0) > 0) {
      lines.push(`   ✖ ${o.cancelled} cancelled by the user <i>(not counted)</i>`);
    }
    if ((o.waiting ?? 0) > 0) lines.push(`   ⏳ ${o.waiting} still waiting`);
    // A delivery we made that is deliberately outside the rate.
    if ((o.rescued ?? 0) > 0) {
      lines.push(`   🎁 ${o.rescued} code(s) landed after a cancel (refund stood)`);
    }
    // The app's own pre-selection. Settled by hand on 2026-08-04: a cancelled
    // deliveroo/us number was used manually and the code arrived, so these are
    // not evidence about delivery at all — nobody ever submitted the number.
    if ((o.default_landed ?? 0) > 0) {
      lines.push(`   ↩︎ ${o.default_landed} the app picked for them ` +
                 `<i>(never used — not counted)</i>`);
    }

    // Only worth the extra lines when providers actually differ — during and
    // after a migration the blended rate averages a dead provider with a live
    // one and describes neither.
    const rows = (o.by_provider ?? []).filter((r) => (r.placed ?? 0) > 0);
    if (rows.length > 1) {
      lines.push(`   <i>by provider</i>`);
      for (const r of rows) {
        const st = r.settled ?? 0;
        lines.push(`   · ${esc(r.provider ?? "?")}: ` +
                   (st > 0
                     ? `${r.received ?? 0}/${st} (${r.pct ?? 0}%)`
                     : `${r.placed ?? 0} numbered, none settled`) +
                   ((r.cancelled ?? 0) > 0 ? ` · ${r.cancelled} cancelled` : ""));
      }
    }
  } else {
    // Say WHY it is empty when the dev account was the only thing ordering.
    // Every figure here excludes dev by design, so an owner testing the app
    // watches their own order vanish and reads "none ordered" as an outage.
    // Reported 2026-08-05 as "I see people ordering numbers yet I don't see
    // that on the telegram stats" — it was one dev order and two real
    // purchases, all behaving correctly.
    const dev = o.dev_hidden ?? 0;
    lines.push(dev > 0
      ? `📱 Numbers: none ordered · ${dev} dev order${dev === 1 ? "" : "s"} hidden`
      : `📱 Numbers: none ordered`);
  }

  // Orders that never got a number: charged and instantly refunded because the
  // price cleared our ceiling, the route was dry, or the provider errored.
  // These are NOT delivery failures and are excluded from the rate above — but
  // they must be visible, because a provider whose prices drift above our
  // margin gate produces them in volume and it looks like nothing at all.
  const numberless = o.numberless ?? 0;
  if (numberless > 0) {
    lines.push(`   ⚠️ ${numberless} never got a number (price/stock, refunded)`);
  }

  // Temp e-mail, rendered in the same shape as Numbers so the two read as one
  // activity view. It was absent from every ops surface from launch (07-30)
  // until 08-05 — 29 orders across 10 users with no operational visibility.
  //
  // `free` is always shown when non-zero: 28 of the first 29 orders were the
  // free tier, so an order count alone reads as revenue when it is nearly all
  // cost. Same honesty rule as printing the FX rate next to /revenue.
  lines.push("");
  const m = s.emails ?? {};
  const mailPlaced = m.placed ?? 0;
  const unprovisioned = m.unprovisioned ?? 0;
  if (mailPlaced > 0 || unprovisioned > 0) {
    const freeNote = (m.free ?? 0) > 0 ? ` · ${m.free} free` : "";
    lines.push(`📧 <b>E-mails</b> — ${mailPlaced} ordered${freeNote}`);
    // Same cancel rule as Numbers. The e-mail line has a provider-enforced
    // 2-minute cancel floor, so a cancel here is still a user decision and not
    // a mailbox that failed to receive.
    const mailSettled = m.settled ?? 0;
    if (mailSettled > 0) {
      lines.push(`   ✅ <b>${m.received ?? 0} of ${mailSettled}</b> delivered ` +
                 `(<b>${m.pct ?? 0}%</b>)`);
    } else if (mailPlaced > 0) {
      lines.push(`   ⏳ nothing settled yet — no rate to report`);
    }
    if ((m.cancelled ?? 0) > 0) lines.push(`   ✖ ${m.cancelled} cancelled by the user`);
    // The mailbox itself was never issued — the e-mail analogue of a numberless
    // SMS order, and deliberately outside the rate above. Five of these in one
    // 7-minute burst is what exposed the free tier running dry.
    if (unprovisioned > 0) {
      lines.push(`   ⚠️ ${unprovisioned} never got an address (stock, refunded)`);
    }
  } else {
    lines.push(`📧 E-mails: none ordered`);
  }

  const e = s.esims ?? {};
  if ((e.count ?? 0) > 0) {
    lines.push("");
    lines.push(`🌍 <b>eSIMs</b> — ${e.count} sold · ${e.credits} credits`);
  }

  lines.push("");
  // HeroSMS first — it serves SMS for the services carrying 99.4% of volume.
  // SMSPVA and SMSPool are gone from this block on purpose: SMSPVA no longer
  // serves anything and eSIMs are paused, so their balances were two lines of
  // noise on the one channel that has to stay readable.
  lines.push("<b>Float</b>");
  lines.push(balanceLine("5sim", s.fivesim_usd));
  lines.push(balanceLine("HeroSMS", s.herosms_usd));

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

/** Telegram hard-limits a message at 4096 chars. Cap the row list well under
 *  that and SAY SO when rows are dropped — a silently truncated list reads as
 *  "that was everything", which is the failure mode this codebase keeps
 *  paying for elsewhere (see the no-silent-caps rule). */
const MAX_ROWS = 35;

/** One order per line: outcome, time, route, what we charged and paid.
 *
 *  Outcome is driven by `got_code` (i.e. `otp is not null`), never by
 *  `status = 'received'` — a code rescued after a cancel lives on a `canceled`
 *  row, and reading status would report a delivered code as a failure.
 *
 *  `held_s` is on every line because it is the single most diagnostic number
 *  here: cancels cluster far below the p90 arrival, and seeing "✖ … 8s" next to
 *  "✅ … 58s" makes the difference legible at a glance. */
export function formatOrders(raw: Record<string, unknown>, windowLabel: string): string {
  const s = raw as {
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
  lines.push(`📋 <b>Orders · last ${esc(windowLabel)}</b>`);

  if (total === 0) {
    lines.push("");
    lines.push("<i>No SMS orders in this window.</i>");
  } else {
    const numbered = s.numbered ?? 0;
    const delivered = s.delivered ?? 0;
    // Rate is over orders that actually held a number AND that the user let
    // run AND that the user chose. Orders that died inside create-order never
    // reserved anything; a cancel measures impatience, not the provider; and a
    // default-landed order was never entered anywhere by anyone. All three get
    // their own line instead of dragging the rate down.
    const settled = s.settled ?? 0;
    const settledCodes = s.settled_codes ?? 0;
    const pct = settled > 0 ? Math.round((settledCodes / settled) * 100) : null;

    lines.push("");
    lines.push(`<b>${total}</b> orders · <b>${numbered}</b> got a number · ` +
               (settled > 0
                 ? `<b>${settledCodes}/${settled}</b> delivered (${pct}%)`
                 : `<i>nothing settled yet</i>`));

    const bits: string[] = [];
    if ((s.cancelled ?? 0) > 0) bits.push(`${s.cancelled} cancelled`);
    if ((s.expired ?? 0) > 0) bits.push(`${s.expired} expired`);
    if ((s.waiting ?? 0) > 0) bits.push(`${s.waiting} still waiting`);
    if ((s.no_number ?? 0) > 0) bits.push(`${s.no_number} never got a number`);
    if ((s.default_landed ?? 0) > 0) bits.push(`${s.default_landed} our own pick`);
    if ((s.rescued ?? 0) > 0) bits.push(`${s.rescued} rescued after a cancel`);
    if (bits.length) lines.push(`<i>${esc(bits.join(" · "))}</i>`);
    // Say what the rate leaves out, but only when it actually left something
    // out — otherwise it is a caveat about nothing.
    if (settled > 0 && (settled !== numbered || delivered !== settledCodes)) {
      lines.push(`<i>rate excludes cancels and our own pre-selection ` +
                 `(${delivered} code${delivered === 1 ? "" : "s"} in total)</i>`);
    }

    lines.push(`💸 Wholesale paid: <b>$${esc(((s.spend_cents ?? 0) / 100).toFixed(2))}</b>`);
    lines.push("");

    for (const r of rows.slice(0, MAX_ROWS)) {
      const mark = r.got_code ? "✅" : r.status === "waiting" ? "⏳" : "✖";
      const t = (r.created_at ?? "").slice(11, 16);            // HH:MM UTC
      const route = `${r.service_id ?? "?"}·${r.country_id ?? "?"}`;
      const paid = r.actual_cost_cents != null ? `/$${(r.actual_cost_cents / 100).toFixed(2)}` : "";
      const extra: string[] = [];
      if (!r.got_number) extra.push("no number");
      else if (!r.got_code) extra.push(r.status === "canceled" ? "cancelled" : (r.status ?? ""));
      if (r.tier === "premium") extra.push("real SIM");
      // Flagged because it changes what the row MEANS: the user did not pick
      // this route, so a missing code here says nothing about the pool.
      if (r.from_default) extra.push("our pick");
      if (r.is_dev) extra.push("dev");
      const tail = extra.filter(Boolean).join(", ");
      lines.push(`${mark} <code>${esc(t)}</code> ${esc(route)} · ` +
                 `${r.cost_credits ?? 0}cr${esc(paid)} · ${r.held_s ?? 0}s` +
                 (tail ? ` · <i>${esc(tail)}</i>` : ""));
    }
    if (rows.length > MAX_ROWS) {
      lines.push(`<i>… and ${rows.length - MAX_ROWS} older, not shown</i>`);
    }
  }

  // Other product lines get a count, not a row list — they have no route and
  // no delivery semantics comparable to a number, and folding them into the
  // rate above would blend three different products into one figure.
  const em = s.email ?? {}, es = s.esim ?? {};
  const otherBits: string[] = [];
  if ((em.total ?? 0) > 0) otherBits.push(`📧 e-mail ${em.total} (${em.received ?? 0} received)`);
  if ((es.total ?? 0) > 0) otherBits.push(`📶 eSIM ${es.total}`);
  if (otherBits.length) {
    lines.push("");
    lines.push(otherBits.join(" · "));
  }

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
 *  people who arrived, how many ordered / paid), never ratio-of-totals: a window
 *  holding yesterday's buyers and today's signups would otherwise produce a
 *  figure describing nobody. Measured here, activation is a single-session event
 *  — median signup → first order 123 seconds — so "ever ordered" and "ordered in
 *  this window" are the same population in practice.
 *
 *  The signup grant is printed because it is the thing that most changes these
 *  numbers and it moves with no release: it has been 5, 0, 1, 3, 0 and 2 within
 *  days. Read live from app_config; a MISSING row is printed as missing, never
 *  as zero. */
export function formatFunnel(raw: Record<string, unknown>): string {
  const s = raw as {
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
  const pct = (n: number) => signups > 0 ? `${Math.round((n / signups) * 1000) / 10}%` : "—";

  const lines: string[] = [];
  lines.push(`📈 <b>Funnel · last ${esc(s.days ?? 7)} days</b>`);
  lines.push("");

  // <pre> so the columns line up in Telegram's monospace font. Six narrow
  // columns fit a phone; anything wider wraps and stops being a table.
  lines.push("<pre>");
  lines.push(esc("date  sgn usr ord num cod buy"));
  for (const r of rows) {
    const day = String(r.d ?? "").slice(5);           // MM-DD
    lines.push(esc(
      day.padEnd(5) +
      String(r.signups ?? 0).padStart(4) +
      String(r.users_ordering ?? 0).padStart(4) +
      String(r.orders ?? 0).padStart(4) +
      String(r.numbered ?? 0).padStart(4) +
      String(r.codes ?? 0).padStart(4) +
      String(r.buys ?? 0).padStart(4),
    ));
  }
  lines.push("</pre>");

  lines.push(`👤 <b>${signups}</b> signups → <b>${t.activated ?? 0}</b> ordered ` +
             `(${esc(pct(t.activated ?? 0))}) → <b>${t.buyers ?? 0}</b> bought ` +
             `(${esc(pct(t.buyers ?? 0))})`);
  lines.push(`<i>both % are of the ${signups} who signed up in this window</i>`);
  lines.push(`📱 ${t.orders ?? 0} orders · ${t.numbered ?? 0} got a number · ` +
             `${t.codes ?? 0} codes`);
  lines.push(`💳 ${t.buys ?? 0} purchases · ${t.credits ?? 0} credits`);

  // The grant decides WHICH single route new users land on, not just how much
  // they can buy, so it belongs next to the activation rate.
  lines.push(typeof s.signup_grant === "number"
    ? `🎁 Signup grant: <b>${s.signup_grant}</b> credit${s.signup_grant === 1 ? "" : "s"}`
    : `🎁 Signup grant: <i>no reading</i> — app_config.signup_bonus_credits missing`);

  // Only when there are any. These are orders on the app's own pre-selection:
  // the user never chose the service and never submitted the number, so they
  // are excluded from every delivery rate in the bot.
  if ((t.default_landed ?? 0) > 0) {
    lines.push(`↩︎ default-landed: <b>${t.default_landed}</b> ` +
               `<i>— our own pre-selection, not delivery evidence</i>`);
  }

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
 *  and refusals are printed in their own columns so the sample the rate uses is
 *  always visible beside the sample it does not. */
export function formatDelivery(raw: Record<string, unknown>, windowLabel: string): string {
  const s = raw as {
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

  const lines: string[] = [];
  lines.push(`📶 <b>Delivery · last ${esc(windowLabel)}</b>`);
  lines.push("");

  if (rows.length === 0) {
    lines.push("<i>No SMS orders in this window.</i>");
  } else {
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
    lines.push(`<i>num=got a number · set=settled (not cancelled, not our own ` +
               `pick) · cod=codes · can=cancelled · ref=refused before a number</i>`);

    const extra: string[] = [];
    if ((tot.waiting ?? 0) > 0) extra.push(`${tot.waiting} still waiting`);
    if ((tot.rescued ?? 0) > 0) extra.push(`${tot.rescued} rescued after a cancel`);
    if ((tot.default_landed ?? 0) > 0) {
      extra.push(`${tot.default_landed} on our own pre-selection`);
    }
    if (extra.length) lines.push(`<i>${esc(extra.join(" · "))}</i>`);
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
    lines.push("🟢 watchdog: all jobs healthy");
  } else {
    for (const f of failing) {
      lines.push(`🚨 watchdog: <b>${esc(f.check)}</b> — ${esc(f.detail ?? "")}`);
    }
  }

  // 7k+ SMSPVA routes are held shut by the reservation-collapse guard. Printed
  // because "the catalog looks small" needs a legible cause, and because a
  // resync could reopen them.
  const hidden = s.smspva_hidden_routes;
  if (typeof hidden === "number") {
    lines.push(`🙈 SMSPVA routes hidden: <b>${hidden}</b> ` +
               `<i>(reservation-collapse guard)</i>`);
  }

  // One line per provider, ALWAYS. An omitted balance reads as healthy, which
  // is exactly the failure that hid SMSPVA having no monitoring at all while it
  // served 100% of SMS.
  for (const b of s.balances ?? []) lines.push(balanceLineFrom(b));

  return lines.join("\n");
}

// ── /subs ───────────────────────────────────────────────────────────────────

/** List price of the Second Number subscription, per month, in the USA base
 *  territory. The MRR below is an ESTIMATE off this figure and says so; the
 *  actual per-currency amounts Apple billed are printed beside it whenever any
 *  active subscription carries them, for the same reason /revenue prints its FX
 *  rate — an estimate must be auditable rather than asserted. */
const LINE_PRICE_USD = 9.99;

/** `/subs` — the Second Number line.
 *
 *  It renders all-zero today and that is the point. This is the product whose
 *  lifecycle shipped with `reclaim_lapsed_lines()` scheduled in no cron job and
 *  `release-lines` never written: an ordinary Apple cancellation left the number
 *  rented at $1/month forever, discoverable only on the Telnyx invoice. So the
 *  subscription state and the LINE state are shown side by side, and a
 *  divergence between them is called out rather than left to be noticed. */
export function formatSubs(raw: Record<string, unknown>): string {
  const s = raw as {
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
    dev_hidden?: { lines?: number; subs?: number };
    mail?: {
      total?: number; active?: number;
      by_state?: { state?: string; n?: number }[];
      auto_renew_on?: number;
    };
  };

  const active = s.subs_active ?? 0;
  const lines: string[] = [];
  lines.push("📞 <b>Second Number</b>");
  lines.push("");

  if ((s.subs_total ?? 0) === 0) {
    lines.push("<i>No subscribers yet.</i>");
  } else {
    const states = (s.subs_by_state ?? [])
      .map((r) => `${esc(r.state ?? "?")} ${r.n ?? 0}`).join(" · ");
    lines.push(`📜 Subscriptions: <b>${s.subs_total}</b> — ${states}`);
    // One row per subscription: plan, running vs cancelled, expiry. auto_renew
    // is ASSN-authoritative (20260815100000); "cancelled" here means auto-renew
    // off — the line stays live until the period ends, so state stays 'active'.
    // A zero billed price is rendered as a free period: an inference from
    // price_milli = 0 (offerType is not persisted), never a tracked fact.
    for (const r of s.subs_list ?? []) {
      const pid = r.product ?? "";
      const plan = pid.endsWith(".line.monthly") ? "monthly"
        : pid.endsWith(".line.yearly") ? "yearly"
        : (pid || "?");
      const free = r.price_milli === 0 ? " · free period" : "";
      const env = r.environment && r.environment !== "Production"
        ? ` · ${esc(r.environment)}` : "";
      const until = r.expires_at ? esc(r.expires_at.slice(5, 10)) : "?";
      const status = r.state === "active"
        ? (r.auto_renew !== false
            ? `▶️ running — renews ${until}`
            : `🔕 cancelled — ends ${until}`)
        : `${esc(r.state ?? "?")} — ${until}`;
      lines.push(`   • ${esc(plan)}${free}${env} · ${status}`);
    }
    if ((s.subs_not_shown ?? 0) > 0) {
      lines.push(`   <i>… and ${s.subs_not_shown} older, not shown</i>`);
    }
  }

  if ((s.lines_total ?? 0) === 0) {
    lines.push("<i>No numbers rented.</i>");
  } else {
    const st = (s.lines_by_status ?? [])
      .map((r) => `${esc(r.status ?? "?")} ${r.n ?? 0}`).join(" · ");
    lines.push(`📱 Lines: <b>${s.lines_total}</b> — ${st}`);
    const bill = (s.lines_by_billing ?? [])
      .map((r) => `${esc(r.billing ?? "?")} ${r.n ?? 0}`).join(" · ");
    if (bill) lines.push(`   billed: ${bill} <i>(only 'apple' earns the MRR below)</i>`);
    const rent = (s.monthly_cost_cents ?? 0) / 100;
    if (rent > 0) lines.push(`   💸 provider rent: <b>$${esc(rent.toFixed(2))}</b>/mo`);
  }

  // ── Temp-e-mail subscription (Task 9, 2026-08-19) ──────────────────────────
  //
  // Built dark: `app_config.email_subscription_enforced` is false, so this
  // renders `total: 0` until a real subscriber exists — see CLAUDE.md's
  // "Temp-e-mail subscription" section for why it stays off. Mirrors the line
  // block above (state totals, then a disagreement warning) rather than
  // inventing a new shape, for the same reason the line block exists: a
  // divergence should be called out, not left for someone to notice by hand.
  const mail = s.mail ?? {};
  lines.push("");
  lines.push("📧 <b>Temp-mail subscription</b>");
  if ((mail.total ?? 0) === 0) {
    lines.push("<i>No subscribers yet — enforcement is OFF " +
               "(app_config.email_subscription_enforced = false).</i>");
  } else {
    const mstates = (mail.by_state ?? [])
      .map((r) => `${esc(r.state ?? "?")} ${r.n ?? 0}`).join(" · ");
    lines.push(`📜 Subscriptions: <b>${mail.total}</b> — ${mstates}`);
    lines.push(`   entitled now: <b>${mail.active ?? 0}</b> · ` +
               `auto-renew on: <b>${mail.auto_renew_on ?? 0}</b>`);
    // "entitled" (state in active/grace AND not yet past its expiry/grace
    // timestamp — has_email_subscription()'s own predicate) vs the RAW
    // active/grace state count from by_state, with no expiry filter. The two
    // read the SAME table, so they should always match; a gap means a
    // subscription is sitting in 'active'/'grace' state past the moment its
    // own expiry says it should have lapsed — an ASSN notification (EXPIRED /
    // grace-period-ended) that has not landed or has not been processed yet.
    const stateActive = (mail.by_state ?? [])
      .filter((r) => r.state === "active" || r.state === "grace")
      .reduce((a, r) => a + (r.n ?? 0), 0);
    const entitled = mail.active ?? 0;
    if (entitled !== stateActive) {
      lines.push(`⚠️ <b>${entitled} entitled vs ${stateActive} in an ` +
                 `active/grace state</b> — these should match. A row stuck in ` +
                 `'active'/'grace' past its own expiry means an ASSN ` +
                 `notification for this subscription has not landed or has not ` +
                 `been processed yet.`);
    }
  }

  // Est. net MRR. The commission rate is PRINTED next to it, exactly as
  // /profit does — a margin figure must never be readable without its
  // assumption, and 15% vs 30% is the difference between this line being right
  // and being 18% out.
  const net = LINE_PRICE_USD * (1 - APPLE_COMMISSION);
  lines.push("");
  lines.push(`💵 Est. net MRR: <b>${esc(usd(active * net))}</b>`);
  lines.push(`<i>${active} active × $${esc(LINE_PRICE_USD.toFixed(2))} list − Apple ` +
             `${Math.round(APPLE_COMMISSION * 100)}% (Small Business Program) = ` +
             `${esc(usd(net))} each</i>`);
  const billed = (s.active_billed ?? [])
    .map((b) => `${esc((b.currency ?? "?").toUpperCase())} ` +
                `${((b.milli ?? 0) / 1000).toFixed(2)} ×${b.n ?? 0}`).join(" + ");
  if (billed) lines.push(`💱 actually billed: ${billed}`);

  // ⚠️ Reported as untracked, never as "0 trials". line_sub_state has no trial
  // member and ASSN's offerType is not persisted, so a zero here would be an
  // assertion we cannot make.
  if (s.trials_tracked !== true) {
    lines.push(`🧪 Trials: <i>"free period" above is inferred from a $0 billed ` +
               `price — no offer-type column exists, so there is no tracked count</i>`);
  }

  // A live line whose subscription is gone is rent we pay for nothing; a live
  // subscription with no line is a customer paying for nothing. Both are
  // silent, and both have happened.
  const activeLines = (s.lines_by_status ?? [])
    .filter((r) => ["active", "grace", "past_due"].includes(r.status ?? ""))
    .reduce((a, r) => a + (r.n ?? 0), 0);
  if (active !== activeLines) {
    lines.push(`⚠️ <b>${active} active sub(s) vs ${activeLines} live line(s)</b> — ` +
               `these should match. A line with no subscription is rent we are ` +
               `paying for nothing; a subscription with no line is a customer ` +
               `paying for nothing.`);
  }

  const notifs = s.notifications_7d ?? [];
  if (notifs.length === 0) {
    lines.push("🔔 ASSN last 7d: <i>none</i>");
  } else {
    lines.push(`🔔 ASSN last 7d: ` + notifs.map((n) =>
      `${esc(n.type ?? "?")}${n.subtype ? `/${esc(n.subtype)}` : ""} ×${n.n ?? 0}`,
    ).join(" · "));
    const stuck = notifs.reduce((a, n) => a + (n.unprocessed ?? 0), 0);
    const bad = notifs.reduce((a, n) => a + (n.errored ?? 0), 0);
    if (stuck > 0 || bad > 0) {
      lines.push(`   ⚠️ ${stuck} unprocessed · ${bad} errored — a dropped ` +
                 `notification is a lapse the line state machine never sees`);
    }
  }

  lines.push(balanceLineFrom({ provider: "Telnyx", ...(s.telnyx ?? {}) },
                             TELNYX_LOW_USD));

  const dev = s.dev_hidden ?? {};
  if ((dev.lines ?? 0) > 0 || (dev.subs ?? 0) > 0) {
    lines.push(`<i>dev account hidden: ${dev.lines ?? 0} line(s), ` +
               `${dev.subs ?? 0} sub(s) — they cost real rent</i>`);
  }

  return lines.join("\n");
}

// ── Second-number line money ───────────────────────────────────────────────
//
// 🔴 `/revenue` AND `/profit` REPORT $0 FOR THIS PRODUCT AND ALWAYS HAVE.
// Subscription purchases land in `line_subscriptions` and never in
// `iap_receipts`, and `revenue_snapshot` reads only the latter — so the one
// thing that bills monthly is invisible in the money commands. Verified
// 2026-08-17: zero `iap_receipts` rows for a line product, against $19.98
// actually collected.
//
// Rendered as its own block rather than folded into the totals, because
// subscription revenue and credit-pack revenue answer different questions and
// merging them would hide the number that matters here: how much RECURS.

interface LinesMoney {
  by_currency?: CurrencyRow[];
  /** Paid events in the window: first charges PLUS renewals. Derived from the
   *  notification stream, never from `line_subscriptions` — that table holds
   *  one row per subscription, so a renewal updates it instead of adding, and
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

/** The line's money, appended to `/revenue` and `/profit`.
 *
 *  ⚠️ COLLECTED AND RECURRING ARE REPORTED SEPARATELY, and that separation is
 *  the whole point. Every subscriber so far switched auto-renew off within 16
 *  minutes of paying, so "collected $19.98" without "renews: $0" would be true
 *  and badly misleading — the exact class of confidently-wrong figure these
 *  commands are being cleaned up to remove. */
export function formatLinesMoney(raw: Record<string, unknown>): string {
  const s = raw as LinesMoney;
  const active = s.active ?? 0;
  const trials = s.trials ?? 0;
  const payments = s.payments ?? 0;
  const numbers = s.numbers_live ?? 0;

  if (active === 0 && payments === 0 && numbers === 0) {
    return "\n\n📞 <b>Second numbers</b>\nNothing sold yet.";
  }

  // The MONEY is already in the headline total above. This block answers the
  // question the headline cannot: how much of it recurs, and what it costs to
  // keep the numbers alive.
  const out = ["", "", "📞 <b>Second numbers</b>"];
  const firsts = s.first_buys ?? 0;
  const renewals = s.renewals ?? 0;
  if (payments > 0) {
    out.push(`Payments: <b>${payments}</b> — ${firsts} new · ${renewals} renewal${renewals === 1 ? "" : "s"}`);
  }

  // The number the owner actually needs. A subscription that will not renew is
  // a one-off sale wearing a subscription's clothes.
  const mrr = (s.mrr_milli ?? 0) / 1000;
  const renewing = s.renewing ?? 0;
  if (renewing === 0) {
    out.push(
      `Recurring: <b>$0.00</b> — none of the ${active} active sub${active === 1 ? "" : "s"} will renew`,
    );
  } else {
    const cur = (s.mrr_currency ?? "USD").toUpperCase();
    const rate = FX_TO_USD[cur] ?? 1;
    out.push(`Recurring: <b>$${(mrr * rate).toFixed(2)}/mo</b> from ${renewing} renewing`);
  }
  if (trials > 0) {
    out.push(`   <i>${trials} free trial${trials === 1 ? "" : "s"} — paid nothing</i>`);
  }

  // Cost, stated as a RUN RATE. We hold this float ~45 days ahead of Apple's
  // payout and cannot verify from here what Telnyx actually charged — so it is
  // never folded into a profit figure, only shown beside it.
  const rent = (s.rent_run_rate_cents ?? 0) / 100;
  if (numbers > 0) {
    const credit = s.credit_rented ?? 0;
    const suffix = credit > 0 ? ` (${credit} rented with credits)` : "";
    out.push(
      `Numbers live: <b>${numbers}</b>${suffix} · rent <b>$${rent.toFixed(2)}/mo</b>`,
    );
  }
  return out.join("\n");
}

/** "Last 7 days", not "Last 168h".
 *
 *  The digest led with a raw hour count, so the first thing the reader had to
 *  do was arithmetic — and 168h/720h are exactly the windows nobody converts in
 *  their head. The snapshot still carries hours; only the label changes. */
function windowWords(hours: number): string {
  if (hours < 1) return "Last hour";
  if (hours < 24) return `Last ${Math.round(hours)} hours`;
  const days = Math.round(hours / 24);
  if (days === 1) return "Last 24 hours";
  if (days === 7) return "Last 7 days";
  if (days === 30 || days === 31) return "Last 30 days";
  return `Last ${days} days`;
}
