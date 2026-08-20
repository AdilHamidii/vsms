// Called by pg_cron every minute. Auto-expires overdue orders (refund + notify),
// then polls the provider for incoming SMS on the rest, persisting OTPs and
// dispatching push notifications.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import { markDead, markSuccess, poll, type OrderProvider } from "../_shared/providers.ts";
import { getBalanceUsd as getEsimaccessBalanceUsd } from "../_shared/esimaccess.ts";
import { getBalanceUsd as getHeroBalanceUsd } from "../_shared/herosms.ts";
import { getProfile as getFivesimProfile, type FiveProfile } from "../_shared/fivesim.ts";
import { getBalance as getSmspvaBalance, isOk } from "../_shared/smspva.ts";
import { getBalance as getTelnyxBalance, faultOf as telnyxFaultOf } from "../_shared/telnyx.ts";
import { sendPush } from "../_shared/apns.ts";
import { notifySafe, esc } from "../_shared/telegram.ts";

// The most a single order can cost us, in dollars — MUST track
// MAX_WHOLESALE_CENTS in sync-prices (750 as of 2026-07-27).
//
// This ladder used to be a hard-coded [20, 10, 5, 1] justified as "5x the
// wholesale ceiling for a single order ($4)". When the ceiling moved to $7.50
// the ladder did not, so at the live SMSPVA balance of $3.55 the monitor read
// tier 3 ("low") while ~1,500 routes — every WhatsApp route among them — could
// not be funded AT ALL. A user ordering one was guaranteed a BALANCE_ERROR,
// charged and refunded. Deriving the tiers keeps that honest through the next
// ceiling change.
const MAX_ORDER_COST_USD = 7.5;

// 5x the priciest single order, so the first page still leaves room to act.
const LOW_BALANCE_USD = MAX_ORDER_COST_USD * 5;

// Escalation ladder. The original single edge-trigger fired once at $20 and
// then NEVER AGAIN — both providers sat "low" for days while sliding toward
// $0 (= 100% order failure) with no further page. Each threshold crossing now
// pages once; recovery above a tier re-arms it automatically.
//
// The last rung is the ceiling itself: below it we cannot fill the most
// expensive route in the catalog, which is a real outage for that inventory
// even though the balance is not zero.
const BALANCE_TIERS = [
  LOW_BALANCE_USD,               // 37.50
  MAX_ORDER_COST_USD * 3,        // 22.50
  MAX_ORDER_COST_USD * 1.5,      // 11.25
  MAX_ORDER_COST_USD,            //  7.50
];

// ── HeroSMS fail-fast ───────────────────────────────────────────────────────
//
// How long a HeroSMS order may sit with a number and no code before we refund
// it and let the user move on. PER PROVIDER on purpose, and the asymmetry is
// measured, not assumed (2026-08-03, every order since the 07-30 cutover):
//
//   of orders still ALIVE at 90s, how many EVER delivered
//     HeroSMS   0 of 22   (0%)      every code it has ever sent: 19s-86s
//     SMSPVA   11 of 49  (22%)      codes as late as 337s
//   Fisher exact p = 0.014
//
// Seven HeroSMS orders ran the full 8-minute window for nothing — 59.5 minutes
// of users watching a screen whose outcome was already fixed, while the credits
// they could have retried with sat locked in a dead order.
//
// 150s is ~1.7x the slowest code HeroSMS has ever sent. The threshold is
// deliberately not agonised over, because being wrong about it costs nothing:
// `expire_order_early_claim` keeps `late_watch_until`, so the number stays
// reserved and polled until its ORIGINAL deadline and any late code is still
// handed over free (the same rescue path a user cancel uses). The only thing
// that moves earlier is the refund. 0 of 22 is a small sample — the rule of
// three puts the upper bound on late HeroSMS delivery at 13.6% — and the
// rescue is exactly what makes that uncertainty affordable.
//
// SMSPVA is deliberately excluded. Applying this to a provider that delivers
// 22% of its remaining orders after 90s would destroy real codes.
const FAIL_FAST_SECONDS_BY_PROVIDER: Record<string, number> = { herosms: 150 };
// Small on purpose: each one is an RPC plus an APNs fan-out, and it must never
// crowd out the polling loop below, which is what delivers codes.
const FAIL_FAST_LIMIT = 25;

// How many times the late-watch sweep may attempt markDead() on one order
// before giving up on it for good. See the block at the release site below —
// the count exists because `late_watch_until` alone cannot express "retry, but
// not forever", and both orderings of (clear the flag, release the number) that
// rely on it alone are wrong in one direction or the other.
const MAX_LATE_RELEASE_ATTEMPTS = 5;

function validateCronSecret(req: Request): boolean {
  const header = req.headers.get("x-cron-secret");
  const expected = Deno.env.get("CRON_SECRET");
  if (!header || !expected) return false;
  return header === expected;
}

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;

  if (!validateCronSecret(req)) {
    return json({ error: "unauthorized" }, { status: 401 });
  }

  const sb = admin();

  // Best-effort push fan-out to all of a user's devices. Never throws.
  async function notify(
    userId: string,
    title: string,
    body: string,
    data: Record<string, unknown>,
  ): Promise<number> {
    const { data: devices } = await sb
      .from("push_devices")
      .select("token, environment, bundle_id")
      .eq("user_id", userId);
    let sent = 0, hardFail = 0;
    for (const d of devices ?? []) {
      try {
        const r = await sendPush(
          d.token,
          { alertTitle: title, alertBody: body, customData: data },
          d.environment as "sandbox" | "production",
        );
        if (r.ok) sent++;
        else {
          // A dead token is NOT an APNs fault — only count transport/auth
          // failures toward push_health, or pruning normal churn would look
          // like an outage.
          const deadToken = r.status === 410 || (r.body ?? "").includes("BadDeviceToken");
          if (!deadToken) hardFail++;
          console.error("APNs status", r.status, r.body);
          // 410 Unregistered / 400 BadDeviceToken = the token is permanently
          // dead (app deleted, token rotated). Prune it: dead tokens never
          // heal, they only slow every future fan-out and — via winback's
          // mark-on-success rule — permanently clog its candidate window.
          if (r.status === 410 || (r.body ?? "").includes("BadDeviceToken")) {
            await sb.from("push_devices").delete().eq("token", d.token);
          }
        }
      } catch (e) {
        hardFail++;
        console.error("APNs send failed:", e);
      }
    }

    // APNs health. Nothing anywhere counted push failures, so an expired .p8 or
    // a drifted topic would kill EVERY push in the product — "your code
    // arrived" included — while this function kept returning 200 {pushSent: 0}.
    // run_watchdog pages at 10 consecutive failures; any success resets it.
    if (sent > 0 || hardFail > 0) {
      try {
        const { data: ph } = await sb
          .from("app_config").select("value").eq("key", "push_health").maybeSingle();
        const prevFails = Number((ph?.value as { consecutive_failures?: number } | null)
          ?.consecutive_failures ?? 0);
        await sb.from("app_config").upsert({
          key: "push_health",
          value: {
            consecutive_failures: sent > 0 ? 0 : prevFails + hardFail,
            last_success_at: sent > 0
              ? new Date().toISOString()
              : (ph?.value as { last_success_at?: string } | null)?.last_success_at ?? null,
            checked_at: new Date().toISOString(),
          },
        }, { onConflict: "key" });
      } catch (e) {
        console.error("push_health update failed (ignored):", e);
      }
    }
    return sent;
  }

  let expired = 0, polled = 0, arrived = 0, pushSent = 0;

  /** Record one provider's balance. Each call is independently guarded so an
   *  outage at one provider can never suppress the other's reading — which is
   *  precisely how SMSPVA would stay invisible on the day it matters.
   *  Alerts once per BALANCE_TIERS threshold crossing (worsening only);
   *  climbing back above a tier re-arms it. The 6-hourly digest carries the
   *  standing status; this is the instant page. */
  async function recordBalance(
    key: string, label: string, read: () => Promise<number | null>,
    /** Extra fields merged into the stored blob, read AFTER `read()` so a
     *  provider can hand back more than a balance without a second call. */
    readExtra?: () => Promise<Record<string, unknown> | null>,
    /** Write the reading but skip the tier pages. Used for eSIM Access while
     *  the eSIM line is PAUSED: "balance EMPTY — orders failing NOW" is false
     *  when nothing can order, and a false page on the one channel that must
     *  stay readable is how a real one gets missed. The tier is still stamped
     *  so unpausing does not replay old crossings. */
    muteAlerts = false,
  ) {
    try {
      const bal = await read();
      if (bal == null || !Number.isFinite(bal)) return;
      const low = bal < LOW_BALANCE_USD;
      // 0 = healthy, 1 = below $20 … 4 = below $1 (effectively empty).
      const tier = BALANCE_TIERS.filter((t) => bal < t).length;

      const { data: prev } = await sb
        .from("app_config").select("value").eq("key", key).maybeSingle();
      const prevVal = prev?.value as { low?: boolean; alert_tier?: number } | null;
      // Older readings predate alert_tier; treat a legacy low=true as tier 1
      // so redeploying doesn't re-page for the crossing that already paged.
      const prevTier = prevVal?.alert_tier ?? (prevVal?.low ? 1 : 0);

      // Send FIRST, then stamp the tier — and only stamp the escalation if the
      // send actually landed.
      //
      // This used to upsert `alert_tier` before calling notifySafe, which
      // swallows failures. One timed-out Telegram send therefore recorded the
      // crossing as already-alerted: the next run saw tier == prevTier and
      // stayed silent. On the bottom rung that is permanent, because there is
      // no lower tier left to cross — the "balance EMPTY" page would never fire
      // again. telegram-notify's claimAndSend already gets this right; these
      // three sites did not.
      let alerted = true;
      if (tier > prevTier && !muteAlerts) {
        console.error(`${key} balance $${bal} crossed below $${BALANCE_TIERS[tier - 1]}`);
        alerted = await notifySafe(
          tier >= BALANCE_TIERS.length
            ? `🚨 <b>${label} balance EMPTY: $${bal.toFixed(2)}</b>\n` +
              `Orders on this provider are failing NOW — top up immediately.`
            : `⚠️ <b>${label} balance low: $${bal.toFixed(2)}</b>\n` +
              `Crossed below $${BALANCE_TIERS[tier - 1]} — top up before orders start failing.`,
        );
        if (!alerted) {
          console.error(`${key} balance page FAILED to send — not recording tier ${tier}, will retry next run`);
        }
      }

      // Never let an optional extra reader break the balance write — the
      // balance is what create-order's pre-charge guard and the pager read.
      let extra: Record<string, unknown> | null = null;
      if (readExtra) {
        try { extra = await readExtra(); }
        catch (e) { console.error(`${key} extra read failed:`, e); }
      }

      await sb.from("app_config").upsert({
        key,
        value: {
          balance_usd: bal,
          low,
          // Hold the previous tier when the page didn't get out, so the
          // crossing is re-attempted rather than silently consumed.
          alert_tier: alerted ? tier : prevTier,
          checked_at: new Date().toISOString(),
          ...(extra ?? {}),
        },
        updated_at: new Date().toISOString(),
      }, { onConflict: "key" });
    } catch (e) {
      console.error(`${key} balance check failed:`, e);
    }
  }

  // ── Balance monitoring runs FIRST, before any order loop. It doubles as the
  //    watchdog's minutely heartbeat (run_watchdog checks smspva_health
  //    freshness), so it must not sit behind work whose duration scales with
  //    order volume — at the 150s worker kill it would silently stop, and a
  //    frozen reading is indistinguishable from a healthy provider.
  // One `user/profile` read serves both the balance and the rating: recordBalance
  // calls `read` and then `readExtra`, so the cached profile is populated by the
  // time the second runs. Never reorder those two calls.
  let fiveProfile: FiveProfile | null = null;
  const readFivesimBalance = async () => {
    fiveProfile = await getFivesimProfile();
    return fiveProfile?.balanceUsd ?? null;
  };
  const readFivesimExtra = async () =>
    fiveProfile?.rating != null ? { rating: fiveProfile.rating } : null;

  // ⚠️ EVERY provider that owns active routes needs a reading here, not just
  // the primary. create-order's pre-charge guard reads
  // `app_config.${route.provider}_health` and requires it to be under 5 minutes
  // old before it will refuse an order — so a provider with no writer here has
  // a guard that is not merely stale but PERMANENTLY DISARMED, failing open on
  // every order forever. SMSPVA was in exactly that state from the 2026-08-03
  // cutover until 08-06: its key sat frozen at $5.26 for three days, below the
  // single-order ceiling, while it still owned 1,035 active routes. The comment
  // that used to sit here said "5sim serves ALL SMS", which was the false
  // premise the omission rested on.
  const readTelnyxBalance = async () => {
    // telnyx.ts returns a fault OBJECT rather than throwing, so the fault check
    // is what stands between a provider outage and a null reading being read as
    // a healthy zero. `.catch` covers transport on top of that.
    const b = await getTelnyxBalance().catch(() => null);
    return b && !telnyxFaultOf(b) ? b.usd : null;
  };

  const readSmspvaBalance = async () => {
    // `.catch(() => null)` then `r && isOk(r)`: isOk dereferences `r.statusCode`,
    // so handing it the null from a thrown call is a TypeError, not a false.
    const r = await getSmspvaBalance().catch(() => null);
    return r && isOk(r) ? Number(r.data.balance) : null;
  };

  // eSIM Access's page mute is gated on the eSIM pause — see recordBalance's
  // muteAlerts note. Read once per run; a failed read unmutes (fail loud).
  let esimPaused = false;
  try {
    const { data: ep } = await sb
      .from("app_config").select("value").eq("key", "esim_paused").maybeSingle();
    esimPaused = ep?.value === true;
  } catch { /* unmuted is the safe default */ }

  await Promise.all([
    // 5sim is the PRIMARY SMS provider. This key is also what create-order's
    // pre-charge balance guard reads (`${providers[0]}_health`) — without it
    // that guard fails OPEN, so a dry balance charges the user and refunds
    // instead of refusing. It was missing from the cutover.
    //
    // `rating` rides along because it is a SECOND way to lose the ability to
    // buy that the balance cannot show: 0 means no purchases at all, and our
    // cancel-and-ban pattern only ever drives it down between top-ups.
    recordBalance("5sim_health", "5sim (SMS)", readFivesimBalance, readFivesimExtra),
    // HeroSMS is NOT retired: it serves the temp-EMAIL line on the same
    // account and balance, so this reading still matters.
    recordBalance("herosms_health", "HeroSMS (SMS + e-mail)", getHeroBalanceUsd),
    // SMSPVA is NOT retired either — it is the documented rollback target and
    // still owns over a thousand active routes. Without this, both its
    // pre-charge guard and `alertLowBalanceBlock` (which only ever fires from
    // inside that guard) are dead code.
    recordBalance("smspva_health", "SMSPVA (SMS)", readSmspvaBalance),
    // 🔴 TELNYX WAS NOT MONITORED AT ALL — there was no `telnyx_health` key in
    // `app_config`, for the one provider that bills us MONTHLY and RECURRING.
    // Every other provider gets a minutely reading and a low-balance page;
    // this one was discovered empty the only way left, by a user hitting
    // `reserve-line-number`'s float guard and seeing "We can't set up new
    // numbers right now". The guard did its job — nobody was charged — but the
    // owner learned about it from a screenshot instead of a page.
    //
    // The shared tier ladder is tuned for SMS float and is aggressive here by
    // comparison, which is the right direction: a line costs $1 up front and
    // $1/month FOREVER, so running dry does not merely block a sale, it means
    // an existing subscriber's number cannot be renewed.
    recordBalance("telnyx_health", "Telnyx (rented lines)", readTelnyxBalance),
    // eSIM Access funds the eSIM line (provider since 2026-08-10). This key is
    // ALSO what create-esim-order's pre-charge guard reads — without a writer
    // here that guard is permanently disarmed, the exact SMSPVA failure above.
    // With no ESIMACCESS_ACCESS_CODE set the reader returns null and nothing
    // is written — /balance renders "no reading", never a healthy zero.
    recordBalance(
      "esimaccess_health", "eSIM Access (eSIM)", getEsimaccessBalanceUsd,
      undefined, esimPaused,
    ),
  ]);

  // ── Auto-expire overdue orders. Each expiry is an atomic claim (flip
  //    waiting -> expired only if still waiting) so two overlapping cron runs
  //    can't both refund/notify the same order — the loser matches 0 rows and
  //    skips. Refund + "no code" push happen only for the winner. Per-order
  //    try/catch keeps one bad row from aborting the batch.
  const { data: expiredCandidates, error: expCandErr } = await sb
    .from("orders")
    .select("id, user_id, cost_credits, provider, smspva_id, service:service_id ( name )")
    .eq("status", "waiting")
    .lt("expires_at", new Date().toISOString())
    .order("expires_at", { ascending: true })
    .limit(50);    // cap the per-run batch; the minutely cadence drains any backlog.
                   // 50, not 200: each expiry is an RPC + up to two sequential
                   // provider calls (markDead, 10s timeout each) + APNs, so a
                   // mass-expiry minute at 200 could eat the whole 120s relay
                   // budget before the POLLING loop below ever ran — starving
                   // exactly the orders whose codes were about to arrive. At 50
                   // a backlog drains in a few minutes while every run still
                   // reaches the poll and rescue phases.
  // If this select fails, zero orders expire and zero refunds are issued — and
  // the run still returns 200 {expired: 0}, which is indistinguishable from a
  // quiet minute. Surface it.
  if (expCandErr) {
    console.error("poll: expiry candidate select FAILED — no orders will be expired this run", expCandErr);
  }

  for (const row of expiredCandidates ?? []) {
    try {
      // Claim the row terminal AND refund it in ONE transaction.
      //
      // These used to be two separate round-trips, and this function really
      // does get killed between them: the relay caps it (120s now, 30s until
      // 20260731140000) while the limits above are sized for the ~150s edge
      // budget. A kill in that window left the order `expired` with the charge
      // never refunded — and terminal rows are never revisited, so nothing
      // would ever retry it. A TypeScript-level rollback cannot cover that,
      // because the process is gone.
      //
      // Inside expire_order_claim a failed wallet_credit RAISES, which aborts
      // the status flip too, so the row returns to `waiting` and the next sweep
      // tries again. false = another run claimed it, or it already closed.
      const { data: didExpire, error: expErr } = await sb
        .rpc("expire_order_claim", { p_order: row.id });
      if (expErr) {
        // Nothing committed — the whole transaction rolled back.
        console.error(`poll: EXPIRE FAILED order=${row.id} user=${row.user_id} ` +
                      `credits=${row.cost_credits}: ${expErr.message}`);
        // A refund that keeps failing retries every minute in silence, so page
        // instead of letting it loop unseen.
        try {
          EdgeRuntime.waitUntil(notifySafe(
            `🚨 <b>Expiry refund failed</b>\n` +
            `order ${esc(row.id)} · user ${esc(row.user_id)} · ${row.cost_credits} credits\n` +
            `${esc(expErr.message)}\n` +
            `<i>Rolled back to waiting; the next sweep retries.</i>`,
          ));
        } catch { /* alerting must never mask the sweep */ }
        continue;   // no count, and above all no "you were refunded" push
      }
      if (!didExpire) continue;
      expired++;

      // Ban + close at the provider. Before this, an expired order was never
      // told to SMSPVA at all: their side kept the request id live for ~10
      // minutes and re-issued the same dead number to the next order (their
      // docs explicitly say to ban when no SMS arrived). Best-effort — the
      // refund above already happened and must never depend on this.
      if (row.smspva_id) {
        await markDead((row.provider ?? "smspva") as OrderProvider, row.smspva_id);
      }

      const svc = row.service as { name: string } | null;
      pushSent += await notify(
        row.user_id,
        "No code arrived",
        `Your ${svc?.name ?? "verification"} number expired — ${row.cost_credits} credits refunded.`,
        // orderId matters: "No code arrived" is the most-delivered push in
        // the product, and without a reference the tap landed on Home —
        // bypassing RecoveryScreen, the refund receipt and the steer.
        { event: "expired", orderId: row.id },
      );
    } catch (e) {
      console.error("expire failed for order", row.id, e);
    }
  }

  // ── Fail-fast: refund a HeroSMS order once it is past the point where a code
  //    has ever arrived, WITHOUT giving up the number. See
  //    FAIL_FAST_SECONDS_BY_PROVIDER for the measurement.
  //
  //    Runs after the natural-expiry sweep and before the rescue below, so an
  //    order closed here is already eligible for rescue in the SAME run.
  //
  //    `expires_at > now` is what keeps the two sweeps disjoint: anything past
  //    its real deadline belongs to the sweep above, which markDead()s the
  //    number to reclaim the wholesale. Here we must NOT release it.
  let failedFast = 0;
  const ffProviders = Object.keys(FAIL_FAST_SECONDS_BY_PROVIDER);
  const ffMinSeconds = Math.min(...Object.values(FAIL_FAST_SECONDS_BY_PROVIDER));
  const { data: ffCandidates, error: ffErr } = await sb
    .from("orders")
    .select("id, user_id, cost_credits, provider, created_at, service:service_id ( name )")
    .eq("status", "waiting")
    .in("provider", ffProviders)
    .not("smspva_number", "is", null)
    .lt("created_at", new Date(Date.now() - ffMinSeconds * 1000).toISOString())
    .gt("expires_at", new Date().toISOString())
    .order("created_at", { ascending: true })
    .limit(FAIL_FAST_LIMIT);
  // Same reasoning as the expiry select: a failed read returns 200 {fail_fast:0},
  // which is indistinguishable from a quiet minute. Surface it.
  if (ffErr) {
    console.error("poll: fail-fast candidate select FAILED — no orders closed early this run", ffErr);
  }

  for (const row of ffCandidates ?? []) {
    try {
      // The select uses the SHORTEST threshold across providers so one query
      // serves them all; re-check this row's own provider before acting.
      const limitS = FAIL_FAST_SECONDS_BY_PROVIDER[row.provider ?? ""];
      if (limitS == null) continue;
      const heldS = (Date.now() - new Date(row.created_at as string).getTime()) / 1000;
      if (heldS < limitS) continue;

      // Refund + close + stamp late_watch_until in ONE transaction. A failed
      // wallet_credit RAISES inside the function and rolls the status flip back
      // to 'waiting', so the order is retried next minute rather than sitting
      // terminal and unrefundable. false = someone else already claimed it —
      // most likely the code landed, which is precisely the race we must lose
      // quietly.
      const { data: closed, error: ffRpcErr } = await sb
        .rpc("expire_order_early_claim", { p_order: row.id });
      if (ffRpcErr) {
        console.error(`poll: FAIL-FAST REFUND FAILED order=${row.id} user=${row.user_id} ` +
                      `credits=${row.cost_credits}: ${ffRpcErr.message}`);
        continue;   // no count, and above all no "you were refunded" push
      }
      if (!closed) continue;
      failedFast++;

      const svc = row.service as { name: string } | null;
      // Same title as the natural expiry: to the user these are the same event
      // ("no code came, you have your credits back"), and inventing a second
      // vocabulary for it would only raise the question of what the difference
      // is. The number is still being watched, so a late code arrives as its
      // own push — deliberately not promised here, because it usually does not
      // happen and a promise we keep 0% of the time is worse than silence.
      pushSent += await notify(
        row.user_id,
        "No code arrived",
        `Your ${svc?.name ?? "verification"} number didn't get a code — ${row.cost_credits} credits refunded. You can try again now.`,
        { event: "expired", orderId: row.id },
      );
    } catch (e) {
      console.error("fail-fast failed for order", row.id, e);
    }
  }

  // NOTE ON ORDERING: this runs BEFORE the main polling loop, not after.
  //
  // It was last, behind up to 200 expiry claims and 50 sequential provider
  // polls inside a ~150s worker budget — so it was the first thing dropped
  // under load, which is exactly when held numbers cost the most. Since
  // cancel-order stopped releasing synchronously, this sweep is the ONLY thing
  // that ever hands back a cancelled number; if it doesn't run, the number is
  // never released and late_watch_until stays set. Cheap anyway: it touches at
  // most 50 rows and usually zero.
  // ── Late-code rescue.
  //
  // Cancels land at a median of 57s; codes arrive at a median of 58s, 45% of
  // them after 60s. cancel-order no longer releases the number — it stamps
  // late_watch_until — so a code that shows up after the user gave up is still
  // ours to hand over. The refund already stands and the status stays
  // 'canceled': we give the code away. Owner decision 2026-07-27.
  //
  // The push carries NO orderId on purpose. Shipped PushManager routes on
  // orderId, and deep-linking into a canceled order would land the user on the
  // recovery/refund screen instead of their code. Without it the tap just opens
  // the app, and the code is in the notification body where they can read it.
  let rescued = 0, lateReleased = 0;
  const nowIso = new Date().toISOString();
  const { data: lateWatch, error: lateErr } = await sb
    .from("orders")
    .select("id, user_id, cost_credits, provider, smspva_id, late_watch_until, late_release_attempts, service:service_id ( name )")
    .not("late_watch_until", "is", null)
    .is("otp", null)
    // 'expired' as well as 'canceled' since the fail-fast sweep above: it
    // closes a dead HeroSMS order as 'expired' and KEEPS the number, so
    // filtering on 'canceled' alone would have made this sweep skip exactly
    // those rows — no rescue, and nothing to ever release the number, because
    // markDead() below is the only thing that does. Safe to widen: nothing
    // else writes late_watch_until on an expired row (the natural-expiry sweep
    // releases the number itself and leaves the column null), so this still
    // matches only rows a close path deliberately handed over.
    .in("status", ["canceled", "expired"])
    .order("late_watch_until", { ascending: true })
    .limit(50);
  if (lateErr) console.error("poll: late-watch select failed", lateErr);

  for (const o of lateWatch ?? []) {
    try {
      if (!o.smspva_id) {
        const { error: clearErr } = await sb
          .from("orders").update({ late_watch_until: null }).eq("id", o.id);
        // Unchecked, a failure here re-selects this row on every run forever —
        // it holds one of the 50 slots below permanently, and enough of them
        // starve the sweep of the rescues it exists to perform.
        if (clearErr) {
          console.error(JSON.stringify({
            alert: "late_watch_clear_failed", order: o.id, detail: clearErr.message,
          }));
        }
        continue;
      }
      // Window closed with no code — reclaim what we can and stop watching.
      // Date comparison, not string. PostgREST renders timestamptz as
      // "+00:00" while JS toISOString() ends in "Z", so a lexical compare is
      // only accidentally correct while the DB session is UTC — and inverts
      // silently if that ever changes, leaving every watched number unreleased.
      if (new Date(o.late_watch_until as string).getTime() <= Date.now()) {
        // 🔴 THE RETRY HERE IS BOUNDED BY A COUNTER, NOT BY THE FLAG — and it
        // has to be, because `late_watch_until` alone cannot express "retry,
        // but not forever". Both orderings that rely on it alone are wrong in
        // one direction:
        //
        //   * markDead() first, clear second: `late_watch_until <= now()` stays
        //     true forever, so a failed clear makes EVERY minutely run
        //     re-cancel-and-ban an already-dead number at the provider, for the
        //     life of the row — unbounded, compounding, and it starves the
        //     50-row budget this sweep shares with real code rescues.
        //   * clear first, markDead second: bounds the DB failure but inverts
        //     the PROVIDER failure, which is the likelier of the two. The flag
        //     is already down, so a throwing markDead() is a PERMANENT forfeit
        //     with no retry — during a provider outage every expiring watched
        //     number forfeits ~$3.50 instead of one.
        //
        // So: increment the attempt counter FIRST, then release. The counter is
        // monotone and is written before the provider is touched, so the number
        // of markDead() calls one order can ever cause is capped at
        // MAX_LATE_RELEASE_ATTEMPTS whatever fails — while a transient provider
        // outage is still retried on the next minutely run.
        //
        // THE BOUND, explicitly: at most MAX_LATE_RELEASE_ATTEMPTS (5) release
        // attempts per order, i.e. ~5 minutes of retrying. On reaching it the
        // row GIVES UP ONCE AND FOR ALL — `late_watch_until` is cleared, the row
        // leaves the sweep permanently, and we forfeit that one number's
        // reclaimable wholesale (~$3.50 worst case). The provider expires the
        // number on its own regardless, and create-order's fresh-number
        // guarantee means it can never be handed back to the same user for the
        // same service. A bounded one-time loss beats both an unbounded
        // provider loop and an outage that is never retried.
        const attempts = (o.late_release_attempts as number | null) ?? 0;
        if (attempts >= MAX_LATE_RELEASE_ATTEMPTS) {
          const { error: giveUpErr } = await sb
            .from("orders").update({ late_watch_until: null }).eq("id", o.id);
          console.error(JSON.stringify({
            alert: "late_watch_release_gave_up", order: o.id, attempts,
            detail: giveUpErr?.message ?? null,
          }));
          continue;
        }

        // Checked, and the release is SKIPPED when it fails. If this write is
        // what is broken, the row is re-selected next run but never reaches the
        // provider — so the pathological case degrades to a row holding one of
        // the 50 slots, never to a repeating cancel-and-ban.
        const { error: bumpErr } = await sb
          .from("orders")
          .update({ late_release_attempts: attempts + 1 })
          .eq("id", o.id);
        if (bumpErr) {
          console.error(JSON.stringify({
            alert: "late_release_attempt_bump_failed", order: o.id,
            detail: bumpErr.message,
          }));
          continue;   // nothing released; retried next run
        }

        await markDead((o.provider ?? "smspva") as OrderProvider, o.smspva_id);

        // Released — stop watching. If THIS clear fails the row comes back next
        // run with the counter already advanced, so it retries at most up to the
        // cap and then gives up above. The re-kill loop stays closed.
        const { error: clearErr } = await sb
          .from("orders").update({ late_watch_until: null }).eq("id", o.id);
        if (clearErr) {
          console.error(JSON.stringify({
            alert: "late_watch_clear_failed", order: o.id, detail: clearErr.message,
          }));
        }
        lateReleased++;
        continue;
      }

      const res = await poll((o.provider ?? "smspva") as OrderProvider, o.smspva_id);
      if (res.state !== "received" || !res.code) continue;

      // Write the code onto the canceled row. `otp is not null` is what the
      // delivery-evidence functions now count as a code, so a rescue correctly
      // credits the route with having delivered.
      const { data: got, error: rescueErr } = await sb
        .from("orders")
        .update({
          otp: res.code,
          raw_message: res.fullText ?? null,
          arrived_at: new Date().toISOString(),
          late_watch_until: null,
        })
        .eq("id", o.id)
        .is("otp", null)
        .select("id");
      // 🔴 AN ERROR AND A LOST RACE PRODUCE THE SAME SHAPE. supabase-js RETURNS
      // errors, so `data` is null on failure just as it is an empty array when
      // `.is("otp", null)` matched nothing — and the bare `!got` test below read
      // both as "another run got there first". A rescued code was then dropped
      // silently: no row, no push, no log, and the user never learns the code
      // they were refunded for actually arrived.
      //
      // Deliberately does NOT clear late_watch_until on this path, so the row
      // stays in the sweep and the next run re-polls and retries the write.
      if (rescueErr) {
        console.error(JSON.stringify({
          alert: "late_code_rescue_write_failed", order: o.id, detail: rescueErr.message,
        }));
        continue;
      }
      if (!got || got.length === 0) continue;   // another run got there first

      await markSuccess((o.provider ?? "smspva") as OrderProvider, o.smspva_id);
      rescued++;
      const svc = o.service as { name: string } | null;
      pushSent += await notify(
        o.user_id,
        `Your ${svc?.name ?? "verification"} code arrived after all`,
        `${res.code} — your ${o.cost_credits} credits were already refunded, so this one's on us.`,
        { event: "late_code", otp: res.code },
      );
    } catch (e) {
      console.error("late-watch failed for order", o.id, e);
    }
  }


  // ── Poll the still-waiting orders for their SMS.
  const { data: pending, error: pErr } = await sb
    .from("orders")
    .select(`
      id, user_id, provider, smspva_id, cost_credits,
      service:service_id ( id, name )
    `)
    .eq("status", "waiting")
    .not("smspva_id", "is", null)
    // Oldest first + hard cap: each row costs a provider round-trip, and the
    // worker dies at ~150s wall clock. 50 sequential polls is already near
    // that budget; anything beyond waits a minute for the next run.
    .order("created_at", { ascending: true })
    .limit(50);

  if (pErr) return json({ error: "list_failed", detail: pErr.message }, { status: 500 });

  for (const o of pending ?? []) {
    polled++;
    let result;
    try {
      result = await poll((o.provider ?? "smspva") as OrderProvider, o.smspva_id!);
    } catch (e) {
      console.error("poll failed for order", o.id, e);
      continue;
    }

    if (result.state === "received" && result.code) {
      // Atomic claim: only flip waiting -> received once, so overlapping runs
      // don't double-notify a delivered code.
      const { data: claimed, error: uErr } = await sb
        .from("orders")
        .update({
          status: "received",
          otp: result.code,
          raw_message: result.fullText ?? null,
          arrived_at: new Date().toISOString(),
          closed_at: new Date().toISOString(),
        })
        .eq("id", o.id)
        .eq("status", "waiting")
        .select("id");

      if (uErr) { console.error("update failed for order", o.id, uErr); continue; }
      if (!claimed || claimed.length === 0) {
        // Same loss class check-order already logs: the code exists at the
        // provider but something (cancel/expiry) closed the order first.
        // This cron path sees far more traffic than manual "Check now" taps,
        // so without this line the true rate of discarded codes is invisible.
        console.warn(
          `poll: code arrived for ${o.id} AFTER it was closed — refund stands, code discarded`,
        );
        continue;
      }

      // Tell SMSPVA the activation succeeded — best-effort karma hygiene.
      await markSuccess((o.provider ?? "smspva") as OrderProvider, o.smspva_id);

      arrived++;
      // Optional-chained: a null embed here used to throw out of the whole
      // handler, aborting every remaining order in the batch.
      const service = o.service as { name: string } | null;
      pushSent += await notify(
        o.user_id,
        `${service?.name ?? "Verification"} code arrived`,
        `Your code is ${result.code}`,
        { orderId: o.id, otp: result.code },
      );
    } else if (result.state === "expired" || result.state === "canceled") {
      // Provider-side close. The status flip and the refund must be ONE
      // transaction — this used to be a claim + a separate wallet_credit, so a
      // worker killed between the two (or a refund error) left a terminal row
      // with the charge never returned, and no sweep revisits terminal rows.
      // expire_order_claim locks, re-checks 'waiting', flips and refunds
      // atomically; false means another worker already closed it.
      const { data: didExpire, error: expErr } = await sb.rpc("expire_order_claim", {
        p_order: o.id,
      });
      if (expErr) {
        console.error(`poll: expire_order_claim failed (provider-close) order=${o.id}: ${expErr.message}`);
        continue; // row stays 'waiting'; the next minutely run retries
      }
      if (!didExpire) continue;
      expired++;
      const svc = o.service as { name: string } | null;
      pushSent += await notify(
        o.user_id,
        "No code arrived",
        `Your ${svc?.name ?? "verification"} number closed — ${o.cost_credits} credits refunded.`,
        { event: "expired", orderId: o.id },
      );
    }
  }

  // `failedFast` is reported separately from `expired` on purpose: they are the
  // same status but different decisions, and collapsing them would hide whether
  // the fail-fast rule is firing at all. Watch it against `rescued` — a rescue
  // rate that climbs means 150s is cutting into real deliveries and the
  // threshold is wrong.
  return json({ expired, failedFast, polled, arrived, pushSent, rescued, lateReleased });
});
