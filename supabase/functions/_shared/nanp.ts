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

/**
 * Can a line in `lineCc` actually deliver a text to `recipient`?
 *
 * 🔴 MEASURED, NOT ASSUMED. Telnyx reports our Canadian longcode as
 * `domestic_two_way: true` with `international_outbound: false`, and every send
 * to a US number is rejected with `40010: The sending number is not
 * 10DLC-registered but is required to be by the carrier`. Lifetime outbound is
 * **1 sent against 6 failed**; inbound is 3 of 3.
 *
 * ⚠️ `.claude/rules/providers.md` still records a CA→US send DELIVERING on
 * 2026-08-05 with no brand and no campaign — the measurement the whole
 * "sell Canadian numbers, no paperwork" launch was built on. It is no longer
 * true in production; either carriers tightened enforcement or that single test
 * slipped through ahead of it. Trust the 40010s, not the note.
 *
 * ⚠️ THIS IS TEMPORARY AND SHOULD BE DELETED, not tuned. It encodes a
 * registration gap, not a fact about telephony. When toll-free verification or
 * 10DLC clears, remove the check rather than adding exceptions to it.
 */
export function canSendTo(
  lineCc: string | null | undefined, recipient: string,
): { ok: true } | { ok: false; reason: "cross_border"; from: string; to: string } {
  const from = (lineCc ?? "").toUpperCase();
  const to = nanpCountry(recipient);
  // Unknown on either side passes: this guard exists to stop a KNOWN failure,
  // and inventing refusals out of missing data is how a catalogue quietly loses
  // destinations it could actually serve.
  if (!from || !to) return { ok: true };
  if (from === to) return { ok: true };
  return { ok: false, reason: "cross_border", from, to };
}
