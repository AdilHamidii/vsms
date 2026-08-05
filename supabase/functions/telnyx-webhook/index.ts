// Public endpoint Telnyx POSTs events to: inbound SMS, delivery receipts,
// number-order completion, and (later) call events.
//
// 🚧 CAPTURE PHASE. This currently VERIFIES and RECORDS only — it does not yet
// write to line_messages or push anything. It exists this early for one reason:
// a signature verifier written against a self-generated keypair proves the
// ALGORITHM, and only a real signed request proves we agreed with Telnyx about
// WHAT is signed. Everything downstream sits behind this check, so it gets
// validated against real bytes before any business logic depends on it.
//
// THREAT MODEL: this URL is guessable and, like telegram-webhook, cannot sit
// behind a JWT — Telnyx's servers must reach it. One gate, and it is
// cryptographic: Ed25519 over `${telnyx-timestamp}|${rawBody}`, plus a 300s
// replay window. It FAILS CLOSED. Every other provider path in this codebase
// degrades gracefully on an unreadable response; this one must not, because an
// unverified webhook is someone else's message written into a user's thread.
//
// ⚠️ MUST be deployed --no-verify-jwt. Telnyx sends no Authorization header, and
// config.toml has no entry for this function, so the flag is the only control.
// Deployed without it, every event 401s and the line goes silently deaf — the
// same failure telegram-webhook documents.
//
// ⚠️ ALWAYS returns 200, including on rejection. A non-2xx makes Telnyx RETRY,
// so a forged or malformed request would become a retry storm; and a 401 would
// confirm to an attacker that the endpoint exists and their guess was wrong.
// Rejections are counted instead, and the watchdog reads that counter.

import { handleCors, json } from "../_shared/cors.ts";
import { admin } from "../_shared/supabaseAdmin.ts";
import { verifyTelnyxRequest } from "../_shared/telnyx.ts";

const CAPTURE_KEY = "telnyx_webhook_last";
const SEEN_KEY = "telnyx_webhook_seen_at";
const REJECT_KEY = "telnyx_webhook_rejects";

Deno.serve(async (req) => {
  const pre = handleCors(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ ok: true }, { status: 200 });

  // 🔴 Read the body ONCE, as text, and verify the RAW bytes. Parsing first and
  // re-serialising verifies a DIFFERENT document than the one Telnyx signed —
  // key order and whitespace both change — and every signature would fail.
  // Parse only after the signature passes.
  const raw = await req.text();
  const result = verifyTelnyxRequest(req, raw);

  const sb = admin();

  if (!result.ok) {
    // Counted, not thrown. A silent 200 that also silently forgets would leave
    // a rotated signing key or a mis-set webhook URL completely invisible —
    // exactly the Telegram allowed_updates failure, where every callback_query
    // was dropped upstream with "nothing logged, no error, no trace".
    const { data } = await sb.from("app_config").select("value")
      .eq("key", REJECT_KEY).maybeSingle();
    const prev = (data?.value as { count?: number } | null)?.count ?? 0;
    await sb.from("app_config").upsert({
      key: REJECT_KEY,
      value: { count: prev + 1, last_reason: result.reason, at: new Date().toISOString() },
    }, { onConflict: "key" });

    console.error("telnyx-webhook rejected:", result.reason);
    return json({ ok: true }, { status: 200 });
  }

  let event: Record<string, unknown> = {};
  try {
    event = JSON.parse(raw);
  } catch {
    console.error("telnyx-webhook: verified signature but unparseable body");
  }
  const data = (event.data ?? {}) as Record<string, unknown>;
  const eventType = String(data.event_type ?? "unknown");

  // Liveness signal for run_watchdog. Silence here while an active line exists
  // is the symptom of a rotated signing key or a webhook URL pointing nowhere —
  // a failure that is otherwise completely invisible, because nothing errors.
  await sb.from("app_config").upsert({
    key: SEEN_KEY, value: { at: new Date().toISOString(), event_type: eventType },
  }, { onConflict: "key" });

  // Capture phase: keep the whole verified request so the verifier can be
  // replayed against REAL Telnyx bytes, and so the payload shape of each event
  // type can be read off a live example rather than guessed from the docs.
  // Remove this once the event handlers land — it stores message bodies.
  await sb.from("app_config").upsert({
    key: CAPTURE_KEY,
    value: {
      at: new Date().toISOString(),
      event_type: eventType,
      signature: req.headers.get("telnyx-signature-ed25519"),
      timestamp: req.headers.get("telnyx-timestamp"),
      raw,
    },
  }, { onConflict: "key" });

  console.log("telnyx-webhook verified:", eventType);
  return json({ ok: true }, { status: 200 });
});
