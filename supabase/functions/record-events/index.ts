// record-events — first-party behavioural analytics ingest (2026-08-28).
//
// The client batches UI events (Analytics.swift, ships in 2.6) and posts them
// here; this function is the ONLY writer of public.app_events (RLS on, no
// client policies — a client that could insert rows directly could poison
// every funnel read). JWT-verified: events are keyed to the calling user, and
// an unauthenticated device has nothing we can join to anyway.
//
// Contract (all fields but `events[].name` optional):
//   { events: [{ name, props?, at?, session_id? }], profile?: {
//       storefront?, locale?, timezone?, app_version? } }
//
// Design constraints, in order:
//  - NEVER make the app worse to measure it: bad batches are dropped with a
//    200 wherever safe, and the client fires-and-forgets. Only a malformed
//    body or auth failure errors.
//  - Bounded: max 50 events per batch, names ^[a-z0-9_.]{1,64}$ (also a DB
//    check), props capped at 2KB serialized — oversized props are replaced
//    with {"_truncated":true}, not rejected, so a fat payload cannot silently
//    delete the event it decorates.
//  - `profile` exists here (not only register-push) because register-push is
//    reached only by users who allowed push; this path covers everyone on
//    2.6+, including the StoreKit storefront — the true payment geography.

import { handleCors, json } from "../_shared/cors.ts";
import { admin, callerUserId } from "../_shared/supabaseAdmin.ts";

const MAX_EVENTS = 50;
const MAX_PROPS_BYTES = 2048;
const NAME_RE = /^[a-z0-9_.]{1,64}$/;

interface EventIn {
  name?: unknown;
  props?: unknown;
  at?: unknown;         // ISO timestamp from the device clock — advisory only
  session_id?: unknown; // UUID minted per app session
}
interface Body {
  events?: EventIn[];
  profile?: {
    storefront?: unknown;
    locale?: unknown;
    timezone?: unknown;
    app_version?: unknown;
  };
}

const str = (v: unknown, max: number): string | null =>
  typeof v === "string" && v.length > 0 ? v.slice(0, max) : null;

Deno.serve(async (req) => {
  const cors = handleCors(req); if (cors) return cors;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, { status: 405 });

  const userId = await callerUserId(req);
  if (!userId) return json({ error: "unauthorized" }, { status: 401 });

  let body: Body;
  try { body = await req.json(); }
  catch { return json({ error: "invalid_body" }, { status: 400 }); }

  const sb = admin();

  if (body.profile && typeof body.profile === "object") {
    const p = body.profile;
    const row: Record<string, string> = {};
    const storefront = str(p.storefront, 8);
    const locale = str(p.locale, 32);
    const timezone = str(p.timezone, 64);
    const appVersion = str(p.app_version, 24);
    if (storefront) row.storefront = storefront;
    if (locale) row.device_locale = locale;
    if (timezone) row.timezone = timezone;
    if (appVersion) row.app_version = appVersion;
    if (Object.keys(row).length > 0) {
      const { error } = await sb.from("device_profiles").upsert({
        user_id: userId, ...row, updated_at: new Date().toISOString(),
      }, { onConflict: "user_id" });
      if (error) console.error(`record-events profile write failed user=${userId}: ${error.message}`);
    }
  }

  const events = Array.isArray(body.events) ? body.events.slice(0, MAX_EVENTS) : [];
  const rows: Record<string, unknown>[] = [];
  let dropped = 0;
  for (const e of events) {
    const name = typeof e?.name === "string" ? e.name : "";
    if (!NAME_RE.test(name)) { dropped++; continue; }

    let props: unknown = e.props ?? {};
    if (typeof props !== "object" || props === null || Array.isArray(props)) props = {};
    try {
      if (JSON.stringify(props).length > MAX_PROPS_BYTES) props = { _truncated: true };
    } catch { props = { _truncated: true }; }

    const at = typeof e.at === "string" ? new Date(e.at) : null;
    const sid = typeof e.session_id === "string" &&
        /^[0-9a-f-]{36}$/i.test(e.session_id) ? e.session_id.toLowerCase() : null;

    rows.push({
      user_id: userId,
      session_id: sid,
      name,
      props,
      client_ts: at && !Number.isNaN(at.getTime()) ? at.toISOString() : null,
    });
  }

  if (rows.length > 0) {
    const { error } = await sb.from("app_events").insert(rows);
    if (error) {
      // Analytics must not retry-loop the client; log loudly, answer ok.
      console.error(`record-events insert failed user=${userId} n=${rows.length}: ${error.message}`);
      return json({ ok: false, stored: 0, dropped: dropped + rows.length });
    }
  }

  return json({ ok: true, stored: rows.length, dropped });
});
