// Rendering for the ops snapshot, shared by the 6-hourly digest
// (telegram-notify) and the on-demand /stats command (telegram-webhook) so the
// two can never disagree about what a number means.

import { esc } from "./telegram.ts";

interface ProviderRow {
  provider?: string;
  placed?: number;
  received?: number;
  failed?: number;
  pct?: number | null;
}

interface Snapshot {
  window_hours?: number;
  signups?: number;
  purchases?: { count?: number; credits?: number };
  orders?: {
    placed?: number; received?: number; failed?: number; pct?: number | null;
    /** Charged-and-refunded attempts that never reserved a number. Excluded
     *  from `placed` so they cannot masquerade as delivery failures. */
    numberless?: number;
    by_provider?: ProviderRow[];
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
};

export function balanceLine(name: string, usd: number | null | undefined): string {
  const role = ROLE[name.toLowerCase()] ?? "";
  const label = `${esc(name)}${role ? ` (${role})` : ""}`;
  // A missing reading is not the same as a healthy one: if nothing has written
  // a balance we say so, rather than omitting the line and implying all is well.
  if (typeof usd !== "number") return `❔ ${label}: <i>no reading</i>`;
  const low = usd < LOW_BALANCE_USD;
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
export function formatGross(raw: Record<string, unknown>): string {
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

  const purchases = r.purchases ?? 0;
  if (purchases === 0) {
    return `💵 <b>Revenue — ${esc(periodLabel(s))}</b>\n\nNo purchases in this period.`;
  }

  const lines: string[] = [];
  lines.push(`💵 <b>Revenue — ${esc(periodLabel(s))}</b>`);
  lines.push("");
  lines.push(`<b>${esc(usd(grossUsd))}</b> paid by customers`);
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

export function formatRevenue(raw: Record<string, unknown>): string {
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

  const purchases = r.purchases ?? 0;
  if (purchases === 0) {
    return `💵 <b>Revenue — ${esc(periodLabel(s))}</b>\n\nNo purchases in this period.`;
  }

  const commission = grossUsd * APPLE_COMMISSION;
  const net = grossUsd - commission;
  const smsUsd = (c.sms_cents ?? 0) / 100;
  const esimUsd = (c.esim_cents ?? 0) / 100;
  const devUsd = (c.dev_cents ?? 0) / 100;
  const profit = net - smsUsd - esimUsd - devUsd;
  const margin = grossUsd > 0 ? Math.round((profit / grossUsd) * 100) : 0;

  const lines: string[] = [];
  lines.push(`💵 <b>Revenue — ${esc(periodLabel(s))}</b>`);
  lines.push("");
  lines.push("<pre>");
  lines.push(row("Gross", usd(grossUsd)));
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

export function formatDigest(raw: Record<string, unknown>): string {
  const s = raw as Snapshot;
  const hours = s.window_hours ?? 6;
  const o = s.orders ?? {};
  const placed = o.placed ?? 0;

  const lines: string[] = [];
  lines.push(`📊 <b>Last ${esc(hours)}h</b>`);
  lines.push("");
  lines.push(`👤 Signups: <b>${s.signups ?? 0}</b>`);

  const buys = s.purchases ?? {};
  if ((buys.count ?? 0) > 0) {
    const usd = ((buys.credits ?? 0) * USD_PER_CREDIT).toFixed(2);
    lines.push(`💳 Purchases: <b>${buys.count}</b> · ${buys.credits} credits · ~$${esc(usd)}`);
  } else {
    lines.push(`💳 Purchases: <b>0</b>`);
  }

  lines.push("");
  if (placed > 0) {
    lines.push(`📱 Numbers: <b>${placed}</b> ordered`);
    lines.push(`   ✅ ${o.received ?? 0} delivered (${o.pct ?? 0}%)`);
    lines.push(`   ❌ ${o.failed ?? 0} failed`);

    // Only worth the extra lines when providers actually differ — during and
    // after a migration the blended rate averages a dead provider with a live
    // one and describes neither.
    const rows = (o.by_provider ?? []).filter((r) => (r.placed ?? 0) > 0);
    if (rows.length > 1) {
      for (const r of rows) {
        lines.push(`   · ${esc(r.provider ?? "?")}: ` +
                   `${r.received ?? 0}/${r.placed ?? 0} (${r.pct ?? 0}%)`);
      }
    }
  } else {
    lines.push(`📱 Numbers: none ordered`);
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

  const e = s.esims ?? {};
  lines.push(`🌍 eSIMs: <b>${e.count ?? 0}</b>${(e.count ?? 0) > 0 ? ` · ${e.credits} credits` : ""}`);

  lines.push("");
  // HeroSMS first — it serves SMS for the services carrying 99.4% of volume.
  // SMSPVA and SMSPool are gone from this block on purpose: SMSPVA no longer
  // serves anything and eSIMs are paused, so their balances were two lines of
  // noise on the one channel that has to stay readable.
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
    // Rate is over orders that actually HELD a number. Orders that died inside
    // create-order never reserved anything, so counting them would understate
    // the provider — they get their own line instead.
    const pct = numbered > 0 ? Math.round((delivered / numbered) * 100) : null;

    lines.push("");
    lines.push(`<b>${total}</b> orders · <b>${numbered}</b> got a number · ` +
               `<b>${delivered}</b> delivered${pct === null ? "" : ` (${pct}%)`}`);

    const bits: string[] = [];
    if ((s.cancelled ?? 0) > 0) bits.push(`${s.cancelled} cancelled`);
    if ((s.expired ?? 0) > 0) bits.push(`${s.expired} expired`);
    if ((s.waiting ?? 0) > 0) bits.push(`${s.waiting} still waiting`);
    if ((s.no_number ?? 0) > 0) bits.push(`${s.no_number} never got a number`);
    if (bits.length) lines.push(`<i>${esc(bits.join(" · "))}</i>`);

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
