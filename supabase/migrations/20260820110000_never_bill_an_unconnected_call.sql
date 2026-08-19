-- ─────────────────────────────────────────────────────────────────────────────
-- A call that never reached the provider must cost the user nothing —
-- credits OR minutes
-- ─────────────────────────────────────────────────────────────────────────────
--
-- 🔴 TWO CORRECT CHANGES COMPOSED INTO A BUG NEITHER OF THEM INTENDED.
--
-- `20260817170000` correctly stopped `attach_line_call_session` settling on the
-- client's word. `20260818140000` then made the 6-hour backstop bill
-- `reserved_seconds` instead of the client's `duration_seconds` — also correct,
-- and argued explicitly on the premise that the backstop is RARE and only ever
-- catches calls the CDR failed to match.
--
-- **That premise is false, and it is measurably false.**
-- `app_config.telnyx_cdr_heartbeat` reads `records: 0, settled: 0` after
-- walking 4 pages: `sync-telnyx-cdr` has settled ZERO calls in the product's
-- entire history, and every historical `line_calls` row closed with
-- `hangup_cause = 'no_cdr'`. The backstop is not the exception — it is the only
-- settlement path that has ever run. A rule written to be a bounded, rare
-- over-bill silently became the billing rule for 100% of calls.
--
-- WHAT THAT COSTS, both halves live:
--
--   * DOMESTIC. A 17-second call consumes 120 s of a 6,000 s monthly
--     allowance. The $9.99 plan advertises 100 minutes and delivers ~50 calls
--     regardless of length.
--   * INTERNATIONAL, and this one takes real money. `settle_call_claim`
--     computes `v_used = ceil(seconds * rate / 60)` from whatever it is handed,
--     and this function handed it the full reservation for rows where NO LEG
--     EVER REACHED TELNYX — the five `missed` / `no_cdr` rows in `line_calls`
--     carry no `provider_call_session_id` at all. Real credits, charged for a
--     call that provably never happened.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- WHY THIS DOES NOT REOPEN THE EXPLOIT `20260818140000` CLOSED
-- ─────────────────────────────────────────────────────────────────────────────
--
-- That exploit is real and stays closed: report
-- `{status:"canceled", duration_seconds:0}` ten seconds into a live
-- international call, keep talking, get everything refunded. **Nothing here
-- restores trust in a client-reported DURATION, or in a client-reported
-- STATUS, for billing.** `duration_seconds` still decides no money anywhere.
--
-- ⚠️ THE GATE IS DELIBERATELY NOT ON `status`, AND THAT IS THE WHOLE DESIGN.
-- The obvious-looking fix is to make `settle_call_claim` bill zero whenever
-- `p_status in ('missed','busy','failed','canceled')` — which would even make
-- its own "a call that never connected bills nothing" comment true. **Do not
-- do that.** `status` is written by `attach_line_call_session` straight from
-- `report-line-call`'s request body, so that guard IS the exploit: set one
-- string, talk for an hour, pay nothing. It was checked and rejected here on
-- purpose; `settle_call_claim` is left byte-identical so no future reader
-- "restores" it.
--
-- The gate is instead on whether any provider leg identifier exists at all.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- THE EVIDENCE RULE, stated plainly so it is not silently widened later
-- ─────────────────────────────────────────────────────────────────────────────
--
-- `provider_call_session_id` / `provider_call_leg_id` both NULL is read here as
-- "no leg ever reached Telnyx". That is the same discriminator this product
-- already used to diagnose calling end to end: the three France calls of
-- 2026-08-18 each carried a session id and connected, while the seven earlier
-- attempts carried none and never reached the provider at all.
--
-- ⚠️ IT IS THE BEST EVIDENCE THAT EXISTS FOR A NO-CDR CALL, AND IT IS WEAK.
-- Every outcome field on `line_calls` is client-written, this one included, so
-- an attacker could suppress the ids. Two things make that acceptable where a
-- status gate is not:
--
--   1. **It is used only as an on/off gate, never to compute an amount.** A
--      call that reached the provider still bills the full server-set
--      reservation, whatever the device claims about it.
--   2. **The full-reservation bill was never a defense against the exploit
--      anyway.** Suppressing the session id is literally step 3 of the
--      documented attack, and the old answer was to charge one 120-second
--      block: against a ten-minute call to a $3.62/min destination that is
--      ~2 credits (~$0.80) of tax on ~$36 of wholesale. It was a rounding
--      error on the exploit while being a certain, recurring over-charge on
--      every honest missed call.
--
-- The exploit's actual bound is elsewhere and already in place: each line has
-- its own Telnyx outbound voice profile (`vsms-<line id>`) carrying its own
-- `daily_spend_limit`, so one abused line cannot run up an unbounded bill.
--
-- 🔴 **THE REAL REPAIR IS TO MAKE `sync-telnyx-cdr` MATCH A RECORD.** It never
-- has. Until it does, every call on this product is settled with no provider
-- evidence whatsoever, and both this gate and the reservation bill are
-- stand-ins for a billing truth we are not currently reading. Treat that as
-- the open defect; this migration only stops charging users for the gap.
--
-- WHAT IS ASSUMED FOR A CALL THAT DID REACH THE PROVIDER: that it used its
-- whole reservation. This over-bills a short connected call, knowingly. It is
-- kept because the only alternative number available is the device's, and a
-- bounded over-bill on an unmatched call is the trade `20260818140000` chose
-- and argued correctly. The two populations are now separated by hangup cause
-- so the size of that over-bill is countable rather than assumed:
--
--   * `no_cdr_full`      — reached Telnyx, no CDR, billed the full reservation
--   * `no_cdr_unreached` — never reached Telnyx, billed nothing
-- ─────────────────────────────────────────────────────────────────────────────

-- Unchanged from `20260818140000` except the `v_secs` computation and the
-- hangup cause. The selection predicate, the 24-hour hold on an `answered` call
-- with no end report, the status mapping and the 200-row limit are all
-- byte-identical.

create or replace function public.settle_stale_calls(p_older_minutes integer default 360)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_call record; v_count integer := 0; v_secs integer; v_reached boolean;
begin
  for v_call in
    select id, duration_seconds, reserved_seconds, status,
           provider_call_session_id, provider_call_leg_id
      from public.line_calls
     where allowance_settled = false
       and created_at < now() - make_interval(mins => greatest(coalesce(p_older_minutes, 360), 30))
       -- Settle at the normal horizon when the device reported an end, or when
       -- the call never reached a connected state. ONLY an `answered` call with
       -- no end report could still have someone talking on it; that one waits
       -- a full day — longer than any real call, still bounded.
       and (ended_at is not null
            or status <> 'answered'
            or created_at < now() - interval '24 hours')
     limit 200
  loop
    -- 🔴 STILL NEVER `duration_seconds` — it is client-supplied and decides no
    -- money anywhere (see 20260818140000). The only quantity billed is the
    -- server-set reservation, made at dial time and unreachable afterwards.
    --
    -- What is new is WHETHER we bill it at all. A row carrying neither a
    -- session id nor a leg id never reached Telnyx: there is no minute and no
    -- credit to recover, because nothing was ever consumed. See the header for
    -- why this evidence is the best available, why it is weak, and why it is
    -- deliberately an on/off gate rather than an input to the amount.
    v_reached := v_call.provider_call_session_id is not null
              or v_call.provider_call_leg_id is not null;
    v_secs := case when v_reached
                   then greatest(coalesce(v_call.reserved_seconds, 0), 0)
                   else 0 end;

    if public.settle_call_claim(
         v_call.id, v_secs, null,
         -- Status is UI-only after 20260817170000; keep the shape callers
         -- expect. A reservation-billed call is not "completed" in any
         -- evidential sense, so keep whatever the row already carries when it
         -- is terminal, else mark it missed.
         case when v_call.status in ('completed','answered') then 'completed'
              else 'missed' end::public.line_call_status,
         case when v_reached then 'no_cdr_full' else 'no_cdr_unreached' end) then
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end;
$function$;

revoke execute on function public.settle_stale_calls(integer) from public, anon, authenticated;
