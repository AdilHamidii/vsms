// Turning what a user typed into a number a provider will accept.
//
// 🔴 THE BUG THIS EXISTS TO KILL. The dialer sent the raw keypad string, so a
// US number reached `begin-line-call` as "4054003316" — no `+`, no country
// code — and the guard there (`/^\+?[1-9]\d{7,14}$/`) ACCEPTED it, because a
// bare 10-digit national number matches that pattern perfectly. We then
// reserved allowance and dialled something Telnyx could never place.
//
// Observed live 2026-08-17: a subscriber dialled "4054003316", watched it fail,
// redialled "14054003316" (still not E.164), failed again, and cancelled a
// $9.99 subscription ten minutes after paying for it.
//
// `send-line-message` had it WORSE — no number validation of any kind, only an
// emergency-number check. Replies happened to work because the peer came back
// from an inbound webhook already in E.164; a user typing a new recipient did
// not.
//
// Both now share this one definition, because the failure mode of having two is
// that they disagree and the message and the call go to different places.

/// The +1 numbering plan. Every country Telnyx sells us WITHOUT end-user
/// regulatory documents is in here — see the sellable-catalogue sweep in
/// `.claude/rules/providers.md`. Kept as a set rather than `=== "US"` so PR/VI
/// are a one-line addition and a non-NANP country FAILS the guard instead of
/// silently defaulting to +1.
///
/// ⚠️ It is no longer the same thing as "the countries we sell". Voice-only
/// non-NANP countries become sellable the moment the catalog says so, so this
/// set means exactly one thing now: **whose bare national numbers may be
/// defaulted to +1**.
export const NANP = new Set(["US", "CA", "PR", "VI"]);

/**
 * Coerce a dialled or addressed string to E.164, or null when it cannot be
 * trusted.
 *
 * Accepts an already-qualified `+…` number always; and a bare 10-digit or
 * 11-digit NANP national number ONLY when the line placing it is itself NANP
 * (or unknown) — the last being what a keypad produces and what shipped
 * clients send.
 *
 * 🔴 `lineCountry` IS WHAT STOPS THE +1 DEFAULT ROTTING INTO A MISDIAL. A GB
 * line whose owner types their own national number `07911123456` must get
 * `null`, not a plausible-looking `+1…` addressed at a stranger in North
 * America. We cannot infer GB from the digits: `+44` is not in them, and
 * guessing a country from a national format is exactly the class of guess this
 * file exists to refuse. An ABSENT `lineCountry` still defaults, because
 * `phone_lines.country_code` is nullable and every line predating the column
 * would otherwise stop working.
 *
 * ⚠️ Anything else is REFUSED rather than guessed at. Dialling or texting the
 * wrong country is materially worse than refusing to act: the user is charged
 * allowance, a stranger may be contacted, and the failure is silent. This is
 * the same rule as `_shared/emailStatus.ts` — never encode a guess about a
 * vocabulary you do not control.
 */
export function toE164(
  raw: string,
  opts?: { lineCountry?: string | null },
): string | null {
  const trimmed = raw.trim();
  const digits = trimmed.replace(/\D/g, "");
  if (!digits) return null;

  if (trimmed.startsWith("+")) {
    // Already qualified. E.164 allows at most 15 digits and a country code
    // never starts with 0. Unaffected by the line's country — the caller said
    // exactly what they meant.
    return /^[1-9]\d{7,14}$/.test(digits) ? "+" + digits : null;
  }

  // Bare national input may only be defaulted for a line that is itself NANP.
  if (!assumesNanp(opts?.lineCountry)) return null;

  // NANP: the area code and the exchange code both start 2-9. That is what
  // separates a real 10-digit national number from a fragment or an extension.
  if (/^[2-9]\d{2}[2-9]\d{6}$/.test(digits)) return "+1" + digits;
  if (/^1[2-9]\d{2}[2-9]\d{6}$/.test(digits)) return "+" + digits;
  return null;
}

/**
 * Whether a bare national number may be DEFAULTED to +1 for this line.
 *
 * ⚠️ Its role is narrower than it used to be, and the difference matters. This
 * is not "may a line exist in this country" — voice-only non-NANP countries are
 * sellable now, gated by `line_country_catalog`, not by this. It answers only
 * "may an unqualified input be assumed North American", which `toE164` now asks
 * internally as well. Callers keep asserting it so they can log WHY they
 * refused, and so a shipped client sending a bare number gets a specific error
 * rather than a bare `bad_number`.
 */
export function assumesNanp(countryCode: string | null | undefined): boolean {
  const cc = String(countryCode ?? "").toUpperCase();
  // An unknown country is permitted: `country_code` is nullable on
  // `phone_lines`, and refusing on absence would break every line whose column
  // was never populated. It is the KNOWN non-NANP case that must fail.
  return !cc || NANP.has(cc);
}
