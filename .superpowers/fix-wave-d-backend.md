# Fix wave D — backend corrections

## Finding 1 — client-controlled zero-billing gate (CRITICAL)
Reverted. `settle_stale_calls` no longer gates on `provider_call_session_id` /
`provider_call_leg_id`: both are written only by `attach_line_call_session` from
`report-line-call`'s request body, so the gate was 100% client-controlled and made
staying silent the winning move. Restored `20260818140000` behaviour — bill the
server-set reservation, `hangup_cause = 'no_cdr_full'`. `settle_call_claim`
untouched. The settlement site now names BOTH rejected gates (`status`, session-id)
and states that the only correct duration source is the provider detail record,
so the backstop deliberately over-bills until `sync-telnyx-cdr` matches one.

Migration `20260820120000_no_client_settable_gate_on_call_billing` — applied,
recorded, selected back by name. Live `prosrc` byte-matches the committed file;
`proacl = {postgres=X/postgres,service_role=X/postgres}`.

CLAUDE.md: new block under "The client is never authoritative about money"
recording that `provider_call_session_id`/`leg_id` are client-supplied despite
the names and must never be treated as provider evidence.

## Finding 2 — late-watch release retry (RISKY)
`orders.late_release_attempts` (migration `20260820130000_late_release_attempts`,
applied + recorded + verified: `integer not null default 0`).
`poll-active-orders` now increments the counter BEFORE calling `markDead()`, then
releases, then clears `late_watch_until`. A transient provider failure is retried
on the next minutely run; the counter is monotone and written pre-provider, so
markDead() calls per order are capped at `MAX_LATE_RELEASE_ATTEMPTS = 5` (~5 min).
At the cap the row gives up once and for all: flag cleared, row leaves the sweep,
one number's reclaimable wholesale (~$3.50 worst case) forfeited — stated in the
comment. A failing counter-write skips the provider entirely, so the unbounded
re-cancel-and-ban loop stays closed.

`deno check` on `poll-active-orders`: identical error set to HEAD (1×TS2304
`EdgeRuntime`, 5×TS2352 pre-existing `service` casts) — no new errors.

## Not deployed
Nothing deployed, per instruction. `poll-active-orders` needs a deploy for
Finding 2 to take effect; Finding 1 is SQL and is already live.
