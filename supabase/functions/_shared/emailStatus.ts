// Vendor email status -> OUR status. The single mapping point, shared by
// check-email-order and the poller so the two can never disagree.
//
// ── Why this exists instead of a Postgres enum of the vendor's values ───────
// HeroSMS's email status vocabulary is undocumented and not discoverable: no
// OpenAPI spec is served at any conventional path, and none of the 50 JS chunks
// behind its docs SPA contains the enum. Probing live on 2026-07-30 produced
// only `WAIT` (fresh) and `CANCEL` (after a successful DELETE). The value that
// means "a code arrived" has never been observed.
//
// Encoding a guess into a DB enum is the mistake that already cost money here:
// `create-esim-order` wrote 'canceled', a member of `order_status` but NOT of
// `esim_status`; PostgREST rejected it with 22P02, the code discarded the
// error, and every failed eSIM purchase silently kept the user's money.
//
// So an unknown vendor string maps to `waiting` and logs loudly. That is the
// safe direction: it keeps polling a live activation rather than closing one
// that may still deliver, and the raw string is persisted in
// `email_orders.provider_status` for diagnosis.

import type { EmailStatus } from "./providers.ts";

/** How long we keep an activation open before closing and refunding.
 *
 *  UNCONFIRMED against the vendor: the probe above sat at WAIT for 15+ minutes
 *  without flipping, so the real timeout is at least that. 20 minutes matches
 *  the window HeroSMS advertises for SMS activations and is the conservative
 *  choice — closing early forfeits our wholesale and, worse, discards a code
 *  that was about to land. Tighten only against an observed vendor timeout. */
export const EMAIL_WINDOW_SECONDS = 20 * 60;

/** Vendor strings seen live. Anything outside this set is logged, not assumed. */
const KNOWN: Record<string, EmailStatus> = {
  WAIT: "waiting",
  CANCEL: "canceled",
};

export interface MappedStatus {
  status: EmailStatus;
  /** Non-null only when the provider has actually handed us a code. */
  code: string | null;
}

/** Resolve one activation to our vocabulary.
 *
 *  **`value` is the authority for "a code arrived", not the status string.**
 *  This is the same rule the SMS side had to learn the hard way: a rescued late
 *  code lives on a `canceled` row, so five SQL functions that keyed on
 *  `status = 'received'` scored a delivered code as a failure. Here it also
 *  means we do not need to know the vendor's success status at all — if there
 *  is a value, there is a code, whatever they call the state.
 *
 *  Order matters: a code found on an otherwise-cancelled activation still wins,
 *  because the user has the thing they paid for. */
export function mapProviderStatus(
  providerStatus: string,
  value: string | null,
  createdAt: string,
  windowSeconds: number = EMAIL_WINDOW_SECONDS,
): MappedStatus {
  const code = value != null && String(value).trim() !== "" ? String(value).trim() : null;
  if (code) return { status: "received", code };

  const raw = (providerStatus ?? "").trim().toUpperCase();
  const known = KNOWN[raw];
  if (known && known !== "waiting") return { status: known, code: null };

  if (!known && raw) {
    // Loud on purpose. A new vendor status is a fact about the product we do
    // not yet have, and it should reach the logs the first time it happens
    // rather than being silently absorbed.
    console.error(
      `emailStatus: UNKNOWN provider status ${JSON.stringify(raw)} — treating as waiting. ` +
      `Add it to KNOWN once its meaning is confirmed.`,
    );
  }

  // Local expiry. The vendor's own timeout is unobserved, so this is what
  // actually closes an abandoned activation and releases the credit.
  const ageSeconds = (Date.now() - new Date(createdAt).getTime()) / 1000;
  if (Number.isFinite(ageSeconds) && ageSeconds > windowSeconds) {
    return { status: "expired", code: null };
  }
  return { status: "waiting", code: null };
}
