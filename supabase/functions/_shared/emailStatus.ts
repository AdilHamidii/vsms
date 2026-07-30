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

/** Our local backstop window — deliberately LONGER than the vendor's.
 *
 *  MEASURED 2026-07-30 by holding one activation to its natural end: still WAIT
 *  at 20m22s, CANCEL at 21m22s. So the vendor's own window is ~20–21 minutes,
 *  and it **auto-refunds** — the account balance returned to exactly its
 *  pre-purchase figure with no action from us.
 *
 *  Ours sits at 22 minutes so the vendor's terminal state is what we normally
 *  observe, and this only fires when we cannot reach them at all. Setting it
 *  SHORTER would race a provider that is still holding a live mailbox, and
 *  closing early discards a code that was about to land — the expensive
 *  direction, since receiving a code is the retention mechanic. */
export const EMAIL_WINDOW_SECONDS = 22 * 60;

/** Vendor strings seen live. Anything outside this set is logged, not assumed.
 *
 *  `CANCEL` is deliberately absent: it is OVERLOADED. The vendor returns it for
 *  a user-initiated DELETE *and* for its own ~20-minute timeout, with nothing
 *  in the payload distinguishing them. Only the caller knows which happened, so
 *  it is resolved in `mapProviderStatus` from `weCancelled` instead of here. */
const KNOWN: Record<string, EmailStatus> = {
  WAIT: "waiting",
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
  /** Did WE issue a DELETE for this activation? Resolves the overloaded
   *  `CANCEL` — see below. Defaults false, which is correct for every code path
   *  that merely polls. */
  weCancelled = false,
): MappedStatus {
  const code = value != null && String(value).trim() !== "" ? String(value).trim() : null;
  if (code) return { status: "received", code };

  const raw = (providerStatus ?? "").trim().toUpperCase();

  // CANCEL means "this activation is over" and NOTHING about who ended it. The
  // vendor uses it for both a user DELETE and its own ~20-minute timeout, with
  // nothing in the payload to tell them apart.
  //
  // Defaulting it to 'canceled' would tell a user they cancelled an order that
  // simply timed out — a false statement on their history row, and the same
  // class of error as showing "Expired" with no refund line. So the caller's
  // knowledge decides, and merely observing CANCEL means it expired.
  if (raw === "CANCEL") {
    return { status: weCancelled ? "canceled" : "expired", code: null };
  }

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
