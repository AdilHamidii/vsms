# Fix wave B — seven backend findings

Worktree `bugfix-ux-pass`. **Nothing deployed.** Two migrations applied to the
live DB and recorded; every edge-function change is committed only.

All seven findings were real. None was refuted.

---

## 1. Watchdog red since 2026-08-17 — `smspva_retired` never written (HIGH, live)

**Confirmed independently.** `select key from app_config where key='smspva_retired'`
returned nothing. `app_config.watchdog` read
`failing: [sync-smspva-operators, sync-smspva-conversions, 5sim-float]`, the two
SMSPVA cursors frozen at 2026-08-17 04:40 and 07:49 — the timestamps at which
`20260817100000_retire_smspva.sql` unscheduled their crons.

**Changed:** `20260820100000_smspva_retired_flag.sql` — inserts the key, with a
header naming the failure class (*a guard reading a key nobody writes fails open
and silent*) and the rule that a retirement must write its flag in the same
migration that unschedules its jobs. The key is deliberately **not** added to the
`app_config_read` whitelist.

**Verified:** applied, recorded, and read back by name. `select public.run_watchdog()`
then returned `failing: [5sim-float]` alone — both false positives cleared, the
genuine float page preserved.

**Note on the winback side-effect:** `claimSafe` requires `failing === 0`, and
`5sim-float` is a *genuine* failure (5sim balance $3.62, ~3.8 days of runway).
So the stranded-credit cohort is still gated — but now correctly: it is gated on
a real inability to fill orders, which is exactly what that predicate is for.
Topping up 5sim opens it. The structural suppression is gone.

---

## 2. Every call billed its full 120 s reservation; missed international calls charged in full (HIGH, live)

**Confirmed.** `telnyx_cdr_heartbeat` reads `{records: 0, settled: 0, pages: 4}`
— `sync-telnyx-cdr` has never matched a record. All five settled `line_calls`
rows closed `hangup_cause = 'no_cdr'` and carry no `provider_call_session_id`.
The premise `20260818140000` reasoned from ("this backstop is rare") is false;
it is the only settlement path that has ever run.

**Changed:** `20260820110000_never_bill_an_unconnected_call.sql`, rewriting
`settle_stale_calls` only.

- No `provider_call_session_id` **and** no `provider_call_leg_id` ⇒ bill 0
  seconds (`hangup_cause = 'no_cdr_unreached'`). Fixes both halves at once:
  international credits are fully refunded, and the domestic branch's
  `settle_line_allowance(line,'voice',0,120)` returns the whole reservation.
- Either id present ⇒ full reservation as before (`no_cdr_full`).

**A design decision I made against the obvious reading of the finding, and the
reason:** the finding located the bug in `settle_call_claim` charging on
`p_status = 'missed'`. Guarding *there* on status would reopen the exploit
`20260818140000` closed — `status` is written straight from `report-line-call`'s
request body, so "bill 0 when status is canceled" is precisely *set one string,
talk for an hour, pay nothing*. **`settle_call_claim` is therefore left
byte-identical**, and the migration header records why so it is not "fixed"
later. The gate lives in the caller, is on provider leg identifiers, and is an
on/off test only — never an input to the amount.

I am explicit in the header that this evidence is **weak** (the ids are
client-written too) and that the full-reservation bill was never a real defense
anyway: ~2 credits (~$0.80) against ~$36 of wholesale on a 10-minute premium
call. The exploit's actual bound is Telnyx's per-line `daily_spend_limit`, which
is already in place. **The real repair is making `sync-telnyx-cdr` match a
record** — flagged in the header and in CLAUDE.md as the open defect.

**Verified behaviourally**, not structurally — `scripts/verify-call-settlement.sql`,
3 assertions inside a rolled-back transaction:

1. unreached international call → 0 credits charged, full 2-credit block refunded,
   `no_cdr_unreached`
2. **reached** international call with client-reported `status: 'canceled'` →
   still billed the full block, `no_cdr_full` (this is the regression test for
   the exploit)
3. unreached domestic call → 0 allowance seconds consumed

Negative control run: flipping assertion 1a to the old expectation produced
`FAIL 1a: unreached intl call charged 0 credits`, proving the assertion reads
live state rather than passing vacuously.

---

## 3. `cancel-order` dropped the error on the code-rescue write (HIGH, live)

**Confirmed** at `cancel-order/index.ts:230`.

**Changed:** destructured `rescueErr`; on error, logs
`alert: cancel_order_rescue_write_failed` and returns **500 `update_failed`**
rather than falling through to the cancel. That leaves the row `waiting`, so the
code stays recoverable via `poll-active-orders` and `check-order` — the user
retries a cancel at worst, instead of being refunded seconds before the code
they paid for. Matches `check-order:76`, which writes the identical statement
and has always destructured it.

`update_failed` added to `VirtualSIM/Networking/APIError.swift` (same commit),
worded for both emitters: order still running, credits unchanged, retry.

**Verified:** `deno check` clean; `xcodebuild` **BUILD SUCCEEDED**.

---

## 4. `poll-active-orders` — three unchecked writes in the late-code sweep (HIGH, live)

**Confirmed**, and there were **three**, not two — the `!o.smspva_id` branch has
the same unchecked clear.

**Changed:**
- Rescue write (`:561`): destructured; on error alerts
  `late_code_rescue_write_failed` and continues **without** clearing
  `late_watch_until`, so the next run re-polls and retries.
- Post-`markDead` clear (`:550`): **reversed to clear-then-release.**
  `late_watch_until <= now()` stays true forever, so a failed clear after
  markDead re-cancels and re-bans an already-dead number every minute for the
  life of the row, permanently holding one of the sweep's 50 slots. Clearing
  first makes the failure bounded — one forfeited reclaim (~$3.50 cap, and the
  provider expires the number anyway) instead of an unbounded minutely loop.
  Both errors checked.
- `!o.smspva_id` clear: checked and alerted.

**Verified:** `deno check` reports the same **5 pre-existing** `TS2352`
join-typing errors before and after my change (measured by stashing), and no new
ones.

---

## 5. `apple-notifications` — unchecked `processed_at` write (HIGH, live)

**Confirmed** at `:117`.

**Changed:** destructured; on failure logs `assn_mark_processed_failed` and
returns **non-2xx**. Returning 200 with the flag unset meant every Apple retry
re-ran `process()` from the top forever, silently — defeating the flag entirely.
Non-2xx costs one extra idempotent reprocess and *ends* the loop. The catch
branch's `process_error` write is checked too, so a blank `process_error` beside
a failing notification can no longer be misread as success.

No new error literal (reuses `process_failed`; this endpoint answers Apple, not
the iOS client). **Verified:** `deno check` clean.

---

## 6. `check-esim-usage` — dropped error on the refund RPC (latent)

**Confirmed** at `:180`.

**Changed:** destructured `closeErr`; alerts `esim_refund_claim_failed` and
**pages** via the existing `pageProviderClosed` with an explicit "REFUND CLAIM
FAILED — credits NOT returned".

**Deliberately does not return 500:** this endpoint reports usage and a 500
blanks the detail screen. That screen polls every 8 s and the row is still
`status = 'provisioning'`, so the next poll retries the claim and a transient
failure self-heals. **Verified:** `deno check` clean.

---

## 7. `sync-esim-plans` — delist sweep reported success on failure (latent)

**Confirmed** at `:249`.

**Changed:** destructured `hideErr`; returns **500 `hide_failed`** with the
counts, matching the fail-loud upsert loop directly above it. Previously a failed
bulk hide rendered `hidden: 0` — byte-identical to "nothing needed hiding" —
while delisted plans stayed on sale.

`hide_failed` is **not** added to `APIError.swift`: this function is cron-gated
and unreachable from the client, matching the existing unmapped `upsert_failed`
beside it. **Verified:** `deno check` clean.

---

## Deferred, as instructed

The partial-unique refund index for `line_id` and `debit_credit_lines`' missing
wallet row were left untouched.

## Docs

`CLAUDE.md` updated in the same commits: the call-billing invariant and the
"gate is not on status" warning replace the stale *"settles on the CLIENT's
reported duration"* paragraph, and the never-written-flag failure is added to
the gotchas list.

## Not fixed — flagged instead

**`sync-telnyx-cdr` has never matched a detail record.** Everything in finding 2
is a stand-in for billing truth we are not reading. Fixing it needs a real call
plus live API access, so it is recorded as the open defect in the migration
header and in CLAUDE.md rather than guessed at — the detail-records query has
already been wrong twice for exactly that reason.

**Deploy list for these changes:** `cancel-order`, `poll-active-orders`,
`apple-notifications`, `check-esim-usage`, `sync-esim-plans`. Both migrations are
already live.
