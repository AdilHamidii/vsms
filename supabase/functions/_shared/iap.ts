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

async function sha256Thumbprint(cert: x509.X509Certificate): Promise<string> {
  const buf = await cert.getThumbprint("SHA-256");
  return Array.from(new Uint8Array(buf))
    .map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function verifyTransactionJWS(jws: string): Promise<AppleTransactionPayload> {
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
    if (!(await top.verify({ publicKey: trustedRoot.publicKey }))) {
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

  const t = payload as AppleTransactionPayload;
  if (!t.transactionId || !t.bundleId || !t.productId) {
    throw new IapVerificationError("malformed_payload");
  }
  if (!ALLOWED_BUNDLE_IDS.includes(t.bundleId)) {
    throw new IapVerificationError("bundle_mismatch", t.bundleId);
  }

  // Validity is checked at SIGNING time, not now. Checking against now() would
  // reject genuine old receipts every time Apple rotates its leaf.
  const signed = new Date(t.signedDate);
  if (Number.isFinite(signed.getTime())) {
    if (signed < leaf.notBefore || signed > leaf.notAfter) {
      throw new IapVerificationError("cert_not_valid_at_signing");
    }
  }

  return t;
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
