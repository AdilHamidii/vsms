// Behavioural check for `_shared/phone.ts`.
//
// This is the normalizer that decides which number a call or a text actually
// goes to, so a mistake here is a call to a stranger or a silently-burned
// allowance. `deno run scripts/verify-phone-e164.ts` — no network, no auth.
//
// The two live inputs from 2026-08-17 are pinned as cases: "4054003316" is what
// the dialer sent, and "14054003316" is what the subscriber typed on the retry.

import { toE164, assumesNanp, NANP } from "../supabase/functions/_shared/phone.ts";

let pass = 0;
const fail: string[] = [];

function eq(label: string, got: unknown, want: unknown) {
  if (got === want) { pass++; return; }
  fail.push(`${label}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
}

// ── The two numbers that actually failed in production ────────────────────
eq("live: bare NANP national", toE164("4054003316"), "+14054003316");
eq("live: user retry with 1", toE164("14054003316"), "+14054003316");
eq("live: the other number", toE164("4058379610"), "+14058379610");

// ── Already-qualified input is preserved ──────────────────────────────────
eq("already E.164", toE164("+14054003316"), "+14054003316");
eq("E.164 non-NANP", toE164("+447911123456"), "+447911123456");
eq("E.164 with spacing", toE164("+1 (405) 400-3316"), "+14054003316");

// ── Formatting is tolerated on national input ─────────────────────────────
eq("national formatted", toE164("(405) 400-3316"), "+14054003316");
eq("national dotted", toE164("405.400.3316"), "+14054003316");
eq("leading/trailing space", toE164("  4054003316  "), "+14054003316");

// ── Refusals: better no call than the wrong call ──────────────────────────
eq("empty", toE164(""), null);
eq("letters only", toE164("abc"), null);
eq("too short", toE164("12345"), null);
// N11 codes and numbers whose area code starts 0/1 are not dialable NANP.
eq("area code starts 1", toE164("1054003316"), null);
eq("area code starts 0", toE164("0054003316"), null);
eq("exchange starts 1", toE164("4051003316"), null);
eq("9 digits", toE164("405400331"), null);
// 11 digits not starting with 1 is not NANP and has no country code we can
// infer — refusing is the whole point.
eq("11 digits not NANP", toE164("44054003316"), null);
eq("E.164 country code 0", toE164("+05540033160"), null);
eq("E.164 too long", toE164("+1234567890123456"), null);

// ── The NANP assumption guard ─────────────────────────────────────────────
eq("US assumes NANP", assumesNanp("US"), true);
eq("CA assumes NANP", assumesNanp("CA"), true);
eq("lowercase ca", assumesNanp("ca"), true);
eq("PR assumes NANP", assumesNanp("PR"), true);
// Nullable column: absent must NOT break existing lines.
eq("null country permitted", assumesNanp(null), true);
eq("empty country permitted", assumesNanp(""), true);
// The case that must fail, so the +1 default cannot rot into a misdial.
eq("GB refuses NANP", assumesNanp("GB"), false);
eq("NL refuses NANP", assumesNanp("NL"), false);
eq("NANP set size", NANP.size, 4);

if (fail.length) {
  console.error(`FAIL ${fail.length} of ${pass + fail.length}`);
  for (const f of fail) console.error("  ✗ " + f);
  Deno.exit(1);
}
console.log(`PASS ${pass}/${pass} phone normalization assertions`);
