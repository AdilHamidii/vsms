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

/// Every country we can sell without regulatory paperwork is +1 — see the
/// sellable-catalogue sweep in `.claude/rules/providers.md`. Kept as a set
/// rather than `=== "US"` so PR/VI are a one-line addition and a non-NANP
/// country FAILS the guard instead of silently defaulting to +1.
export const NANP = new Set(["US", "CA", "PR", "VI"]);

/**
 * Coerce a dialled or addressed string to E.164, or null when it cannot be
 * trusted.
 *
 * Accepts an already-qualified `+…` number, an 11-digit NANP string beginning
 * with 1, and a bare 10-digit NANP national number — the last being what a
 * keypad produces and what shipped clients send.
 *
 * ⚠️ Anything else is REFUSED rather than guessed at. Dialling or texting the
 * wrong country is materially worse than refusing to act: the user is charged
 * allowance, a stranger may be contacted, and the failure is silent. This is
 * the same rule as `_shared/emailStatus.ts` — never encode a guess about a
 * vocabulary you do not control.
 */
export function toE164(raw: string): string | null {
  const trimmed = raw.trim();
  const digits = trimmed.replace(/\D/g, "");
  if (!digits) return null;

  if (trimmed.startsWith("+")) {
    // Already qualified. E.164 allows at most 15 digits and a country code
    // never starts with 0.
    return /^[1-9]\d{7,14}$/.test(digits) ? "+" + digits : null;
  }
  // NANP: the area code and the exchange code both start 2-9. That is what
  // separates a real 10-digit national number from a fragment or an extension.
  if (/^[2-9]\d{2}[2-9]\d{6}$/.test(digits)) return "+1" + digits;
  if (/^1[2-9]\d{2}[2-9]\d{6}$/.test(digits)) return "+" + digits;
  return null;
}

/**
 * Whether a bare national number may be assumed NANP for this line.
 *
 * `toE164` defaults an unqualified 10-digit string to +1, which is correct
 * while the catalogue is US/CA only. The moment a non-NANP line is sold that
 * default becomes a silent misdial to the wrong country, so callers assert it
 * rather than letting the assumption rot.
 */
export function assumesNanp(countryCode: string | null | undefined): boolean {
  const cc = String(countryCode ?? "").toUpperCase();
  // An unknown country is permitted: `country_code` is nullable on
  // `phone_lines`, and refusing on absence would break every line whose column
  // was never populated. It is the KNOWN non-NANP case that must fail.
  return !cc || NANP.has(cc);
}
