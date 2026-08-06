#!/usr/bin/env -S deno run --allow-net --allow-env
//
// Assertions for `_shared/telnyx.ts`'s webhook signature verifier.
//
//   deno run --allow-net --allow-env scripts/verify-telnyx-signature.ts
//
// Self-contained: it generates its own Ed25519 keypair, so it needs no Telnyx
// account, no secrets and no network beyond the esm.sh import.
//
// This exists because a verified webhook and a decorative one look identical
// until you try to break them. It is the repo's standing four-assertion rule
// (valid passes / flipped byte fails / stale timestamp fails / no signature
// fails) plus the failure modes that are specific to this verifier.
//
// It also REPLAYS a real captured webhook when given one:
//
//   supabase db query --linked \
//     "select value::text from app_config where key='telnyx_webhook_last';"
//   # save the JSON object to capture.json, then:
//   deno run --allow-read --allow-net --allow-env \
//     scripts/verify-telnyx-signature.ts capture.json
//
// A locally-generated signature proves the ALGORITHM; only a real one proves we
// agreed with Telnyx about WHAT is signed. Done for real on 2026-08-05 — 6/6.
// The capture is not committed: this repo is public and it contains live
// numbers.
//
// 🔴 That replay found the thing worth remembering: Telnyx sends PRETTY-PRINTED
// JSON. The captured body was 1,703 bytes and JSON.parse -> JSON.stringify
// yields 1,203. Parsing before verifying silently discards 500 bytes of signed
// content, and every signature fails.

import { ed25519 } from "https://esm.sh/@noble/curves@1.6.0/ed25519";
import {
  verifyTelnyxSignature, classifyTelnyxFault, faultOf,
  TELNYX_SIGNATURE_TOLERANCE_SECONDS,
} from "../supabase/functions/_shared/telnyx.ts";

let pass = 0, fail = 0;
const ok = (n: string, c: boolean, d = "") => {
  console.log(`${c ? "PASS" : "*** FAIL ***"}  ${n}${d ? "  " + d : ""}`);
  c ? pass++ : fail++;
};
const b64 = (u: Uint8Array) => btoa(String.fromCharCode(...u));

const priv = ed25519.utils.randomPrivateKey();
const pubB64 = b64(ed25519.getPublicKey(priv));
const NOW = 1_800_000_000;

const body = JSON.stringify({
  data: {
    event_type: "message.received",
    id: "msg_ext_1",
    payload: { from: { phone_number: "+15551110000" }, text: "hello" },
  },
});
const sign = (ts: number, b: string) =>
  b64(ed25519.sign(new TextEncoder().encode(`${ts}|${b}`), priv));

const good = sign(NOW, body);

ok("valid signature accepted",
   verifyTelnyxSignature(body, good, String(NOW), pubB64, NOW).ok);

const r2 = verifyTelnyxSignature(body.replace("hello", "hellp"), good,
                                 String(NOW), pubB64, NOW);
ok("tampered body rejected", !r2.ok && r2.reason === "bad_signature",
   r2.ok ? "" : r2.reason);

// THE trap the verifier's doc comment warns about: parse -> re-serialize
// changes the bytes, so it must be verified BEFORE parsing.
ok("re-serialized body rejected (whitespace)",
   !verifyTelnyxSignature(JSON.stringify(JSON.parse(body), null, 2), good,
                          String(NOW), pubB64, NOW).ok);

const r4 = verifyTelnyxSignature(body, good, String(NOW), pubB64,
                                 NOW + TELNYX_SIGNATURE_TOLERANCE_SECONDS + 1);
ok("stale timestamp rejected", !r4.ok && r4.reason === "stale_timestamp",
   r4.ok ? "" : r4.reason);

// A far-future timestamp is what makes a captured request replayable forever,
// which is why the window is an ABSOLUTE difference.
const future = sign(NOW + 10_000, body);
const r4b = verifyTelnyxSignature(body, future, String(NOW + 10_000), pubB64, NOW);
ok("far-future timestamp rejected", !r4b.ok && r4b.reason === "stale_timestamp",
   r4b.ok ? "" : r4b.reason);

ok("inside the window accepted",
   verifyTelnyxSignature(body, good, String(NOW), pubB64,
     NOW + TELNYX_SIGNATURE_TOLERANCE_SECONDS - 1).ok);

for (
  const [name, res] of [
    ["no signature", verifyTelnyxSignature(body, null, String(NOW), pubB64, NOW)],
    ["no timestamp", verifyTelnyxSignature(body, good, null, pubB64, NOW)],
    ["no public key", verifyTelnyxSignature(body, good, String(NOW), undefined, NOW)],
    ["non-numeric timestamp", verifyTelnyxSignature(body, good, "abc", pubB64, NOW)],
    ["garbage signature", verifyTelnyxSignature(body, "!!!!", String(NOW), pubB64, NOW)],
    ["short signature",
      verifyTelnyxSignature(body, b64(new Uint8Array(10)), String(NOW), pubB64, NOW)],
  ] as const
) ok(`${name} rejected`, !res.ok, res.ok ? "" : res.reason);

const otherSig = b64(ed25519.sign(new TextEncoder().encode(`${NOW}|${body}`),
                                  ed25519.utils.randomPrivateKey()));
const r6 = verifyTelnyxSignature(body, otherSig, String(NOW), pubB64, NOW);
ok("wrong signing key rejected", !r6.ok && r6.reason === "bad_signature",
   r6.ok ? "" : r6.reason);

// The timestamp is inside the signed message, so it cannot be swapped to slide
// a captured signature into a fresh window.
ok("timestamp swap rejected",
   !verifyTelnyxSignature(body, good, String(NOW + 1), pubB64, NOW + 1).ok);

// A thrown verifier becomes a 500, and Telnyx RETRIES a 500 — one bad request
// would become a retry storm.
try {
  verifyTelnyxSignature(body, b64(new Uint8Array(64)), String(NOW), pubB64, NOW);
  ok("malformed point does not throw", true);
} catch (e) { ok("malformed point does not throw", false, String(e)); }

ok("401 -> AUTH_ERROR", classifyTelnyxFault(401) === "AUTH_ERROR");
ok("429 -> RATE_LIMITED", classifyTelnyxFault(429) === "RATE_LIMITED");
ok("402 -> BALANCE_ERROR", classifyTelnyxFault(402) === "BALANCE_ERROR");
ok("unknown 500 -> TRANSPORT_ERROR", classifyTelnyxFault(500) === "TRANSPORT_ERROR");
// Never guess stockout for an unknown failure: on this line there is no other
// country to shop to, so it reads as the product simply not working.
ok("unknown 422 -> TRANSPORT_ERROR, not stockout",
   classifyTelnyxFault(422, "something_else") === "TRANSPORT_ERROR");
ok("faultOf guards",
   faultOf({ telnyxFault: true, type: "AUTH_ERROR", status: 401 }) &&
   !faultOf({ id: "x" } as unknown as { telnyxFault: true }));

// ── Optional: replay a REAL captured webhook ───────────────────────────────
// Shape: {raw, signature, timestamp} as written by telnyx-webhook's capture
// phase into app_config.telnyx_webhook_last.
if (Deno.args[0]) {
  const cap = JSON.parse(await Deno.readTextFile(Deno.args[0]));
  const key = Deno.env.get("TELNYX_PUBLIC_KEY");
  if (!key) {
    console.error("\nTELNYX_PUBLIC_KEY not set; skipping the real-capture replay");
  } else {
    const t = Number(cap.timestamp);
    console.log("\n--- replaying real captured webhook ---");

    const a = verifyTelnyxSignature(cap.raw, cap.signature, cap.timestamp, key, t);
    ok("REAL webhook verifies", a.ok, a.ok ? "" : a.reason);

    const flipped = cap.raw.slice(0, 100) +
      (cap.raw[100] === "a" ? "b" : "a") + cap.raw.slice(101);
    ok("REAL: flipped byte rejected",
       !verifyTelnyxSignature(flipped, cap.signature, cap.timestamp, key, t).ok);

    // Telnyx pretty-prints, so this drops ~30% of the signed bytes.
    const reser = JSON.stringify(JSON.parse(cap.raw));
    ok("REAL: re-serialized body rejected",
       !verifyTelnyxSignature(reser, cap.signature, cap.timestamp, key, t).ok,
       `(${cap.raw.length} -> ${reser.length} bytes)`);

    ok("REAL: replay past the window rejected",
       !verifyTelnyxSignature(cap.raw, cap.signature, cap.timestamp, key, t + 301).ok);

    ok("REAL: timestamp cannot be slid forward",
       !verifyTelnyxSignature(cap.raw, cap.signature, String(t + 1), key, t + 1).ok);
  }
}

console.log(`\n${pass} passed, ${fail} failed`);
if (fail) Deno.exit(1);
