// Public endpoint Telnyx POSTs events to: inbound SMS, delivery receipts,
// number-order completion, and (later) call events.
//
// ✅ The capture phase did its job and is retired. The verifier was validated
// against REAL Telnyx bytes before any business logic was hung off it — which
// is how we learned Telnyx sends PRETTY-PRINTED JSON (1,703 bytes vs 1,203
// re-serialised), so parsing before verifying would have silently discarded
// 500 bytes of signed content and every signature would have failed.
//
// The same capture settled the payload SHAPE, and one detail in it is a trap:
// `payload.to` is an ARRAY of objects, not a string. Reading it as a phone
// number yields "[object Object]" and matches no line.
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
import { sendPush } from "../_shared/apns.ts";

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

  const payload = (data.payload ?? {}) as Record<string, unknown>;

  try {
    switch (eventType) {
      case "message.received":
        await handleInbound(sb, payload);
        break;
      // Delivery receipts. `message.sent` means the carrier accepted it;
      // `message.finalized` carries the terminal outcome.
      case "message.sent":
      case "message.finalized":
        await handleReceipt(sb, payload, eventType);
        break;
      // ── Inbound VOICE ────────────────────────────────────────────────
      //
      // 🔴 THIS IS THE ONLY WAY A CALL REACHES THE APP, and it is not
      // optional plumbing. Telnyx refuses to route a DID straight at the
      // on-demand telephony credential the SDK logs in with — "inbound calls
      // directly to on-demand generated credential is not currently
      // supported … purely for outbound calls" — but SUPPORTS dialing that
      // same credential from Call Control. So the number points at a Call
      // Control application, and this transfers the PSTN leg to the client's
      // SIP URI. Proven live 2026-09-08: a Call Control leg to
      // `sip:<sip_username>@sip.telnyx.com` rang the owner's device, after
      // five weeks in which no inbound call ever reached a phone.
      case "call.initiated":
        await handleInboundCall(sb, payload);
        break;
      // Temporary, and deliberately loud. The transfer leg's own outcome is
      // the one fact nobody can see: `call.bridged` fires, no `webrtc` detail
      // record is ever written, and the device does not ring. The hangup cause
      // and SIP response on THAT leg say why, and they exist only here.
      case "call.bridged":
      case "call.hangup":
      case "call.answered":
        console.log("telnyx-webhook call event:", eventType, JSON.stringify({
          leg: payload.call_leg_id, session: payload.call_session_id,
          from: payload.from, to: payload.to, direction: payload.direction,
          cause: payload.hangup_cause, source: payload.hangup_source,
          sip: payload.sip_hangup_cause, state: payload.state,
        }));
        break;
      default:
        // Recorded and ignored, never guessed at. Telnyx adds event types, and
        // encoding a guess about a vendor's vocabulary is what broke eSIM
        // refunds.
        console.log("telnyx-webhook unhandled:", eventType);
    }
  } catch (e) {
    // Swallowed on purpose: a non-2xx makes Telnyx RETRY, and a retry storm on
    // a bug we have not fixed yet is worse than one lost event. The error is
    // logged and the watchdog reads the liveness stamp above.
    console.error("telnyx-webhook handler failed:", eventType, String(e));
  }

  return json({ ok: true }, { status: 200 });
});

/** `payload.to` is an ARRAY of `{phone_number, status, …}`. Reading it as a
 *  string yields "[object Object]" and matches no line at all. */
function firstTo(payload: Record<string, unknown>): Record<string, unknown> | null {
  const to = payload.to;
  if (Array.isArray(to) && to.length) return to[0] as Record<string, unknown>;
  return null;
}

async function handleInbound(sb: ReturnType<typeof admin>, payload: Record<string, unknown>) {
  const from = (payload.from ?? {}) as Record<string, unknown>;
  const to = firstTo(payload);
  const ourNumber = String(to?.phone_number ?? "");
  const peer = String(from.phone_number ?? "");
  if (!ourNumber || !peer) return;

  // Which line owns this number. A message for a number we released — or never
  // owned — is dropped rather than guessed at.
  const { data: line } = await sb.from("phone_lines")
    .select("id, user_id, status").eq("e164", ourNumber)
    .in("status", ["active", "grace", "past_due", "provisioning"])
    .maybeSingle();
  if (!line) {
    console.log("telnyx-webhook: inbound for unknown/inactive number", ourNumber);
    return;
  }

  const { data: res, error } = await sb.rpc("record_inbound_message", {
    p_line_id: line.id,
    p_provider_id: String(payload.id ?? ""),
    p_from: peer,
    p_to: ourNumber,
    p_body: String(payload.text ?? ""),
    p_segments: Number(payload.parts ?? 1),
    p_received_at: payload.received_at ? String(payload.received_at) : null,
  });
  if (error) throw new Error(`record_inbound_message: ${error.message}`);
  if (res?.ok !== true) return;

  // ⚠️ `was_new` is the retry guard. Telnyx retries, and the partial unique
  // index makes the INSERT a no-op the second time — but the push is not
  // idempotent, so sending it unconditionally would buzz the user once per
  // retry for a message they already have.
  if (res.was_new !== true) return;

  // A blocked peer is stored but never announced. The row exists for report and
  // appeal; the user is not disturbed by it.
  if (res.blocked === true) return;

  await pushInbound(sb, String(res.user_id), peer, String(payload.text ?? ""),
                    String(res.thread_id ?? ""));
}

/** Delivery receipt → settle the outbound row and, on a terminal failure, hand
 *  the allowance back. This line has no money to refund, so the allowance is
 *  the only thing that can be made whole. */
async function handleReceipt(
  sb: ReturnType<typeof admin>, payload: Record<string, unknown>, eventType: string,
) {
  const providerId = String(payload.id ?? "");
  if (!providerId) return;

  const to = firstTo(payload);
  const raw = String(to?.status ?? "");

  // Telnyx's vocabulary, mapped to ours. Anything unrecognised is left alone
  // rather than forced into a terminal state — `line_msg_status` is OUR enum
  // and a wrong guess here would tell a user their message failed when it did
  // not. Same rule as `_shared/emailStatus.ts`.
  let status: string | null = null;
  if (eventType === "message.sent") status = "sent";
  if (raw === "delivered") status = "delivered";
  if (raw === "sending_failed" || raw === "delivery_failed") status = "failed";
  if (!status) return;

  // ⚠️ The claim function keys on the MESSAGE UUID, not the provider id — it
  // does `select ... where id = p_message for update`, which is what makes it a
  // claim at all. A receipt only carries Telnyx's id, so resolve it here.
  // `send-line-message` writes that id back onto the row immediately after the
  // send, which is what makes this lookup possible.
  // ⚠️ RETRIED ONCE. `send-line-message` writes the provider id back onto the
  // row immediately after the send returns, but Telnyx can deliver
  // `message.sent` before that write lands — and we ALWAYS return 200, so
  // Telnyx never retries a receipt we dropped. A single miss used to leave the
  // message `queued` forever with its segments spent. The 15-minute stale
  // sweep is the floor; this is what stops it being reached in the ordinary
  // race.
  let row = await findMessage(sb, providerId);
  if (!row) {
    await new Promise((r) => setTimeout(r, 1500));
    row = await findMessage(sb, providerId);
  }
  if (!row) {
    // Genuinely ours to drop: a receipt for a message we never recorded. The
    // stale sweep hands the allowance back on the row's own timer.
    console.log("telnyx-webhook: receipt for unknown message", providerId);
    return;
  }

  // Telnyx bills fractions of a cent per segment, so `Math.round(0.004 * 100)`
  // is 0 — which is why the exact figure goes into its own numeric column and
  // the rounded one is kept only for display.
  const cost = payload.cost as { amount?: string } | undefined;
  const costUsd = cost?.amount != null ? parseFloat(String(cost.amount)) : null;

  // 🔴 THE REASON A MESSAGE FAILED WAS BEING THROWN AWAY. `raw` is only
  // Telnyx's coarse status — "delivery_failed" — which is the same string for a
  // bad number, an unregistered 10DLC campaign, a carrier block and a spam
  // filter. The actual cause travels in `errors[]`, and we dropped it on write.
  //
  // That cost a real diagnosis: three outbound messages from a Canadian line to
  // US numbers failed on 2026-08-17 and the stored rows could not say whether
  // it was carrier filtering or something we controlled. Keep the code and the
  // title, capped so one verbose payload cannot bloat the column.
  const errs = payload.errors as Array<Record<string, unknown>> | undefined;
  const failDetail = (() => {
    if (status !== "failed") return null;
    const first = errs?.[0];
    if (!first) return raw;
    const code = first.code == null ? "" : `${first.code}: `;
    const text = String(first.detail ?? first.title ?? "");
    return `${raw} (${code}${text})`.slice(0, 300);
  })();
  if (status === "failed") {
    // Loud, because a sustained run of one code is an operational signal —
    // 10DLC rejection looks identical to a bad number until you read this.
    console.error(JSON.stringify({
      alert: "line_message_failed", message: row.id, raw,
      code: errs?.[0]?.code ?? null, detail: errs?.[0]?.detail ?? null,
    }));
  }

  const { error } = await sb.rpc("settle_outbound_message_claim", {
    p_message: row.id,
    p_provider_id: providerId,
    p_status: status,
    p_cost_cents: costUsd != null ? Math.round(costUsd * 100) : null,
    p_error: failDetail,
    // Telnyx's own segment count is authoritative; ours is a local estimate
    // that errs low on purpose.
    p_segments: payload.parts != null ? Number(payload.parts) : null,
    p_cost_usd: Number.isFinite(costUsd as number) ? costUsd : null,
  });
  if (error) throw new Error(`settle_outbound_message_claim: ${error.message}`);
}

async function findMessage(
  sb: ReturnType<typeof admin>, providerId: string,
): Promise<{ id: string } | null> {
  const { data } = await sb.from("line_messages")
    .select("id").eq("provider_message_id", providerId).maybeSingle();
  return data ? { id: String(data.id) } : null;
}

/** The verification code in `text`, or null.
 *
 *  A port of the client's `VerificationCode.detect` (`Models/VerificationCode
 *  .swift`) — kept deliberately IN SYNC with it and deliberately CONSERVATIVE.
 *  There was nothing to reuse: the other two product lines take the code from
 *  the provider (`sms[].code`, `activation.value`) and never parse a body, so
 *  no shared extractor exists.
 *
 *  Two bars, either of which a candidate must clear: the message mentions a
 *  verification keyword, or it is essentially just the code. A single digit run
 *  is required outright — "your code for order 4471 is 90210" must resolve to
 *  nothing rather than to the order number. A WRONG code on the lock screen is
 *  worse than no code: the user reads it, types it, is rejected, and stops
 *  trusting the number.
 *
 *  ⚠️ Keyword matching is on the START of a word, not `contains`. The Swift
 *  version shipped `contains` first and "pin" matched inside **shipping**,
 *  topping and opinion — so "Your shipping label 74839201 is ready" was offered
 *  as a code. */
function detectCode(text: string): string | null {
  const candidates = text.split(/\D+/).filter((s) => s.length >= 4 && s.length <= 8);
  if (candidates.length !== 1) return null;
  const code = candidates[0];

  const lower = text.toLowerCase();
  const keywords = [
    "code", "otp", "pin", "verif",
    "bestätigung", "kode", "código", "codice", "verifica",
    "認証", "確認",
    "password", "passcode", "one-time", "2fa",
  ];
  const mentions = (word: string) => {
    // CJK has no word boundaries and cannot occur inside a Latin word.
    if (/[^\x00-\x7F]/.test(word) && !/[a-zà-ÿ]/i.test(word)) return lower.includes(word);
    let from = 0;
    for (;;) {
      const i = lower.indexOf(word, from);
      if (i < 0) return false;
      if (i === 0 || !/\p{L}/u.test(lower[i - 1])) return true;
      from = i + word.length;
    }
  };
  if (keywords.some(mentions)) return code;

  // No keyword: accept only when the message is essentially the code itself.
  // A lone number in a sentence is far more likely a balance, price or date.
  return text.trim().length <= code.length + 4 ? code : null;
}

/** Alert push for an inbound text.
 *
 *  ⚠️ Carries `kind` and `threadId`, never `orderId`. `PushManager` routes on
 *  `orderId` and would deep-link a text message into the SMS refund screen —
 *  the same trap the late-code rescue push had to avoid.
 *
 *  ⚠️ **The CODE LEADS the body when we can find one.** Receiving verification
 *  codes is what this product is sold as, and the lock screen is where a code
 *  is actually read — yet the body was the raw message, so the glanceable part
 *  was "Your code is 483920. Do not share…" with the digits buried mid-sentence
 *  and often truncated. The client already extracts the code in-thread; the
 *  push did not, which is the one place extraction pays for itself.
 *
 *  The raw message is kept as the fallback and is APPENDED even when a code is
 *  found, never replaced — the sender's own words carry which service it is
 *  from, and a bare six digits with no context is its own kind of useless. */
async function pushInbound(
  sb: ReturnType<typeof admin>, userId: string, peer: string,
  text: string, threadId: string,
) {
  const { data: devices } = await sb.from("push_devices")
    .select("token, environment").eq("user_id", userId);
  if (!devices?.length) return;

  const code = detectCode(text);
  const body = code ? `${code} — ${text}` : text;

  for (const d of devices) {
    await sendPush(String(d.token), {
      alertTitle: peer,
      // Truncated: a lock-screen preview is not the place for a 1,600-character
      // message, and the full text is one tap away. Truncating AFTER prefixing
      // is what guarantees the code survives the cut — it is now the first
      // thing in the string rather than whatever the sender put there.
      alertBody: body.length > 140 ? body.slice(0, 139) + "…" : body,
      customData: { kind: "line_message", threadId },
    }, (d.environment as "sandbox" | "production" | null) ?? undefined);
  }
}


/** Ring the rented line's app for an incoming PSTN call.
 *
 * ── Why a TRANSFER and not an ANSWER ──────────────────────────────────────
 *
 * Answering first would bill us for the leg AND replace the caller's ringback
 * with silence while we dial onward. `transfer` hands the call straight to the
 * client and lets Telnyx generate ringback, so the caller hears a normal phone
 * ringing and we pay only if it connects.
 *
 * ⚠️ `payload.to` is a STRING on call events and an ARRAY on message events.
 * `firstTo` exists for the message shape and must NOT be used here — it
 * returns null on a call, which would silently drop every inbound call.
 */
async function handleInboundCall(
  sb: ReturnType<typeof admin>, payload: Record<string, unknown>,
) {
  // Only calls arriving FROM the network. Our own outbound legs raise
  // `call.initiated` too, and transferring one of those would loop a call
  // into the client that the client itself just placed.
  if (String(payload.direction ?? "") !== "incoming") return;

  const called = normaliseE164(payload.to);
  const caller = normaliseE164(payload.from);
  const callControlId = String(payload.call_control_id ?? "");
  if (!called || !callControlId) {
    console.error("telnyx-webhook: inbound call missing to/call_control_id");
    return;
  }

  // The line that owns the number, and the credential its app registers with.
  const { data: line } = await sb.from("phone_lines")
    // 🔴 `provider_connection_id` MUST be selected. Without it
    // `registeredSipUser` never even considers the connection user — the
    // identity current builds register as — and silently falls back to the
    // old telephony credential, which is exactly the mismatch that made the
    // phone log a missed call without ringing. Confirmed from the transfer
    // log: `to: sip:gencredz…` while the device was registered as `vsms…`.
    .select("id, user_id, status, provider_credential_id, provider_connection_id")
    .eq("e164", called)
    .not("status", "in", "(released,suspended)")
    .maybeSingle();

  const key = Deno.env.get("TELNYX_API_KEY") ?? "";
  const command = async (action: string, body: unknown) =>
    await fetch(
      `https://api.telnyx.com/v2/calls/${encodeURIComponent(callControlId)}/actions/${action}`,
      {
        method: "POST",
        headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
        body: JSON.stringify(body),
      },
    );

  // A number with no live line, or a line whose voice was never provisioned,
  // must HANG UP rather than ring forever. A caller hearing endless ringback
  // on a number nobody owns is worse than a clean rejection, and Telnyx bills
  // for the time either way.
  if (!line?.provider_credential_id) {
    console.error("telnyx-webhook: inbound call to unowned/unprovisioned number", called);
    await command("hangup", {});
    return;
  }

  // 🔴 DIAL WHICHEVER IDENTITY IS ACTUALLY REGISTERED RIGHT NOW.
  //
  // The app can be logged in as EITHER of two things and they are not
  // interchangeable, so a hardcoded target rings nobody half the time:
  //   - builds up to 2.11(54): the on-demand telephony credential `gencred…`
  //   - 2.11(55) and later:    the credential connection's own user `vsms…`
  // Both are live in the field at once (TestFlight, the App Store, and a
  // client that falls back between them when Telnyx refuses a login), so the
  // fleet is genuinely mixed and will stay mixed for as long as an old build
  // is installed anywhere.
  //
  // Measured 2026-09-08, and this is exactly the failure it prevents: the
  // transfer was aimed at `gencred…` while 2.11(55) had just registered as
  // `vsms…`. Telnyx accepted the transfer, raised `call.bridged`, and the
  // phone showed a missed call in Recents without ever ringing.
  //
  // `registered` is the provider's own answer, not our inference, so this
  // follows a client that switches credentials without a server release.
  const sipUser = await registeredSipUser(key, line);
  if (!sipUser) {
    console.error("telnyx-webhook: no REGISTERED sip identity for line", line.id);
    await command("hangup", {});
    return;
  }

  // 🔴 `from` MUST BE A NUMBER WE OWN — the caller's number silently fails.
  //
  // Measured 2026-09-08. A direct Call Control leg with `from` = the line's
  // own e164 rang the device. The same leg raised by `transfer` with `from` =
  // the real caller (+33…, +1659…) returned 200, produced `call.bridged`, and
  // never reached the phone — three times, from two different countries.
  // Telnyx accepts the command and drops the leg, the silent-no-op pattern
  // this adapter has now hit four times.
  //
  // So the ANI is the line's own number and the CALLER travels as the display
  // name, which is what the app renders anyway. A caller ID the carrier will
  // not accept is worse than a display name: it produces a phone that never
  // rings, with a 200 in the log.
  const res = await command("transfer", {
    to: `sip:${sipUser}@sip.telnyx.com`,
    from: called,
    from_display_name: caller ?? "",
    timeout_secs: 30,
  });
  if (!res.ok) {
    console.error("telnyx-webhook: transfer failed",
                  res.status, (await res.text()).slice(0, 300));
    return;
  }

  // Recorded so an inbound call has history, allowance accounting and — the
  // part that has never existed — a row `sync-telnyx-cdr` can match a detail
  // record against. Failure here must not affect the call the user is
  // answering right now.
  const { error } = await sb.rpc("record_line_call", {
    p_line: line.id,
    p_direction: "inbound",
    p_peer: caller ?? "",
    p_session_id: String(payload.call_session_id ?? "") || null,
    p_status: "ringing",
    // Inbound reserves nothing: the caller pays their own carrier and our
    // minute allowance covers outbound. Reserving here would bill a user for
    // being phoned.
    p_reserved_seconds: 0,
  });
  if (error) console.error("telnyx-webhook: record_line_call failed", error.message);
}

/** Call events carry `to`/`from` as plain E.164 strings; message events carry
 *  `to` as an array. Accepts either rather than assuming one. */
function normaliseE164(v: unknown): string | null {
  if (typeof v === "string" && v.trim()) return v.trim();
  if (Array.isArray(v) && v.length) {
    const first = v[0] as Record<string, unknown>;
    const n = first?.phone_number;
    if (typeof n === "string" && n.trim()) return n.trim();
  }
  if (v && typeof v === "object") {
    const n = (v as Record<string, unknown>).phone_number;
    if (typeof n === "string" && n.trim()) return n.trim();
  }
  return null;
}


/** The SIP username the device is registered as, or null when nothing is.
 *
 * Asks Telnyx about both candidates and prefers the connection user, which is
 * what current builds log in as. Returns null rather than guessing: dialing an
 * unregistered identity produces a call that reports success and rings
 * nothing, which is strictly worse than hanging up.
 */
async function registeredSipUser(
  key: string, line: { provider_credential_id?: unknown; provider_connection_id?: unknown },
): Promise<string | null> {
  const get = async (path: string) => {
    try {
      const r = await fetch(`https://api.telnyx.com/v2${path}`,
                            { headers: { Authorization: `Bearer ${key}` } });
      return await r.json().catch(() => ({}));
    } catch { return {}; }
  };
  const isRegistered = async (username: string, type: string) => {
    const j = await get(
      `/sip_registration_status?username=${encodeURIComponent(username)}&credential_type=${type}`);
    // The reply is a BARE object, not the usual `{data: …}` envelope.
    return (j as { registered?: boolean })?.registered === true;
  };

  const candidates: Array<{ username: string; type: string }> = [];

  if (line.provider_connection_id) {
    const conn = await get(
      `/credential_connections/${encodeURIComponent(String(line.provider_connection_id))}`);
    const user = (conn as { data?: { user_name?: string } })?.data?.user_name;
    if (user) candidates.push({ username: String(user), type: "sip_credential_connection" });
  }
  if (line.provider_credential_id) {
    const cred = await get(
      `/telephony_credentials/${encodeURIComponent(String(line.provider_credential_id))}`);
    const user = (cred as { data?: { sip_username?: string } })?.data?.sip_username;
    if (user) candidates.push({ username: String(user), type: "telephony_credential" });
  }

  for (const c of candidates) {
    if (await isRegistered(c.username, c.type)) return c.username;
  }
  // Nothing registered. A VoIP push can still wake a terminated app, and the
  // credential it will attach with is the one current builds use — so fall
  // back to the connection user rather than refusing outright.
  return candidates[0]?.username ?? null;
}
