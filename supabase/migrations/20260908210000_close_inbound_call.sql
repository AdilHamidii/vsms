-- Close an inbound call's `line_calls` row from Telnyx's own call events.
--
-- 🔴 THIS MOVES NO MONEY, AND MUST NEVER MOVE ANY. Inbound reserves nothing —
-- the caller pays their own carrier and the minute allowance covers outbound
-- only (`begin-line-call` passes `reserveSeconds = 0`, `settle_call_claim`'s
-- inbound branch settles a zero reservation). So this function writes ONLY
-- status / answered_at / ended_at / duration_seconds / hangup_cause and does
-- not touch `allowance_settled`, `reserved_seconds`, `billed_seconds`,
-- `credits_*` or `provider_cost_*`. It is history accuracy, not billing.
--
-- Leaving `allowance_settled` alone is deliberate: `sync-telnyx-cdr` still owns
-- the row and can still attach the provider's real cost to it. Residual, stated
-- plainly: if no CDR ever matches, `settle_stale_calls` closes the row at six
-- hours and overwrites `hangup_cause` with 'no_cdr_full'. The STATUS and
-- DURATION written here survive that (its status branch keeps 'completed' and
-- never touches `duration_seconds`), which is the part a user reads.
--
-- ── Why the gap existed ───────────────────────────────────────────────────
-- Inbound calling started working on 2026-09-08. `telnyx-webhook` transferred
-- the leg and wrote a `ringing` row, and `call.answered` / `call.hangup` were
-- logged and thrown away — so every incoming call sat `ringing` in the user's
-- history until the 6-hour backstop relabelled it, and a call nobody answered
-- was indistinguishable from one still in progress.
--
-- ── The key is the SESSION, and it is provider evidence ───────────────────
-- Measured from the live event log, 2026-09-08: the PSTN leg and the transfer
-- leg SHARE one `call_session_id` (session 3f9740c8 carried leg 3f974c44
-- `+1438… → +1437…` and leg 406269c4 `+1437… → sip:vsms…`). So one session is
-- one call, and `line_calls_session_key` — unique where the id is not null —
-- makes it a unique row key.
--
-- Both legs raise `call.answered` and both raise `call.hangup`, so EVERY call
-- delivers each event at least twice; redeliveries add more. The first event
-- to reach a non-terminal row wins and every later one is a no-op. That is
-- also what makes an out-of-order delivery safe: a `call.answered` arriving
-- after the hangup cannot un-terminal a finished call.
--
-- Session ids we never recorded (our own outbound legs, calls to numbers we do
-- not own) simply match nothing and are refused `unknown_call`.
--
-- 🔴 `direction = 'inbound'` IS A SAFETY ASSERTION, NOT A LOOKUP AID. The
-- session key is already unique across the table. The predicate is there so
-- this function can never, under any bug or replay, move an OUTBOUND row —
-- whose minutes and credits are real money settled from the provider's detail
-- record. Same rule as the standing one on `settle_stale_calls`: anything that
-- could touch a billed row must be structurally unable to.

create or replace function public.close_inbound_call_claim(
  p_session       text,
  p_event         text,                                   -- 'answered' | 'hangup'
  p_at            timestamptz default null,
  p_hangup_cause  text default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_id uuid; v_status public.line_call_status;
  v_started timestamptz; v_answered timestamptz; v_ended timestamptz;
  v_reserved integer; v_credits integer;
  v_at timestamptz; v_final public.line_call_status; v_dur integer;
begin
  if p_session is null or btrim(p_session) = '' then
    return jsonb_build_object('ok', false, 'reason', 'no_session');
  end if;
  if p_event not in ('answered', 'hangup') then
    return jsonb_build_object('ok', false, 'reason', 'unknown_event');
  end if;

  -- The claim. `for update` is what makes two simultaneous legs' events
  -- serialise instead of racing to write different terminal states.
  select id, status, started_at, answered_at, ended_at,
         coalesce(reserved_seconds, 0), coalesce(credits_reserved, 0)
    into v_id, v_status, v_started, v_answered, v_ended, v_reserved, v_credits
    from public.line_calls
   where provider_call_session_id = p_session
     and direction = 'inbound'
   for update;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'unknown_call');
  end if;

  -- Belt to the direction brace. An inbound row cannot carry a reservation;
  -- if one ever does, something is wrong and this function refuses rather
  -- than writing over a row that has money attached to it.
  if v_reserved > 0 or v_credits > 0 then
    return jsonb_build_object('ok', false, 'reason', 'not_free_inbound',
                              'call_id', v_id);
  end if;

  if v_status in ('completed','missed','busy','failed','canceled') then
    return jsonb_build_object('ok', true, 'reason', 'already_terminal',
                              'acted', false, 'call_id', v_id,
                              'status', v_status::text);
  end if;

  -- Telnyx's own timestamp when it is sane, ours otherwise. A stamp before the
  -- call started or far in the future is a clock we do not control producing a
  -- negative or absurd duration, so it is discarded rather than trusted.
  v_at := coalesce(p_at, now());
  if v_at > now() + interval '5 minutes'
     or (v_started is not null and v_at < v_started) then
    v_at := now();
  end if;

  if p_event = 'answered' then
    if v_status = 'answered' then
      return jsonb_build_object('ok', true, 'reason', 'already_answered',
                                'acted', false, 'call_id', v_id);
    end if;
    update public.line_calls
       set status      = 'answered',
           answered_at = coalesce(answered_at, v_at)
     where id = v_id;
    return jsonb_build_object('ok', true, 'reason', 'answered',
                              'acted', true, 'call_id', v_id);
  end if;

  -- hangup. A hangup with no answer is a MISSED call, never a zero-second
  -- answered one: "answered for 0s" reads as a fault in the app, and the
  -- overwhelmingly common inbound outcome is a call nobody picked up.
  if v_answered is not null or v_status = 'answered' then
    v_final := 'completed';
    v_dur := greatest(0, floor(extract(epoch from
               (v_at - coalesce(v_answered, v_started, v_at))))::int);
  else
    v_final := 'missed';
    v_dur := 0;
  end if;

  update public.line_calls
     set status           = v_final,
         ended_at         = coalesce(ended_at, v_at),
         duration_seconds = v_dur,
         hangup_cause     = coalesce(p_hangup_cause, hangup_cause)
   where id = v_id;

  return jsonb_build_object('ok', true, 'reason', v_final::text,
                            'acted', true, 'call_id', v_id,
                            'duration_seconds', v_dur);
end;
$$;

revoke execute on function public.close_inbound_call_claim(text, text, timestamptz, text)
  from public, anon, authenticated;

-- ── record_line_call: a redelivered `call.initiated` must not re-open a
-- finished call ───────────────────────────────────────────────────────────
--
-- The conflict arm was an unconditional `set status = excluded.status`, so a
-- retried or re-ordered `call.initiated` — Telnyx retries, and the webhook
-- always answers 200, so a retry is a timeout away — reset a completed call to
-- 'ringing'. Harmless while nothing ever closed an inbound row; the moment
-- close_inbound_call_claim does, it is a terminal state an old event can undo.
-- Everything else in this function is byte-identical to 20260805170000.
create or replace function public.record_line_call(
  p_line uuid, p_direction line_call_direction, p_peer text,
  p_session_id text, p_status line_call_status, p_reserved_seconds integer)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_user uuid; v_call uuid;
begin
  select user_id into v_user from public.phone_lines where id = p_line;
  if v_user is null then
    return jsonb_build_object('ok', false, 'reason', 'line_unavailable');
  end if;

  insert into public.line_calls (
    line_id, user_id, direction, peer_e164, provider_call_session_id,
    status, started_at, reserved_seconds)
  values (p_line, v_user, p_direction, p_peer, p_session_id,
          p_status, now(), greatest(coalesce(p_reserved_seconds, 0), 0))
  -- Partial index arbiter — the `where` is required, same as in
  -- record_inbound_message. A NULL session id simply never conflicts, which is
  -- correct: a call we have no provider id for yet is genuinely a new row.
  on conflict (provider_call_session_id) where provider_call_session_id is not null
  do update set status = case
       when public.line_calls.status
            in ('completed','missed','busy','failed','canceled')
         then public.line_calls.status
       else excluded.status end
  returning id into v_call;

  return jsonb_build_object('ok', true, 'call_id', v_call, 'user_id', v_user);
end;
$$;

revoke execute on function public.record_line_call(uuid, line_call_direction, text, text, line_call_status, integer)
  from public, anon, authenticated;
