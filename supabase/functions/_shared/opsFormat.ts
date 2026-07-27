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
const ROLE: Record<string, string> = { smspva: "SMS", smspool: "eSIM" };

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
