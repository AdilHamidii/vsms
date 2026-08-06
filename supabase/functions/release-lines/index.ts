// Hand numbers back to Telnyx. THE OTHER HALF OF THE CANCELLATION PATH.
//
// 🔴 THIS FUNCTION DID NOT EXIST, AND ITS ABSENCE WAS A MONEY LEAK.
// `20260805170000_phone_lines.sql` names `release-lines` as the thing that
// drains `releasing` rows, and `reclaim_lapsed_lines()` was written to feed it
// — but the sweep was scheduled in no cron job and this function was never
// written. So an ordinary Apple cancellation went EXPIRED → `suspend_line_claim`
// → `suspended` → and nothing ever ran again. $1/month per cancelled
// subscriber, forever, discoverable only on the Telnyx invoice.
//
// ── Why the claim and the DELETE are separate ─────────────────────────────
// `reclaim_lapsed_lines()` is pure SQL in pg_cron so the CLAIM survives the
// edge layer being down — the same reason `run_watchdog` is pure SQL. A
// provider call cannot survive that, so it lives here and picks up whatever
// the claim left behind. A crash between them costs one more sweep, never a
// lost number.
//
// ── The orphan sweep is DRY RUN until switched on, deliberately ───────────
// Releasing a number is irreversible and the number is immediately re-sold. A
// bug in the matching logic would take live customers' numbers away, which is
// strictly worse than the leak it fixes. So it reports what it WOULD release
// and releases nothing until `app_config.line_orphan_release_enabled` is true.
// Same discipline as measuring the reservation cost rather than assuming it:
// this codebase has already spent $3.83 trusting a field that meant nothing.
//
// Cron-gated: deploy with `--no-verify-jwt`.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import {
  releaseNumber, findNumberId, deleteTelephonyCredential, listOwnedNumbers,
  faultOf,
} from "../_shared/telnyx.ts";
import { sendMessage, esc } from "../_shared/telegram.ts";

/** Bounded because the edge runtime dies at ~150s and each line is up to three
 *  provider calls. The sweep runs every 15 minutes, so a backlog drains on its
 *  own rather than needing one heroic invocation. */
const MAX_RELEASE = 25;

/** Never release more than this many orphans in one run even when enabled. An
 *  orphan sweep that suddenly wants to delete fifty numbers is a bug in the
 *  matching, not fifty orphans. */
const MAX_ORPHANS = 5;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function cronOk(req: Request): boolean {
  const secret = Deno.env.get("CRON_SECRET");
  return !!secret && req.headers.get("x-cron-secret") === secret;
}

Deno.serve(async (req) => {
  const pre = handleCors(req);
  if (pre) return pre;
  if (!cronOk(req)) return json({ error: "forbidden" }, { status: 403 });

  const sb = admin();
  const at = new Date().toISOString();

  const { data: pending, error: pendErr } = await sb
    .rpc("lines_awaiting_release", { p_limit: MAX_RELEASE });
  if (pendErr) {
    console.error(JSON.stringify({
      alert: "line_release_lookup_failed", detail: pendErr.message,
    }));
    return json({ ok: false, error: "lookup_failed" }, { status: 500 });
  }

  let released = 0, failed = 0, noNumber = 0;

  for (const line of (pending ?? []) as Array<Record<string, unknown>>) {
    const lineId = String(line.line_id);

    // Revoke the calling credential FIRST. It is what makes a release real
    // rather than a status change: a live credential would keep working
    // against a connection whose number we are about to give away.
    const credentialId = line.provider_credential_id
      ? String(line.provider_credential_id) : null;
    if (credentialId) {
      const dropped = await deleteTelephonyCredential(credentialId);
      if (faultOf(dropped)) {
        // Not fatal — releasing the number is what stops the money — but it
        // pages, because a credential outliving its number is a live token
        // pointing at someone else's future line.
        console.error(JSON.stringify({
          alert: "line_credential_delete_failed", line: lineId,
          detail: dropped.detail,
        }));
      }
    }

    // The stored id first, a lookup second. An older row may predate us
    // storing it, and failing to resolve it means paying rent forever on a
    // number nobody has.
    let numberId = line.provider_number_id ? String(line.provider_number_id) : null;
    if (!numberId && line.e164) {
      const found = await findNumberId(String(line.e164));
      if (faultOf(found)) {
        failed++;
        console.error(JSON.stringify({
          alert: "line_release_lookup_number_failed", line: lineId,
        }));
        continue;
      }
      numberId = found;
    }

    if (!numberId) {
      // Genuinely nothing to give back — a line that never got a number. Close
      // it rather than leaving it in `releasing` forever, where the watchdog
      // would page about it every six hours for the rest of time.
      const { error } = await sb.rpc("confirm_line_released", { p_line: lineId });
      if (error) {
        failed++;
        console.error(JSON.stringify({
          alert: "line_confirm_released_failed", line: lineId, detail: error.message,
        }));
      } else {
        noNumber++;
      }
      continue;
    }

    const r = await releaseNumber(numberId);
    if (faultOf(r)) {
      // Left in `releasing` deliberately: the next sweep retries it. Marking it
      // released here would hide a number we are still being billed for — the
      // exact failure this whole function exists to end.
      failed++;
      console.error(JSON.stringify({
        alert: "line_release_failed", line: lineId, detail: r.detail, type: r.type,
      }));
      continue;
    }

    const { error: confirmErr } = await sb.rpc("confirm_line_released", { p_line: lineId });
    if (confirmErr) {
      // The number IS gone at the provider. Failing to record that leaves the
      // row claiming a number that no longer exists, so it pages loudly — but
      // the money has stopped, which is the property that mattered.
      failed++;
      console.error(JSON.stringify({
        alert: "line_release_confirm_failed", line: lineId, detail: confirmErr.message,
      }));
      continue;
    }
    released++;
  }

  // ── The orphan sweep ─────────────────────────────────────────────────────
  const orphans = await findOrphans(sb);

  // Heartbeat for run_watchdog, written on EVERY run including a quiet one:
  // "nothing to release" and "this job stopped running" have to be
  // distinguishable, which is the whole reason the leak was invisible.
  await sb.from("app_config").upsert({
    key: "line_release_heartbeat",
    value: {
      at, pending: (pending ?? []).length, released, failed, no_number: noNumber,
      orphans: orphans.list.length, orphans_released: orphans.releasedCount,
      orphan_release_enabled: orphans.enabled,
      orphan_error: orphans.error,
    },
  }, { onConflict: "key" });

  if (failed > 0 || orphans.list.length > 0) {
    await alertOps(sb, at, failed, orphans);
  }

  return json({
    ok: true, pending: (pending ?? []).length, released, failed,
    no_number: noNumber, orphans: orphans.list, orphans_released: orphans.releasedCount,
    orphan_release_enabled: orphans.enabled,
  });
});

interface OrphanResult {
  list: Array<{ id: string; e164: string; reference: string | null; why: string }>;
  releasedCount: number;
  enabled: boolean;
  error: string | null;
}

/** Numbers Telnyx says we own that no live line points at.
 *
 *  `customer_reference` is set to the line id at purchase, and that single
 *  field is the only join back — the number resource carries no cost and no
 *  account metadata, so without it an orphan is invisible until the invoice.
 *
 *  ⚠️ Three guards, and every one of them is the difference between a cleanup
 *  and taking a paying customer's number away:
 *   - a number with NO reference is never touched. That covers the manually
 *     bought probe numbers and anything predating the reference convention.
 *   - a reference that is not a UUID is never touched.
 *   - only a reference matching NO row, or a row that is already
 *     released/failed, counts. A `releasing` row is handled by the loop above;
 *     an active one is a live customer.
 */
async function findOrphans(sb: ReturnType<typeof admin>): Promise<OrphanResult> {
  const empty: OrphanResult = { list: [], releasedCount: 0, enabled: false, error: null };

  const { data: flag } = await sb.from("app_config")
    .select("value").eq("key", "line_orphan_release_enabled").maybeSingle();
  const enabled = flag?.value === true;

  const owned = await listOwnedNumbers(1, 250);
  if (faultOf(owned)) {
    return { ...empty, enabled, error: `${owned.type}` };
  }

  const refs = owned
    .map((n) => n.reference)
    .filter((r): r is string => !!r && UUID_RE.test(r));

  // One query for every referenced line, rather than one per number.
  const known = new Map<string, string>();
  if (refs.length) {
    const { data: rows, error } = await sb.from("phone_lines")
      .select("id, status").in("id", refs);
    if (error) return { ...empty, enabled, error: error.message };
    for (const r of rows ?? []) known.set(String(r.id), String(r.status));
  }

  const list: OrphanResult["list"] = [];
  for (const n of owned) {
    const ref = n.reference;
    if (!ref || !UUID_RE.test(ref)) continue;   // never ours to judge
    const status = known.get(ref);
    if (status === undefined) {
      list.push({ id: n.id, e164: n.e164, reference: ref, why: "no_line_row" });
    } else if (status === "released" || status === "failed") {
      list.push({ id: n.id, e164: n.e164, reference: ref, why: `line_${status}` });
    }
  }

  if (!enabled || list.length === 0) {
    return { list, releasedCount: 0, enabled, error: null };
  }

  let releasedCount = 0;
  for (const o of list.slice(0, MAX_ORPHANS)) {
    const r = await releaseNumber(o.id);
    if (faultOf(r)) {
      console.error(JSON.stringify({
        alert: "line_orphan_release_failed", number: o.e164, detail: r.detail,
      }));
      continue;
    }
    releasedCount++;
    console.log(JSON.stringify({ line_orphan_released: o.e164, why: o.why }));
  }
  return { list, releasedCount, enabled, error: null };
}

/** Ops ping. NOT the exactly-once `telegram_events` claim shape used for
 *  business events: this is an operational condition that can persist across
 *  runs, and a claim row keyed on it would announce it once and then go silent
 *  while the money kept leaking. Rate-limited by hand instead. */
async function alertOps(
  sb: ReturnType<typeof admin>, at: string, failed: number, orphans: OrphanResult,
) {
  try {
    const { data } = await sb.from("app_config")
      .select("value").eq("key", "line_release_alert").maybeSingle();
    const last = (data?.value as { at?: string } | null)?.at;
    if (last && Date.now() - new Date(last).getTime() < 6 * 3_600_000) return;

    const lines: string[] = ["⚠️ <b>Line release</b>"];
    if (failed > 0) {
      lines.push(`${failed} number(s) failed to release — still billing.`);
    }
    if (orphans.list.length > 0) {
      lines.push(
        `${orphans.list.length} orphan number(s) at Telnyx with no live line` +
        (orphans.enabled
          ? `, ${orphans.releasedCount} released.`
          : `. Release is OFF — set app_config.line_orphan_release_enabled to true after checking:\n` +
            orphans.list.slice(0, 5).map((o) => esc(`${o.e164} (${o.why})`)).join("\n")),
      );
    }
    const r = await sendMessage(lines.join("\n"));
    if (r.ok) {
      await sb.from("app_config").upsert(
        { key: "line_release_alert", value: { at } }, { onConflict: "key" });
    }
  } catch (e) {
    console.error("release-lines alert failed (ignored):", e);
  }
}
