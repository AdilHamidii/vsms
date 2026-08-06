// StoreKit 2 transaction verification.
//
// Apple sends each transaction as a JWS whose header carries an `x5c`
// certificate chain: [leaf, intermediate, root]. The signature is only worth
// anything if that chain provably terminates at APPLE'S root.
//
// ─────────────────────────────────────────────────────────────────────────
// WHAT THIS FILE USED TO DO, AND WHY IT WAS A FULL COMPROMISE
//
// The previous implementation was:
//
//     const leafPem = `-----BEGIN CERTIFICATE-----\n${x5c[0]}\n...`;
//     const leafKey = await importX509(leafPem, "ES256");
//     const { payload } = await jwtVerify(jws, leafKey, ...);
//
// It took the certificate OUT of the attacker-supplied header and then checked
// that the attacker-supplied signature matched that attacker-supplied key.
// That is circular: it proves the JWS is internally consistent, and nothing
// else. Apple is never involved.
//
// Exploit, confirmed by building and running it against this exact code path:
// generate an ES256 keypair, self-sign a certificate, put it in x5c[0], and
// sign any payload you like — bundleId `com.anthersystems.VirtualSIM`,
// productId `...credits.150`. The only prerequisite is a Supabase JWT, which
// Sign in with Apple hands out free and instantly. `transactionId` was only
// checked for truthiness, so a fresh random string per call defeats the
// unique-constraint idempotency and one account can mint credits forever.
// Those credits spend against real provider balances.
//
// The bundle_id check and transaction_id idempotency that the old comment
// cited as mitigations are both fields INSIDE the forged payload.
//
// All 18 receipts on record at the time of the fix were re-verified from
// scratch against a freshly downloaded Apple root — every one genuine. The
// hole was open, not yet used.
//
// ─────────────────────────────────────────────────────────────────────────
// WHAT IT DOES NOW
//
//   1. Verify every hop of the chain cryptographically.
//   2. Terminate at Apple's Root CA - G3, PINNED BY SHA-256 THUMBPRINT and
//      embedded below — never at whatever the caller calls a "root". Pinning
//      by subject name would be defeated by a self-signed certificate whose CN
//      is the string "Apple Root CA - G3", which is trivial to make.
//   3. Require Apple's receipt-signing extension OID on the leaf, so a
//      certificate legitimately issued by Apple for some OTHER purpose cannot
//      be repurposed to sign receipts.
//   4. Check the leaf was valid AT SIGNING TIME (signedDate), not now — so
//      ordinary certificate rotation does not retroactively invalidate old,
//      genuine receipts.
//
// PIN THE ROOT ONLY. The current leaf expires 2027-10-13 and Apple rotates
// intermediates on a normal schedule; pinning anything below the root turns
// the next routine rotation into a total purchase outage. The root below is
// valid until 2039-04-30.
//
// No OCSP/revocation check on purpose. It needs a live round trip to Apple
// during the user's checkout spinner, so an Apple-side outage or timeout would
// fail EVERY legitimate purchase — strictly worse than the risk it covers,
// which requires Apple's own signing infrastructure to be compromised. Apple's
// own reference library also leaves this off by default.

import { decodeProtectedHeader, importX509, jwtVerify } from "https://esm.sh/jose@5.9.4";
import * as x509 from "https://esm.sh/@peculiar/x509@1.12.3";
// Apple Root CA - G3 is ECDSA **P-384 / SHA-384**, and Supabase's edge runtime
// WebCrypto does not implement P-384 verification: the final chain hop threw
// `NotSupportedError: Not implemented`, which surfaced as `chain_verify_failed`
// and REJECTED EVERY PURCHASE on 2026-08-03. The identical code, the same
// pinned library and the same certificate verify `true` on local Deno, so this
// is a hosted-runtime limitation, not a bad cert and not our logic.
//
// Fixed with a pure-JS verification of that one hop rather than by weakening
// the pin. The tempting shortcut — pin the INTERMEDIATE by thumbprint and skip
// the signature check — is exactly what turns Apple's routine intermediate
// rotation into a total purchase outage. Pin the ROOT ONLY still holds.
import { p384 } from "https://esm.sh/@noble/curves@1.6.0/p384";
import { sha384 } from "https://esm.sh/@noble/hashes@1.5.0/sha512";

const ALLOWED_BUNDLE_IDS = ["com.anthersystems.VirtualSIM"];

/** Apple's receipt-signing marker. Present on leaves Apple issues for signing
 *  StoreKit transactions, absent on its other certificates. */
const APPLE_RECEIPT_SIGNING_OID = "1.2.840.113635.100.6.11.1";

/** Apple Root CA - G3. Fetched from
 *  https://www.apple.com/certificateauthority/AppleRootCA-G3.cer and verified:
 *    SHA-256 63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:
 *            7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79
 *    valid   2014-04-30 .. 2039-04-30
 *  If you ever replace this, re-verify that fingerprint from apple.com first. */
const APPLE_ROOT_CA_G3_PEM = `-----BEGIN CERTIFICATE-----
MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwS
QXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9u
IEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcN
MTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBS
b290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9y
aXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49
AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtf
TjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517
IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySr
MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gA
MGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4
at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM
6BgD56KyKA==
-----END CERTIFICATE-----`;

const trustedRoot = new x509.X509Certificate(APPLE_ROOT_CA_G3_PEM);

export interface AppleTransactionPayload {
  transactionId: string;
  originalTransactionId: string;
  webOrderLineItemId?: string;
  bundleId: string;
  productId: string;
  subscriptionGroupIdentifier?: string;
  purchaseDate: number;        // ms since epoch
  originalPurchaseDate: number;
  quantity: number;
  type: string;                // "Consumable" | "Non-Consumable" | etc.
  inAppOwnershipType?: string;
  signedDate: number;
  environment: "Sandbox" | "Xcode" | "Production";

  // ── Auto-renewable subscriptions only ──────────────────────────────────
  // All optional: the five credit packs are consumables and carry none of
  // these, so requiring them would break the path that funds the app today.
  /** ms since epoch. The line's `current_period_end` comes from HERE and
   *  nowhere else — never `purchaseDate + 30 days`, which drifts against
   *  Apple's own clock and is flatly wrong in Sandbox, where a month is five
   *  minutes. */
  expiresDate?: number;
  /** MILLIUNITS — 9990 = 9.99. Same convention as `jws_payload()` in
   *  revenue_snapshot; a hardcoded USD ladder mis-states every non-USD sale. */
  price?: number;
  currency?: string;
  storefront?: string;
  /** Present only on a refunded/revoked transaction. Its presence is the
   *  signal, not its value. */
  revocationDate?: number;
  revocationReason?: number;

  /** 1 = introductory, 2 = promotional, 3 = offer code. Apple omits it
   *  entirely on an ordinary paid period, so ABSENCE means "paying". */
  offerType?: number;
  /** "FREE_TRIAL" | "PAY_AS_YOU_GO" | "PAY_UP_FRONT" on newer payloads. */
  offerDiscountType?: string;
}

/** Thrown for anything that fails the trust checks. Carries a short stable
 *  `code` so iap-verify can log/alert on WHICH check failed — the difference
 *  between "someone is attacking us" and "we broke legitimate purchases". */
export class IapVerificationError extends Error {
  constructor(public code: string, detail?: string) {
    super(detail ? `${code}: ${detail}` : code);
    this.name = "IapVerificationError";
  }
}

function pemFromB64(b64: string): string {
  const body = b64.replace(/\s+/g, "").match(/.{1,64}/g)?.join("\n") ?? b64;
  return `-----BEGIN CERTIFICATE-----\n${body}\n-----END CERTIFICATE-----`;
}

/** The uncompressed EC point inside an SPKI DER blob. P-384 => 0x04 + 48 + 48. */
function p384PointFromSpki(spki: ArrayBuffer): Uint8Array {
  const b = new Uint8Array(spki);
  for (let i = 0; i < b.length; i++) {
    if (b[i] === 0x04 && b.length - i === 97) return b.slice(i);
  }
  throw new IapVerificationError("root_key_unreadable");
}

/** Verify that `cert` was signed by the PINNED Apple root, in pure JS.
 *  Returns false on a bad signature; never throws for a merely invalid cert. */
function verifyAgainstAppleRoot(cert: x509.X509Certificate): boolean {
  const pub = p384PointFromSpki(trustedRoot.publicKey.rawData);
  // `tbs` is the exact bytes the CA signed. It is runtime-public but typed
  // private by @peculiar/x509, so the cast is explicit rather than silent:
  // re-encoding the TBS ourselves would risk verifying different bytes than
  // the ones Apple signed, which is the whole point of the check.
  const tbs = (cert as unknown as { tbs: ArrayBuffer }).tbs;
  const digest = sha384(new Uint8Array(tbs));
  try {
    return p384.verify(new Uint8Array(cert.signature), digest, pub, { prehash: false });
  } catch {
    return false;   // malformed signature encoding is a rejection, not a crash
  }
}

async function sha256Thumbprint(cert: x509.X509Certificate): Promise<string> {
  const buf = await cert.getThumbprint("SHA-256");
  return Array.from(new Uint8Array(buf))
    .map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Verify ANY Apple-signed JWS: the x5c chain, the pinned root, the leaf's
 *  receipt-signing purpose, and the JWS signature itself.
 *
 *  Apple signs several different things with this same chain — StoreKit
 *  transactions, App Store Server Notifications V2 (`signedPayload`), and the
 *  `signedTransactionInfo` / `signedRenewalInfo` nested inside those. They
 *  differ only in PAYLOAD SHAPE, so the trust half is extracted here and the
 *  shape half stays with each caller.
 *
 *  Writing a second verifier for notifications instead would mean maintaining
 *  two copies of the root pin, the P-384 workaround and the OID check — and the
 *  copy that drifts is the one that stops rejecting forgeries.
 *
 *  Returns the leaf alongside the payload so callers can run
 *  `assertSignedWithinValidity` at the right point in their OWN check order.
 *  This function deliberately does NOT do that check itself: moving it here
 *  would reorder the error codes `verifyTransactionJWS` reports, and those
 *  codes are what distinguish "someone is attacking us" from "we just broke
 *  every legitimate purchase". */
export async function verifyAppleJWS<T>(
  jws: string,
): Promise<{ payload: T; leaf: x509.X509Certificate }> {
  let header: ReturnType<typeof decodeProtectedHeader>;
  try {
    header = decodeProtectedHeader(jws);
  } catch (e) {
    throw new IapVerificationError("malformed_jws", String(e));
  }

  const x5c = header.x5c;
  if (!Array.isArray(x5c) || x5c.length === 0) {
    throw new IapVerificationError("missing_x5c");
  }

  let certs: x509.X509Certificate[];
  try {
    certs = x5c.map((c) => new x509.X509Certificate(pemFromB64(String(c))));
  } catch (e) {
    throw new IapVerificationError("unparseable_cert", String(e));
  }

  // Discard any copy of the root the CALLER supplied. We do not care what they
  // sent as a root — we substitute our own pinned copy below. This also makes
  // the code indifferent to whether Apple ships [leaf, intermediate] or
  // [leaf, intermediate, root].
  const rootFp = await sha256Thumbprint(trustedRoot);
  const supplied: x509.X509Certificate[] = [];
  for (const c of certs) {
    if (await sha256Thumbprint(c) !== rootFp) supplied.push(c);
  }
  if (supplied.length === 0) throw new IapVerificationError("no_leaf");

  // Verify each hop among the supplied certs, then verify the topmost one
  // against the PINNED root. A forged chain fails at the last step: the
  // attacker's intermediate is not signed by Apple's root, and they cannot
  // make one that is without Apple's private key.
  try {
    for (let i = 0; i < supplied.length - 1; i++) {
      if (!(await supplied[i].verify({ publicKey: supplied[i + 1].publicKey }))) {
        throw new IapVerificationError("bad_chain_signature", `hop ${i}`);
      }
    }
    const top = supplied[supplied.length - 1];
    // Deliberately NOT `top.verify({publicKey: trustedRoot.publicKey})` — see
    // the import block. Same cryptographic check, computed in JS so it does not
    // depend on the host runtime implementing ECDSA P-384.
    if (!verifyAgainstAppleRoot(top)) {
      throw new IapVerificationError("untrusted_chain");
    }
  } catch (e) {
    if (e instanceof IapVerificationError) throw e;
    throw new IapVerificationError("chain_verify_failed", String(e));
  }

  const leaf = supplied[0];
  if (!leaf.getExtension(APPLE_RECEIPT_SIGNING_OID)) {
    throw new IapVerificationError("wrong_cert_purpose");
  }

  let payload: unknown;
  try {
    const leafKey = await importX509(leaf.toString("pem"), "ES256");
    ({ payload } = await jwtVerify(jws, leafKey, { algorithms: ["ES256"] }));
  } catch (e) {
    throw new IapVerificationError("bad_jws_signature", String(e));
  }

  return { payload: payload as T, leaf };
}

/** Validity is checked at SIGNING time, not now. Checking against now() would
 *  reject genuine old receipts every time Apple rotates its leaf. */
export function assertSignedWithinValidity(
  leaf: x509.X509Certificate,
  signedDate: number | undefined,
): void {
  const signed = new Date(signedDate as number);
  if (!Number.isFinite(signed.getTime())) return;
  if (signed < leaf.notBefore || signed > leaf.notAfter) {
    throw new IapVerificationError("cert_not_valid_at_signing");
  }
}

export async function verifyTransactionJWS(jws: string): Promise<AppleTransactionPayload> {
  const { payload: t, leaf } = await verifyAppleJWS<AppleTransactionPayload>(jws);

  if (!t.transactionId || !t.bundleId || !t.productId) {
    throw new IapVerificationError("malformed_payload");
  }
  if (!ALLOWED_BUNDLE_IDS.includes(t.bundleId)) {
    throw new IapVerificationError("bundle_mismatch", t.bundleId);
  }
  assertSignedWithinValidity(leaf, t.signedDate);

  return t;
}

// ───────────────────────────────────────────────────────────────────────────
// App Store Server Notifications V2
//
// Apple POSTs `{signedPayload}` to our endpoint. That JWS carries the SAME x5c
// chain as a transaction, so it goes through the same verifier — but its
// payload is a notification envelope, and the interesting parts
// (`signedTransactionInfo`, `signedRenewalInfo`) are themselves JWSs that must
// be verified separately. Verifying only the envelope and then trusting its
// nested strings would re-open the exact hole the chain check exists to close.

export interface AppleNotificationData {
  bundleId?: string;
  bundleVersion?: string;
  environment?: "Sandbox" | "Production";
  /** A JWS — verify with verifyTransactionJWS, never decode and trust. */
  signedTransactionInfo?: string;
  /** A JWS — verify with verifyRenewalInfoJWS. */
  signedRenewalInfo?: string;
  status?: number;
}

export interface AppleNotificationPayload {
  notificationType: string;
  subtype?: string;
  /** Apple's idempotency key. Persist BEFORE acting: notifications retry at
   *  1h/12h/24h/48h/72h and reconcile-subscriptions replays the same state
   *  change from the other direction. */
  notificationUUID: string;
  version: string;
  signedDate: number;
  data?: AppleNotificationData;
  summary?: Record<string, unknown>;
  externalPurchaseToken?: Record<string, unknown>;
}

export interface AppleRenewalInfoPayload {
  originalTransactionId: string;
  autoRenewProductId?: string;
  productId?: string;
  autoRenewStatus?: number;          // 1 = on, 0 = off
  expirationIntent?: number;
  isInBillingRetryPeriod?: boolean;
  gracePeriodExpiresDate?: number;
  offerType?: number;
  environment?: "Sandbox" | "Production";
  signedDate: number;
  renewalDate?: number;
}

export async function verifyNotificationJWS(jws: string): Promise<AppleNotificationPayload> {
  const { payload: n, leaf } = await verifyAppleJWS<AppleNotificationPayload>(jws);

  if (!n.notificationType || !n.notificationUUID) {
    throw new IapVerificationError("malformed_payload");
  }
  // `bundleId` lives under `data` here, not at the top level as it does on a
  // transaction. It is absent on some notification types (e.g. the CONSUMPTION
  // family), so this is checked only when present rather than required —
  // requiring it would drop legitimate notifications on the floor.
  const bundleId = n.data?.bundleId;
  if (bundleId && !ALLOWED_BUNDLE_IDS.includes(bundleId)) {
    throw new IapVerificationError("bundle_mismatch", bundleId);
  }
  assertSignedWithinValidity(leaf, n.signedDate);

  return n;
}

export async function verifyRenewalInfoJWS(jws: string): Promise<AppleRenewalInfoPayload> {
  const { payload: r, leaf } = await verifyAppleJWS<AppleRenewalInfoPayload>(jws);

  if (!r.originalTransactionId) {
    throw new IapVerificationError("malformed_payload");
  }
  assertSignedWithinValidity(leaf, r.signedDate);

  return r;
}

const PRODUCT_TO_CREDITS: Record<string, number> = {
  "com.anthersystems.VirtualSIM.credits.5":   5,
  "com.anthersystems.VirtualSIM.credits.12":  12,
  "com.anthersystems.VirtualSIM.credits.30":  30,
  "com.anthersystems.VirtualSIM.credits.60":  60,   // for eSIM plans
  "com.anthersystems.VirtualSIM.credits.150": 150,
};

export function creditsForProduct(productId: string): number | null {
  return PRODUCT_TO_CREDITS[productId] ?? null;
}

/** The rented-line subscription. ⚠️ DELIBERATELY NOT IN `PRODUCT_TO_CREDITS`.
 *
 *  That map feeds `credit_iap_purchase`, which grants wallet credits. A
 *  subscription grants an ENTITLEMENT — a phone number — and must never be
 *  reachable from the credit path: one stray entry there would pay out credits
 *  on every monthly renewal, forever, with the tombstone happily recording each
 *  one as legitimate.
 *
 *  Auto-renewables allow one active subscription per group with no quantity, so
 *  this single product IS the line. More lines later means TIERS inside this
 *  same group, never a second product family here. */
export const LINE_SUBSCRIPTION_PRODUCT_ID =
  "com.anthersystems.VirtualSIM.line.monthly";

/** EVERY product in the line subscription group.
 *
 * 🔴 A product created in App Store Connect and not added here is worse than
 * missing: it falls through `isSubscriptionProduct` into `iap-verify`'s
 * unknown-product branch, which 400s a legitimate purchase, pages the owner,
 * and tells them to add it to `PRODUCT_TO_CREDITS` — which for a subscription
 * would pay wallet credits on every renewal forever.
 *
 * Both live in the SAME subscription group (22289428), which is what makes
 * them upgrade/downgrade siblings Apple prorates, and what stops a user
 * holding both at once. `phone_lines_one_apple_line_per_user` assumes exactly
 * that: a second concurrent Apple line would be refused, so a user in two
 * groups would be paying for a number they can never receive.
 */
export const LINE_SUBSCRIPTION_PRODUCT_IDS: readonly string[] = [
  "com.anthersystems.VirtualSIM.line.monthly",
  "com.anthersystems.VirtualSIM.line.yearly",
];

/** True when this transaction is being served by an introductory offer — for
 *  us, the 3-day free trial on the yearly plan.
 *
 * ⚠️ Nothing may GATE provisioning on this. A trial subscriber is entitled to
 * a working number; that is the entire product they are trialling. It exists
 * so ops can tell a trial apart from a paid period, because the two are
 * otherwise identical in every table we keep — a trial simply carries
 * `price: 0` and an `expiresDate` three days out, and Apple then sends
 * DID_RENEW on conversion or EXPIRED on cancellation, both of which the
 * existing lapse state machine already handles.
 */
export function isFreeTrial(tx: AppleTransactionPayload): boolean {
  return tx.offerType === 1 || tx.offerDiscountType === "FREE_TRIAL";
}

/** `iap-verify` must call this BEFORE `creditsForProduct`. Its unmapped-product
 *  branch returns HTTP 400 `unknown_product` and fires a Telegram alert — so
 *  without this guard, every single renewal pages the owner and 400s a
 *  perfectly legitimate transaction. */
export function isSubscriptionProduct(productId: string): boolean {
  return LINE_SUBSCRIPTION_PRODUCT_IDS.includes(productId);
}
