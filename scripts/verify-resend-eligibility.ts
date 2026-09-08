// Offline assertions for fivesim.supportsResend(). No network, no key.
//
//   deno run --allow-read scripts/verify-resend-eligibility.ts
//
// The pool list is 5SIM'S PUBLISHED CLAIM, not our measurement — these
// assertions prove we transcribed it faithfully and fail closed, nothing more.
// Whether a second SMS actually arrives on these pools is settled only by a
// `resend_promoted` line in the poller logs.
import { supportsResend } from "../supabase/functions/_shared/fivesim.ts";

let pass = 0, fail = 0;
function check(name: string, got: boolean, want: boolean) {
  if (got === want) { pass++; return; }
  fail++;
  console.error(`FAIL ${name}: got ${got}, want ${want}`);
}

// Unconditional pools from 5sim's published list.
for (
  const op of [
    "virtual2",
    "virtual21",
    "virtual26",
    "virtual34",
    "virtual36",
    "virtual38",
    "virtual40",
    "virtual47",
    "virtual49",
    "virtual51",
    "virtual52",
    "virtual53",
    "virtual54",
    "virtual58",
  ]
) {
  check(`${op}/usa`, supportsResend("usa", op), true);
  check(`${op}/england`, supportsResend("england", op), true);
}

// virtual8 is USA + Canada only; virtual12 is Canada only.
check("virtual8/usa", supportsResend("usa", "virtual8"), true);
check("virtual8/canada", supportsResend("canada", "virtual8"), true);
check("virtual8/england", supportsResend("england", "virtual8"), false);
check("virtual12/canada", supportsResend("canada", "virtual12"), true);
check("virtual12/usa", supportsResend("usa", "virtual12"), false);

// Pools carrying real traffic that are NOT on the list. virtual63 is the one
// that matters most: it is the second-biggest source of delivered codes and
// sits alongside virtual51 on whatnot/us, so getting it wrong would hold the
// wrong half of that route open.
for (
  const op of [
    "virtual63",
    "virtual66",
    "virtual60",
    "virtual59",
    "virtual61",
    "virtual65",
    "virtual4",
    "virtual28",
  ]
) {
  check(`${op}/usa is ineligible`, supportsResend("usa", op), false);
}

// Fails closed. `operator_used` is nullable and null means "not recorded",
// which is NOT the same as eligible.
check("null operator", supportsResend("usa", null), false);
check("undefined operator", supportsResend("usa", undefined), false);
check("empty operator", supportsResend("usa", ""), false);
check("null country", supportsResend(null, "virtual51"), false);
check("unpinned", supportsResend("usa", "any"), false);
check("unknown pool", supportsResend("usa", "virtual999"), false);

// Case and whitespace are provider data, not user data, but normalise anyway.
check("uppercase", supportsResend("USA", "VIRTUAL51"), true);
check("padded", supportsResend(" usa ", " virtual51 "), true);

console.log(`${pass} passed, ${fail} failed`);
if (fail > 0) Deno.exit(1);
