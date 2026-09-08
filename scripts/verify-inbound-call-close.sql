-- Behavioural checks for close_inbound_call_claim + the record_line_call
-- redelivery guard (migration 20260908210000). Everything runs inside a
-- transaction that is ROLLED BACK, so production state is untouched.
--
-- Run: supabase db query --linked --file scripts/verify-inbound-call-close.sql
-- Expect: 'NEGATIVE CONTROL OK' then 'ALL CHECKS PASSED'. Any failure raises.
--
-- A structural check cannot cover any of this: the function exists and is
-- callable in every one of the failure modes below. Only behaviour separates
-- "closed the call" from "closed the wrong call", and money from history.

begin;

do $$
declare
  v_line uuid; v_user uuid; v_call uuid; v_out uuid;
  r record; j jsonb; v_raised boolean;
begin
  select id, user_id into v_line, v_user
    from public.phone_lines where e164 = '+14377832487' limit 1;
  if v_line is null then
    raise exception 'fixture line +14377832487 is gone — pick another live line';
  end if;

  -- ── A: ringing → answered → hangup = completed, with a real duration ────
  j := public.record_line_call(v_line, 'inbound', '+15551230001',
                               'verify-sess-A', 'ringing', 0);
  v_call := (j->>'call_id')::uuid;
  update public.line_calls set started_at = now() - interval '30 seconds'
   where id = v_call;

  j := public.close_inbound_call_claim('verify-sess-A', 'answered',
                                       now() - interval '20 seconds', null);
  if j->>'reason' <> 'answered' or (j->>'acted')::boolean is not true then
    raise exception 'A: answered event refused (%)', j;
  end if;

  j := public.close_inbound_call_claim('verify-sess-A', 'hangup',
                                       now() - interval '5 seconds',
                                       'normal_clearing');
  if j->>'reason' <> 'completed' then
    raise exception 'A: answered call did not complete (%)', j;
  end if;

  select * into r from public.line_calls where id = v_call;
  if r.status <> 'completed' then
    raise exception 'A: status is % not completed', r.status;
  end if;
  if r.answered_at is null or r.ended_at is null then
    raise exception 'A: answered_at/ended_at not stamped (% / %)',
      r.answered_at, r.ended_at;
  end if;
  if r.duration_seconds is distinct from 15 then
    raise exception 'A: duration is % not 15', r.duration_seconds;
  end if;
  if r.hangup_cause <> 'normal_clearing' then
    raise exception 'A: hangup cause is %', r.hangup_cause;
  end if;

  -- ── E: NO MONEY MOVED. The whole point of this function. ───────────────
  if r.allowance_settled is not false then
    raise exception 'E: allowance_settled was flipped — this function must never settle';
  end if;
  if coalesce(r.reserved_seconds, 0) <> 0 or coalesce(r.credits_reserved, 0) <> 0
     or r.credits_charged is not null or r.billed_seconds is not null
     or r.provider_cost_cents is not null then
    raise exception 'E: a billing column was written (reserved=% credits=% charged=% billed=% cost=%)',
      r.reserved_seconds, r.credits_reserved, r.credits_charged,
      r.billed_seconds, r.provider_cost_cents;
  end if;

  -- ── C: a REDELIVERED hangup on a terminal row is a no-op ───────────────
  j := public.close_inbound_call_claim('verify-sess-A', 'hangup', now(), 'timeout');
  if j->>'reason' <> 'already_terminal' or (j->>'acted')::boolean is not false then
    raise exception 'C: duplicate hangup was not a no-op (%)', j;
  end if;
  select * into r from public.line_calls where id = v_call;
  if r.hangup_cause <> 'normal_clearing' or r.duration_seconds <> 15 then
    raise exception 'C: duplicate hangup overwrote a terminal row (% / %)',
      r.hangup_cause, r.duration_seconds;
  end if;

  -- ── I: a REDELIVERED call.initiated must not re-open a finished call ───
  j := public.record_line_call(v_line, 'inbound', '+15551230001',
                               'verify-sess-A', 'ringing', 0);
  if (j->>'call_id')::uuid <> v_call then
    raise exception 'I: redelivery created a second row';
  end if;
  select status into r from public.line_calls where id = v_call;
  if r.status <> 'completed' then
    raise exception 'I: a replayed call.initiated re-opened a completed call (status=%)',
      r.status;
  end if;

  -- ── B: hangup with NO answer is a MISSED call, not a 0-second answered one
  j := public.record_line_call(v_line, 'inbound', '+15551230002',
                               'verify-sess-B', 'ringing', 0);
  v_call := (j->>'call_id')::uuid;
  j := public.close_inbound_call_claim('verify-sess-B', 'hangup', now(), 'no_answer');
  if j->>'reason' <> 'missed' then
    raise exception 'B: unanswered call did not become missed (%)', j;
  end if;
  select * into r from public.line_calls where id = v_call;
  if r.status <> 'missed' or r.duration_seconds <> 0 or r.answered_at is not null then
    raise exception 'B: missed row wrong (status=% dur=% answered=%)',
      r.status, r.duration_seconds, r.answered_at;
  end if;
  if r.ended_at is null then raise exception 'B: ended_at not stamped'; end if;

  -- ── D: OUT OF ORDER. A late `answered` cannot un-terminal a missed call.
  j := public.close_inbound_call_claim('verify-sess-B', 'answered', now(), null);
  if j->>'reason' <> 'already_terminal' then
    raise exception 'D: late answered event acted on a terminal row (%)', j;
  end if;
  select status into r from public.line_calls where id = v_call;
  if r.status <> 'missed' then
    raise exception 'D: a late answered event resurrected a missed call (%)', r.status;
  end if;

  -- ── F: an OUTBOUND row is NEVER touched, even on an exact session match.
  -- Its minutes and credits are real money settled from the provider's CDR.
  j := public.record_line_call(v_line, 'outbound', '+15551230003',
                               'verify-sess-F', 'ringing', 120);
  v_out := (j->>'call_id')::uuid;
  j := public.close_inbound_call_claim('verify-sess-F', 'hangup', now(), 'normal_clearing');
  if j->>'reason' <> 'unknown_call' then
    raise exception 'F: an OUTBOUND row was reachable from the inbound closer (%)', j;
  end if;
  select * into r from public.line_calls where id = v_out;
  if r.status <> 'ringing' or r.reserved_seconds <> 120 or r.ended_at is not null then
    raise exception 'F: outbound row mutated (status=% reserved=% ended=%)',
      r.status, r.reserved_seconds, r.ended_at;
  end if;

  -- ── G: an inbound row carrying a reservation is REFUSED, not written over.
  j := public.record_line_call(v_line, 'inbound', '+15551230004',
                               'verify-sess-G', 'ringing', 0);
  v_call := (j->>'call_id')::uuid;
  update public.line_calls set reserved_seconds = 60 where id = v_call;
  j := public.close_inbound_call_claim('verify-sess-G', 'hangup', now(), 'normal_clearing');
  if j->>'reason' <> 'not_free_inbound' then
    raise exception 'G: a reserved inbound row was written over (%)', j;
  end if;
  select status into r from public.line_calls where id = v_call;
  if r.status <> 'ringing' then
    raise exception 'G: reserved inbound row mutated (%)', r.status;
  end if;

  -- ── H: unknown session and unknown event are refusals, never guesses.
  j := public.close_inbound_call_claim('verify-sess-NOPE', 'hangup', now(), null);
  if j->>'reason' <> 'unknown_call' then
    raise exception 'H: unknown session not refused (%)', j;
  end if;
  j := public.close_inbound_call_claim('verify-sess-B', 'call.bridged', now(), null);
  if j->>'reason' <> 'unknown_event' then
    raise exception 'H: unknown event not refused (%)', j;
  end if;
  j := public.close_inbound_call_claim(null, 'hangup', now(), null);
  if j->>'reason' <> 'no_session' then
    raise exception 'H: null session not refused (%)', j;
  end if;

  -- ── Negative control: prove the assertions above can actually fail. ─────
  -- Without this the whole script is compatible with an empty DO block that
  -- asserts nothing at all. (Never write a literal dollar-quote in a comment
  -- inside one: it terminates the block early, which is a 42601 at a line
  -- number that points at innocent code.)
  v_raised := false;
  begin
    select status into r from public.line_calls where id = v_call;
    if r.status <> 'this_is_not_a_status' then
      raise exception 'negative control fired';
    end if;
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    raise exception 'NEGATIVE CONTROL DID NOT FIRE — these assertions prove nothing';
  end if;
  raise notice 'NEGATIVE CONTROL OK';

  raise notice 'ALL CHECKS PASSED';
end $$;

rollback;
