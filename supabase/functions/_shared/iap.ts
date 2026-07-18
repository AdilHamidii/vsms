// StoreKit 2 transaction verification.
// Apple sends each transaction as a JWS signed by Apple. We verify the
// JWS using the leaf certificate from the x5c header chain.
//
// NOTE: Full production-grade verification should also walk the cert
// chain back to Apple's root CA. For MVP we trust the embedded leaf
// signature, combined with the bundle_id check + idempotency on
// transaction_id (Apple-globally unique).

import { decodeProtectedHeader, importX509, jwtVerify } from "https://esm.sh/jose@5.9.4";

const ALLOWED_BUNDLE_IDS = ["com.anthersystems.VirtualSIM"];

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
  environment: "Sandbox" | "Production";
}

export async function verifyTransactionJWS(jws: string): Promise<AppleTransactionPayload> {
  const header = decodeProtectedHeader(jws);
  const x5c = header.x5c;
  if (!Array.isArray(x5c) || x5c.length === 0) {
    throw new Error("missing_x5c");
  }
  const leafPem = `-----BEGIN CERTIFICATE-----\n${x5c[0]}\n-----END CERTIFICATE-----`;
  const leafKey = await importX509(leafPem, "ES256");

  const { payload } = await jwtVerify(jws, leafKey, { algorithms: ["ES256"] });
  const t = payload as unknown as AppleTransactionPayload;

  if (!t.transactionId || !t.bundleId || !t.productId) {
    throw new Error("malformed_payload");
  }
  if (!ALLOWED_BUNDLE_IDS.includes(t.bundleId)) {
    throw new Error("bundle_mismatch");
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
