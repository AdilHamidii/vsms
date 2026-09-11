// broadcast-push — send ONE push to a named segment. Moves no money, writes
// no state.
//
// Built 2026-08-04 alongside the bulk top-up to 3 credits. `goodwill-credit`
// already does grant+push, but only per user and only WITH a grant, so it
// cannot announce anything to people whose balance should not change.
//
// Cron-gated like every ops function: trigger via net.http_post with
// private_cron_secret(), so the secret never leaves the database:
//
//   select net.http_post(
//     url := 'https://enugzltysdmjzavisloy.supabase.co/functions/v1/broadcast-push',
//     headers := jsonb_build_object('Content-Type','application/json',
//                                   'x-cron-secret', private_cron_secret()),
//     body := jsonb_build_object('segment','topped_up','dry_run',true,
//                                'title','...','body','...'),
//     timeout_milliseconds := 120000);
//
// MUST be deployed --no-verify-jwt (the relay sends no Authorization header);
// fails closed without the secret.
//
// ⚠️ DRY RUN FIRST. `dry_run: true` resolves the segment and reports the
// device count without contacting APNs. A push cannot be recalled, and the
// two segments here are complements — getting the predicate wrong means
// somebody is told their balance changed when it did not.
//
// Deliberately NOT localized, matching the announcement banner: this is the
// owner's words rendered verbatim, and machine-translating a broadcast would
// put words in their mouth. The in-app screens stay localized.
//
// customData carries NO orderId — PushManager deep-links on that key and
// there is no order here.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import { sendPush } from "../_shared/apns.ts";

/** Segments are computed here, not passed in as a user list, so a caller
 *  cannot accidentally target one person with a broadcast message. */
type Segment = "topped_up" | "not_topped_up" | "all" | "no_line_ever";

/** How far back a wallet credit counts as "the top-up we just did".
 *  Deliberately short: this function must not resurrect an older make-good. */
const TOPUP_LOOKBACK_HOURS = 6;

/** Which ledger reasons mean "we just put credits in your wallet".
 *
 *  `signup_bonus` was added 2026-08-07: the retroactive make-good for the 43
 *  users who signed up while the signup grant was 0 was written with that
 *  reason, which is the semantically correct one — so keying the segment on
 *  'adjustment' alone matched NOBODY, and the only other option was `all`,
 *  which would have told the whole install base their balance changed when it
 *  had not. That is precisely the failure the comment on `Segment` warns about.
 *
 *  ⚠️ Inside the lookback this also matches ordinary NEW signups, who really
 *  did just receive their bonus — so the message stays true for them. Keep any
 *  copy sent through this segment true for both cases: state that credits are
 *  in the wallet, never that they are compensation for something specific. */
const TOPUP_REASONS = ["adjustment", "signup_bonus"];

/** A broadcast is not a loop that should ever run away. Low enough to be a real
 *  backstop, high enough for the install base. ⚠️ Raise this only together with
 *  CONCURRENCY below — the cap and the runtime are the same constraint. */
const MAX_DEVICES = 4000;

/** 🔴 SENDS MUST BE CONCURRENT, OR A FULL BROADCAST CANNOT FINISH.
 *
 *  This function sent one push at a time until 2026-09-11, when a broadcast to
 *  1,746 devices died on the edge runtime's **150s idle timeout** (HTTP 504
 *  `IDLE_TIMEOUT`) partway through the list. An unknown subset was notified and
 *  the rest were not — and because only FAILURES are logged, there was no way
 *  afterwards to tell which. The function was written when ~200 devices were on
 *  file and silently outgrew its own runtime as the install base grew.
 *
 *  25 in flight turns ~1,750 sequential round-trips into ~70 batches, seconds
 *  rather than minutes. Kept modest deliberately: APNs will throttle a single
 *  connection that floods it, and a broadcast has no deadline worth risking
 *  that for. */
const CONCURRENCY = 25;

/** VoIP tokens CANNOT receive an ordinary alert push. They are PushKit tokens
 *  on the `.voip` topic, and APNs answers `400 DeviceTokenNotForTopic` for
 *  every one — 77 of them in the 2026-09-11 broadcast before it timed out, out
 *  of 225 on file (~13% of every broadcast, wasted).
 *
 *  `push_devices` holds BOTH kinds keyed on the same users, because the line
 *  product registers a PushKit token for incoming calls alongside the ordinary
 *  alert token. Selecting the table without this filter is always wrong for a
 *  user-visible message. */
const ALERT_BUNDLE_ID = "com.anthersystems.VirtualSIM";

Deno.serve(async (req) => {
  const pre = handleCors(req);
  if (pre) return pre;

  const secret = Deno.env.get("CRON_SECRET");
  if (!secret || req.headers.get("x-cron-secret") !== secret) {
    return json({ error: "forbidden" }, { status: 403 });
  }

  let body: {
    segment?: Segment;
    title?: string;
    body?: string;
    dry_run?: boolean;
  };
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad_json" }, { status: 400 });
  }

  const segment = body.segment ?? "all";
  if (!["topped_up", "not_topped_up", "all", "no_line_ever"].includes(segment)) {
    return json({ error: "bad_segment" }, { status: 400 });
  }
  const title = (body.title ?? "").trim();
  const alertBody = (body.body ?? "").trim();
  if (!title || !alertBody) return json({ error: "empty_message" }, { status: 400 });

  const sb = admin();

  // Who was topped up. supabase-js RETURNS errors rather than throwing, and a
  // discarded error here would silently turn "topped_up" into an empty set and
  // "not_topped_up" into EVERYONE — i.e. tell the whole install base their
  // balance changed when it did not. Fail loudly instead.
  const since = new Date(Date.now() - TOPUP_LOOKBACK_HOURS * 3600_000).toISOString();
  const { data: adj, error: adjErr } = await sb
    .from("wallet_transactions")
    .select("user_id")
    .in("reason", TOPUP_REASONS)
    .gte("created_at", since);
  if (adjErr) {
    console.error("broadcast-push: adjustment read failed:", adjErr.message);
    return json({ error: "segment_read_failed", detail: adjErr.message }, { status: 500 });
  }
  const toppedUp = new Set((adj ?? []).map((r) => r.user_id as string));

  // Who has EVER held a line subscription, in any state — active, expired,
  // revoked, trial. Used by `no_line_ever`, whose whole purpose is the intro
  // offer: 🔴 **Apple grants ONE introductory offer per subscription GROUP per
  // Apple ID**, so anyone who has ever subscribed is INELIGIBLE and would be
  // charged the full price after being told otherwise. `state` is deliberately
  // not filtered — a lapsed subscriber has still consumed their one intro.
  //
  // Same fail-loud rule as the read above, and here it is worse: a discarded
  // error empties this set, `no_line_ever` becomes EVERYONE, and the people
  // told to buy a number at an intro price they cannot get are precisely the
  // paying subscribers who already have one.
  //
  // ⚠️ Residual, stated plainly: eligibility lives at the APPLE ID, this table
  // is keyed on our user_id. Someone who deleted their account and signed up
  // again reads as "never subscribed" here while Apple still refuses the offer.
  // `line_subscriptions` has no FK to `auth.users` so the old row survives, but
  // the new signup carries a new user_id and cannot be matched to it. 22 users
  // have ever subscribed, so the blast radius is small — but it is not zero.
  const { data: everLine, error: lineErr } = await sb
    .from("line_subscriptions")
    .select("user_id");
  if (lineErr) {
    console.error("broadcast-push: line_subscriptions read failed:", lineErr.message);
    return json({ error: "segment_read_failed", detail: lineErr.message }, { status: 500 });
  }
  const hasHadLine = new Set(
    (everLine ?? []).map((r) => r.user_id as string).filter(Boolean),
  );

  const { data: devices, error: devErr } = await sb
    .from("push_devices")
    .select("user_id, token, environment")
    .eq("bundle_id", ALERT_BUNDLE_ID);   // never the .voip PushKit tokens
  if (devErr) {
    console.error("broadcast-push: device read failed:", devErr.message);
    return json({ error: "device_read_failed", detail: devErr.message }, { status: 500 });
  }

  const targets = (devices ?? []).filter((d) => {
    if (segment === "all") return true;
    if (segment === "no_line_ever") return !hasHadLine.has(d.user_id as string);
    const hit = toppedUp.has(d.user_id as string);
    return segment === "topped_up" ? hit : !hit;
  });

  if (targets.length > MAX_DEVICES) {
    return json({ error: "too_many", devices: targets.length, max: MAX_DEVICES }, { status: 400 });
  }

  if (body.dry_run) {
    return json({
      dry_run: true,
      segment,
      devices: targets.length,
      users: new Set(targets.map((t) => t.user_id)).size,
      topped_up_users_in_window: toppedUp.size,
      ever_subscribed_users_excluded: hasHadLine.size,
      title,
      body: alertBody,
    });
  }

  // CONCURRENCY at a time. See the constant: sequentially this cannot finish
  // inside the 150s idle timeout at the current device count, and a broadcast
  // killed halfway is unrecoverable — a resend double-notifies everyone who
  // already got it, and nothing records who that was.
  let pushed = 0, failed = 0, unregistered = 0;
  const started = Date.now();

  for (let i = 0; i < targets.length; i += CONCURRENCY) {
    await Promise.all(targets.slice(i, i + CONCURRENCY).map(async (d) => {
      try {
        const r = await sendPush(
          d.token as string,
          { alertTitle: title, alertBody, customData: { broadcast: segment } },
          d.environment as "sandbox" | "production",
        );
        if (r.ok) { pushed++; return; }
        failed++;
        // 410 Unregistered is APNs stating the app is GONE from that device.
        // Counted separately so a broadcast's failure number is readable:
        // dead installs are not a delivery problem to go chasing.
        if (r.status === 410) unregistered++;
        else console.error("broadcast-push APNs", r.status, r.body);
      } catch (e) {
        failed++;
        console.error("broadcast-push APNs threw:", e);
      }
    }));
  }

  const elapsedMs = Date.now() - started;
  console.log(`broadcast-push: segment=${segment} pushed=${pushed}/${targets.length} `
    + `failed=${failed} unregistered=${unregistered} elapsed_ms=${elapsedMs}`);
  return json({
    segment, devices: targets.length, pushed, failed, unregistered,
    elapsed_ms: elapsedMs,
  });
});
