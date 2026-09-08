// Which NANP country a +1 number belongs to, and whether a line may text it.
//
// Separate from `phone.ts` on purpose: that file NORMALISES a number, this one
// decides WHERE it is and whether we can reach it. Two different jobs, and the
// second one is policy that will change the moment a registration clears.

/**
 * 🔴 YOU CANNOT TELL CANADA FROM THE UNITED STATES BY THE COUNTRY CODE.
 * Both are +1; only the three-digit area code (NPA) separates them.
 *
 * This is the full set of Canadian NPAs. It changes when the numbering
 * administrator opens a new area code — roughly once a year, always announced
 * well in advance — so a stale entry means one new Canadian area code is read
 * as American and we REFUSE to text it. That fails closed, which is the safe
 * direction: refusing costs the user nothing, while attempting spends a segment
 * of their allowance to buy a guaranteed failure.
 */
const CA_NPA = new Set([
  "204", "226", "236", "249", "250", "263", "289", "306", "343", "354",
  "365", "367", "368", "382", "387", "403", "416", "418", "428", "431",
  "437", "438", "450", "468", "474", "506", "514", "519", "548", "579",
  "581", "584", "587", "600", "604", "613", "639", "647", "672", "683",
  "705", "709", "742", "753", "778", "780", "782", "807", "819", "825",
  "867", "873", "879", "902", "905",
]);

/** "US" | "CA" for a +1 number, null for anything else. */
export function nanpCountry(e164: string): "US" | "CA" | null {
  const d = e164.replace(/\D/g, "");
  if (d.length !== 11 || !d.startsWith("1")) return null;
  return CA_NPA.has(d.slice(1, 4)) ? "CA" : "US";
}

/** The NANP countries that share +1. Mirrors `phone.ts`'s `NANP` — kept as its
 *  own constant because that file answers "may I default a bare number to +1"
 *  and this one answers "may this line text that number". Two questions, and
 *  only this one is policy. */
const NANP_CC = new Set(["US", "CA", "PR", "VI"]);

/** Is this a +1 number at all? PR (787/939) and VI (340) resolve to "US"
 *  through `nanpCountry`, which is fine as a LABEL and wrong as a country — so
 *  the bloc membership test is deliberately separate from the label. */
export function isNanpNumber(e164: string): boolean {
  const d = e164.replace(/\D/g, "");
  return d.length === 11 && d.startsWith("1");
}

/**
 * Can a line in `lineCc` actually deliver a text to `recipient`?
 *
 * 🔴 POLICY, 2026-09-08: **NANP → NANP is ALLOWED. Everything else is refused.**
 *
 * Why the blanket cross-border refusal was wrong:
 *
 * - It was written on 2026-08-18 from FOUR sends on one evening, every one of
 *   them from a CANADIAN number to a US number, every one `40010` (the sending
 *   number is not attached to a 10DLC campaign). At the time Canada was the
 *   only country we sold, so "cross-border fails" and "sends from a Canadian
 *   longcode fail" were the same observation wearing the more general name.
 * - On 2026-09-08 a send from a US number we own to a Canadian number we own
 *   was **delivered**, with no error, and the inbound webhook landed it in the
 *   recipient's app. The fleet is now 7 US + 5 CA numbers and no US number had
 *   ever attempted a send.
 *
 * ⚠️ **THAT SEND WAS ON-NET — both endpoints are numbers on our own Telnyx
 * account — so it may never have crossed a real carrier's spam or registration
 * filter, and no 10DLC campaign is registered on any number we own
 * (`messaging_campaign_id` is null on all 12, read from
 * `app_config.telnyx_messaging_probe`, 2026-09-08). OUTBOUND SMS TO A REAL
 * HANDSET IS NOT PROVEN.** Nothing built on this may claim that it works. A
 * carrier rejection arrives asynchronously as a delivery receipt, so the
 * failure is surfaced from `line_messages.error_code` in the thread rather
 * than predicted here.
 *
 * 🔴 **NON-NANP DESTINATIONS STAY REFUSED, and that is a capability rather
 * than a policy guess:** `features.sms.international_outbound` reads **false**
 * on all 12 numbers we own (same probe, same day), and the messaging profile's
 * `whitelisted_destinations` is `["CA","GB","US"]`. Attempting one spends a
 * segment of a hard-stop allowance to buy a guaranteed failure — the same
 * shape as `create-order`'s pre-charge provider-balance guard.
 *
 * ⚠️ Still temporary in the sense the old note meant: re-read the probe before
 * widening this, and never widen it on the strength of a single successful
 * send — that is exactly the mistake the 2026-08-05 "Canada needs no
 * paperwork" measurement made in the other direction.
 */
export function canSendTo(
  lineCc: string | null | undefined, recipient: string,
): { ok: true }
  | { ok: false; reason: "cross_border" | "international"; from: string; to: string } {
  const from = (lineCc ?? "").toUpperCase();
  const to = nanpCountry(recipient);

  // An unknown SENDER passes. This guard exists to stop a known failure, and
  // inventing refusals out of missing data is how a catalogue quietly loses
  // destinations it could serve.
  if (!from) return { ok: true };

  if (NANP_CC.has(from)) {
    // Inside the plan: US ⇄ CA ⇄ PR ⇄ VI, in any combination. One measured
    // delivery (US → CA, 2026-09-08) plus `domestic_two_way: true` on every
    // number we own. PR and VI ride here because they ARE +1 US area codes.
    if (isNanpNumber(recipient)) return { ok: true };
    // Outside it, the number's own capability says no.
    return { ok: false, reason: "international", from, to: "INTL" };
  }

  // A sender we do not classify (no non-NANP line exists today) keeps the old
  // permissive behaviour toward its own region rather than being grounded by a
  // rule written for someone else's numbering plan — but a NANP destination
  // from there is an international send its own number almost certainly cannot
  // make either.
  if (!to) return { ok: true };
  return { ok: false, reason: "cross_border", from, to };
}
