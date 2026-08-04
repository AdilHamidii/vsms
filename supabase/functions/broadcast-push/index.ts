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
type Segment = "topped_up" | "not_topped_up" | "all";

/** How far back a wallet 'adjustment' counts as "the top-up we just did".
 *  Deliberately short: this function must not resurrect an older make-good. */
const TOPUP_LOOKBACK_HOURS = 6;

/** A broadcast is not a loop that should ever run away. Well above the ~200
 *  devices on file, low enough to be a real backstop. */
const MAX_DEVICES = 2000;

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
  if (!["topped_up", "not_topped_up", "all"].includes(segment)) {
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
    .eq("reason", "adjustment")
    .gte("created_at", since);
  if (adjErr) {
    console.error("broadcast-push: adjustment read failed:", adjErr.message);
    return json({ error: "segment_read_failed", detail: adjErr.message }, { status: 500 });
  }
  const toppedUp = new Set((adj ?? []).map((r) => r.user_id as string));

  const { data: devices, error: devErr } = await sb
    .from("push_devices")
    .select("user_id, token, environment");
  if (devErr) {
    console.error("broadcast-push: device read failed:", devErr.message);
    return json({ error: "device_read_failed", detail: devErr.message }, { status: 500 });
  }

  const targets = (devices ?? []).filter((d) => {
    if (segment === "all") return true;
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
      title,
      body: alertBody,
    });
  }

  let pushed = 0, failed = 0;
  for (const d of targets) {
    try {
      const r = await sendPush(
        d.token as string,
        { alertTitle: title, alertBody, customData: { broadcast: segment } },
        d.environment as "sandbox" | "production",
      );
      if (r.ok) pushed++;
      else { failed++; console.error("broadcast-push APNs", r.status, r.body); }
    } catch (e) {
      failed++;
      console.error("broadcast-push APNs threw:", e);
    }
  }

  console.log(`broadcast-push: segment=${segment} pushed=${pushed}/${targets.length} failed=${failed}`);
  return json({ segment, devices: targets.length, pushed, failed });
});
