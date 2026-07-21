// Rendering for the ops snapshot, shared by the 6-hourly digest
// (telegram-notify) and the on-demand /stats command (telegram-webhook) so the
// two can never disagree about what a number means.

import { esc } from "./telegram.ts";

interface Snapshot {
  window_hours?: number;
  signups?: number;
  purchases?: { count?: number; credits?: number };
  orders?: { placed?: number; received?: number; failed?: number; pct?: number | null };
  esims?: { count?: number; credits?: number };
  smspool_usd?: number | null;
}

/** Roughly what a credit is worth in gross revenue, for a readable estimate
 *  only. The packs run $0.598/cr (5-pack) down to $0.333/cr (150-pack); this
 *  is deliberately the middle of that range and is never presented as exact. */
const USD_PER_CREDIT = 0.45;

/** Warn below ~5x the wholesale ceiling of a single order, matching the
 *  low-balance threshold poll-active-orders alerts on. */
const LOW_BALANCE_USD = 20;

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
  } else {
    lines.push(`📱 Numbers: none ordered`);
  }

  const e = s.esims ?? {};
  lines.push(`🌍 eSIMs: <b>${e.count ?? 0}</b>${(e.count ?? 0) > 0 ? ` · ${e.credits} credits` : ""}`);

  if (typeof s.smspool_usd === "number") {
    const low = s.smspool_usd < LOW_BALANCE_USD;
    lines.push("");
    lines.push(`${low ? "⚠️" : "💰"} SMSPool balance: <b>$${esc(s.smspool_usd.toFixed(2))}</b>` +
               (low ? " — <b>top up</b>" : ""));
  }

  return lines.join("\n");
}
