// Mirror Apple purchases into RevenueCat so the owner can read the business
// from RevenueCat's phone app instead of opening Telegram.
//
// ── What this is NOT ──────────────────────────────────────────────────────
// 🔴 RevenueCat is a READ surface and nothing more. It grants no entitlement,
// gates no product and settles no money. `has_email_subscription`,
// `reclaim_lapsed_lines`, `credit_iap_purchase` and both subscription stores
// are untouched. A RevenueCat outage must cost exactly one thing: a stale
// chart. Never make a product decision depend on a row here.
//
// ── Why a SWEEP and not a forward from the money paths ────────────────────
// RevenueCat is explicit that the receipts call has to land: "if you don't
// have this endpoint hit for that user, that subscription will most likely not
// be tracked." An inline POST in `iap-verify` / `apple-notifications` would
// therefore need its own retry, inside the two functions this repo most needs
// to keep boring — and a discarded error there is precisely the shape of the
// four silent `wallet_credit` money bugs already fixed. A sweep cannot lose a
// row: an unsynced row simply stays unsynced and is picked up next run. The
// cost is latency (one cron interval), which for a dashboard is nothing.
//
// ── Sandbox is excluded on purpose ────────────────────────────────────────
// Sandbox receipts are genuinely Apple-signed and cost $0. Mirroring them
// would invent revenue on the one surface built to be trusted at a glance.
//
// ── Renewals ──────────────────────────────────────────────────────────────
// A renewal REWRITES `latest_signed_transaction` on the subscription row, so a
// boolean "synced" flag would mirror month one and then go silent forever.
// `rc_synced_txn` records WHICH transaction was mirrored and the sweep re-sends
// whenever it moves.
//
// Cron-gated: deploy with `--no-verify-jwt`.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";

const RC_RECEIPTS = "https://api.revenuecat.com/v1/receipts";

/** Rows considered per family per run. The steady state is ~2 purchases a day;
 *  this only matters for the initial backfill, which drains over a few runs. */
const BATCH = 40;

/** Stop well before the ~150s edge kill. A run that dies mid-loop is not a
 *  correctness problem here (unsynced stays unsynced) but it burns a cron slot
 *  and logs nothing useful, so leave real headroom. */
const DEADLINE_MS = 100_000;

/** A row that has failed this many times is left alone. Something is wrong with
 *  that specific receipt and retrying it forever would crowd out live rows on
 *  every run — the backlog would silently stop draining. Surfaced by
 *  `rc_sync_error` rather than retried into the ground. */
const MAX_ATTEMPTS = 10;

function cronOk(req: Request): boolean {
  const secret = Deno.env.get("CRON_SECRET");
  return !!secret && req.headers.get("x-cron-secret") === secret;
}

type PostResult = { ok: boolean; status: number; detail: string };

/** One receipt to RevenueCat. `fetch_token` takes a StoreKit 2 signed
 *  transaction JWS directly, which is what both `iap_receipts.raw_jws` and
 *  `*_subscriptions.latest_signed_transaction` already hold — there is no
 *  legacy base64 receipt anywhere in this product to fall back on.
 *
 *  Price and currency are deliberately NOT sent: RevenueCat derives them from
 *  the JWS using the In-App Purchase key, which is more accurate per-storefront
 *  than anything we could restate, and restating a price we own is the mistake
 *  this repo has made in three other places. */
async function postReceipt(
  key: string,
  appUserId: string,
  fetchToken: string,
  productId: string | null,
): Promise<PostResult> {
  try {
    const res = await fetch(RC_RECEIPTS, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${key}`,
        "Content-Type": "application/json",
        "X-Platform": "ios",
      },
      body: JSON.stringify({
        app_user_id: appUserId,
        fetch_token: fetchToken,
        ...(productId ? { product_id: productId } : {}),
      }),
    });
    const text = await res.text();
    return {
      ok: res.ok,
      status: res.status,
      // Keep the stored error short: this column is read in an ops message, and
      // RevenueCat echoes the whole subscriber object on success.
      detail: res.ok ? "" : text.slice(0, 300),
    };
  } catch (e) {
    // A network fault is not a bad receipt. It must leave the row retryable.
    return { ok: false, status: 0, detail: `fetch failed: ${String(e).slice(0, 200)}` };
  }
}

Deno.serve(async (req) => {
  const pre = handleCors(req);
  if (pre) return pre;
  if (!cronOk(req)) return json({ error: "forbidden" }, { status: 403 });

  const key = Deno.env.get("REVENUECAT_API_KEY");
  if (!key) return json({ error: "revenuecat_key_missing" }, { status: 500 });

  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* empty body is a normal cron call */ }
  const dryRun = body.dry_run === true;
  const limit = Math.min(Number(body.limit) || BATCH, BATCH);

  const sb = admin();
  const started = Date.now();
  const out = {
    dry_run: dryRun,
    packs: { seen: 0, synced: 0, failed: 0 },
    line: { seen: 0, synced: 0, failed: 0 },
    mail: { seen: 0, synced: 0, failed: 0 },
    errors: [] as string[],
    deadline_hit: false,
  };

  const outOfTime = () => Date.now() - started > DEADLINE_MS;

  // ── 1. Credit packs (consumables) ───────────────────────────────────────
  // Immutable once written, so `rc_synced_at is null` is the whole predicate.
  {
    const { data, error } = await sb
      .from("iap_receipts")
      .select("id,user_id,product_id,raw_jws,rc_sync_attempts")
      .is("rc_synced_at", null)
      .eq("environment", "Production")
      .not("raw_jws", "is", null)
      .lt("rc_sync_attempts", MAX_ATTEMPTS)
      .order("created_at", { ascending: true })
      .limit(limit);
    if (error) return json({ error: "pack_read_failed", detail: error.message }, { status: 500 });

    for (const row of data ?? []) {
      if (outOfTime()) { out.deadline_hit = true; break; }
      out.packs.seen++;
      if (dryRun) continue;
      const r = await postReceipt(key, row.user_id, row.raw_jws, row.product_id);
      if (r.ok) {
        const { error: uerr } = await sb.from("iap_receipts")
          .update({ rc_synced_at: new Date().toISOString(), rc_sync_error: null })
          .eq("id", row.id);
        if (uerr) out.errors.push(`pack ${row.id} stamp: ${uerr.message}`);
        else out.packs.synced++;
      } else {
        out.packs.failed++;
        if (out.errors.length < 5) out.errors.push(`pack ${row.id}: ${r.status} ${r.detail}`);
        const { error: uerr } = await sb.from("iap_receipts")
          .update({
            rc_sync_attempts: (row.rc_sync_attempts ?? 0) + 1,
            rc_sync_error: `${r.status} ${r.detail}`,
          })
          .eq("id", row.id);
        if (uerr) out.errors.push(`pack ${row.id} stamp: ${uerr.message}`);
      }
    }
  }

  // ── 2 & 3. The two subscription families ────────────────────────────────
  // 🔴 They are separate Apple subscription GROUPS and separate tables, and
  // they must stay separately counted here too: `line_notifications` is a
  // misnomer that carries every product, and conflating the two is exactly how
  // mail money spent weeks being rendered as line money in `/revenue`.
  for (const fam of ["line", "mail"] as const) {
    const table = fam === "line" ? "line_subscriptions" : "email_subscriptions";
    const bucket = out[fam];

    const { data, error } = await sb
      .from(table)
      .select(
        "original_transaction_id,user_id,product_id,latest_signed_transaction," +
        "last_transaction_id,rc_synced_txn,rc_sync_attempts",
      )
      .eq("environment", "Production")
      .not("latest_signed_transaction", "is", null)
      .lt("rc_sync_attempts", MAX_ATTEMPTS)
      .order("updated_at", { ascending: true })
      .limit(limit);
    if (error) return json({ error: `${fam}_read_failed`, detail: error.message }, { status: 500 });

    for (const row of data ?? []) {
      // Already mirrored at this exact transaction — a renewal moves
      // `last_transaction_id` and brings the row back here on its own.
      if (row.rc_synced_txn && row.rc_synced_txn === row.last_transaction_id) continue;
      if (outOfTime()) { out.deadline_hit = true; break; }
      bucket.seen++;
      if (dryRun) continue;

      const r = await postReceipt(key, row.user_id, row.latest_signed_transaction, row.product_id);
      const id = row.original_transaction_id;
      if (r.ok) {
        const { error: uerr } = await sb.from(table)
          .update({
            rc_synced_txn: row.last_transaction_id,
            rc_synced_at: new Date().toISOString(),
            rc_sync_error: null,
          })
          .eq("original_transaction_id", id);
        if (uerr) out.errors.push(`${fam} ${id} stamp: ${uerr.message}`);
        else bucket.synced++;
      } else {
        bucket.failed++;
        if (out.errors.length < 5) out.errors.push(`${fam} ${id}: ${r.status} ${r.detail}`);
        const { error: uerr } = await sb.from(table)
          .update({
            rc_sync_attempts: (row.rc_sync_attempts ?? 0) + 1,
            rc_sync_error: `${r.status} ${r.detail}`,
          })
          .eq("original_transaction_id", id);
        if (uerr) out.errors.push(`${fam} ${id} stamp: ${uerr.message}`);
      }
    }
  }

  return json({ ok: true, elapsed_ms: Date.now() - started, ...out });
});
