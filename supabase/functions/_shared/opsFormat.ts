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
    by_provider?: ProviderRow[];
  };
  esims?: { count?: number; credits?: number };
  smspva_usd?: number | null;
  smspool_usd?: number | null;
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
  herosms: "SMS",
  smspva: "SMS fallback",
  smspool: "eSIM",
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

  const e = s.esims ?? {};
  lines.push(`🌍 eSIMs: <b>${e.count ?? 0}</b>${(e.count ?? 0) > 0 ? ` · ${e.credits} credits` : ""}`);

  lines.push("");
  lines.push(balanceLine("SMSPVA", s.smspva_usd));
  lines.push(balanceLine("SMSPool", s.smspool_usd));

  return lines.join("\n");
}
