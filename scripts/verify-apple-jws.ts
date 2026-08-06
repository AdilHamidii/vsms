#!/usr/bin/env -S deno run --allow-read --allow-net
//
// Assertions for `_shared/iap.ts`'s Apple JWS chain verification, run against
// REAL receipts rather than fixtures.
//
//   # pull a couple of real production receipts out of the DB first
//   supabase db query --linked "select id, raw_jws from public.iap_receipts \
//     where raw_jws is not null and environment='Production' \
//     order by id desc limit 2;"
//   # write each raw_jws to its own file, then:
//   deno run --allow-read --allow-net scripts/verify-apple-jws.ts a.jws b.jws
//
// Run this after ANY change to iap.ts. That file is the only thing standing
// between a free Sign-in-with-Apple account and unlimited minted credits, and
// it has already been a full compromise once (a circular self-signed check)
// and a total purchase outage once (ECDSA P-384 unimplemented on the Supabase
// edge runtime, passing locally the whole time).
//
// ⚠️ Passing locally does NOT prove the hosted runtime works — that is exactly
// how the P-384 outage hid for weeks. Treat a local pass as necessary, never
// sufficient, and confirm a real purchase after deploying.

import {
  verifyTransactionJWS, verifyAppleJWS, IapVerificationError,
  isSubscriptionProduct, creditsForProduct, LINE_SUBSCRIPTION_PRODUCT_ID,
} from "../supabase/functions/_shared/iap.ts";

let pass = 0, fail = 0;
const ok = (n: string, c: boolean, d = "") => {
  console.log(`${c ? "PASS" : "*** FAIL ***"}  ${n}${d ? "  " + d : ""}`);
  c ? pass++ : fail++;
};

const files = Deno.args;
if (files.length === 0) {
  console.error("usage: verify-apple-jws.ts <receipt.jws> [more.jws ...]");
  console.error("(see the header for how to pull real receipts out of the DB)");
  Deno.exit(2);
}

for (const path of files) {
  const jws = (await Deno.readTextFile(path)).trim();
  const name = path.split("/").pop();

  const t = await verifyTransactionJWS(jws);
  ok(`${name} verifies`, true,
     `${t.productId} tx=${t.transactionId} env=${t.environment}`);

  // The generic extraction must be a pure refactor of the transaction path.
  ok(`${name} generic agrees`,
     JSON.stringify((await verifyAppleJWS<typeof t>(jws)).payload) === JSON.stringify(t));

  // One flipped payload byte must break the signature.
  const parts = jws.split(".");
  const b = parts[1].split(""); b[10] = b[10] === "A" ? "B" : "A";
  try {
    await verifyTransactionJWS([parts[0], b.join(""), parts[2]].join("."));
    ok(`${name} rejects tampering`, false, "ACCEPTED A FORGED PAYLOAD");
  } catch (e) {
    ok(`${name} rejects tampering`, e instanceof IapVerificationError,
       (e as IapVerificationError).code);
  }

  // A lone self-signed leaf must not terminate at the pinned Apple root. This
  // is the EXACT shape of the original compromise: take the cert out of the
  // attacker-supplied header and check the attacker-supplied signature against
  // it. It must fail at the chain, not at the signature.
  const hdr = JSON.parse(atob(parts[0].replace(/-/g, "+").replace(/_/g, "/")));
  hdr.x5c = [hdr.x5c[0]];
  const selfHdr = btoa(JSON.stringify(hdr))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  try {
    await verifyTransactionJWS([selfHdr, parts[1], parts[2]].join("."));
    ok(`${name} rejects lone leaf`, false, "ACCEPTED AN UNCHAINED LEAF");
  } catch (e) {
    ok(`${name} rejects lone leaf`, e instanceof IapVerificationError,
       (e as IapVerificationError).code);
  }
}

// The subscription must never be reachable from the credit-granting map: one
// entry there pays out wallet credits on every monthly renewal, forever.
ok("subscription not in credit map",
   creditsForProduct(LINE_SUBSCRIPTION_PRODUCT_ID) === null);
ok("subscription identified", isSubscriptionProduct(LINE_SUBSCRIPTION_PRODUCT_ID));
ok("credit pack not a subscription",
   !isSubscriptionProduct("com.anthersystems.VirtualSIM.credits.12"));
ok("credit pack still maps",
   creditsForProduct("com.anthersystems.VirtualSIM.credits.12") === 12);

console.log(`\n${pass} passed, ${fail} failed`);
if (fail) Deno.exit(1);
