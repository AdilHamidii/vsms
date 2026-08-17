-- A call that never connected must hand its reservation back IMMEDIATELY.
--
-- 🔴 THE BUG. `begin-line-call` reserves a flat 120 seconds before the client
-- dials. `attach_line_call_session` then records how the call ended — and
-- froze the status without ever touching the meter. So every call that failed,
-- was cancelled, hit a busy tone or went unanswered kept its full two minutes
-- until `settle_stale_calls()` swept it SIX HOURS later.
--
-- Measured live 2026-08-17: one subscriber made five outbound attempts between
-- 00:25:52 and 00:31:37, every one of them zero seconds long because calling
-- was broken outright (see 20260817090100 and the `user_name` fix in
-- `_shared/telnyx.ts`). Their line showed `voice_used_seconds = 600` — ten
-- minutes of a hundred-minute allowance consumed by calls that never rang.
-- Fifty such taps would have locked the user out of their own subscription for
-- six hours, and the meter in the app would have told them, correctly, that
-- they were out of minutes.
--
-- ⚠️ THE ASYMMETRY IS THE TELL. The SMS side already gets this right:
-- `settle_outbound_message_claim` calls `settle_line_allowance(..., 0, segments)`
-- the moment a message reports `failed`. Voice simply never grew the matching
-- branch. This makes the two paths agree.
--
-- WHY ONLY THE NEVER-CONNECTED STATUSES. `completed` is deliberately left to
-- the CDR: the client is advisory and `sync-telnyx-cdr` is the billing truth,
-- so settling a completed call from a device-reported duration would make the
-- device authoritative over money. That poller runs every 10 minutes, which is
-- a bounded wait. `canceled`/`failed`/`busy`/`missed` mean no leg was ever
-- answered, so the billable time is zero BY DEFINITION rather than by the
-- client's say-so — there is nothing for a CDR to correct, and
-- `settle_call_claim` guards re-entry with `if v_settled then return false`.

-- ⚠️ The DEFAULTs are part of the signature and must be reproduced exactly.
-- `report-line-call` passes every argument, but dropping them here would still
-- change the callable shape for anything that does not.
create or replace function public.attach_line_call_session(
  p_user uuid,
  p_call uuid,
  p_session text,
  p_leg text default null,
  p_status public.line_call_status default null,
  p_answered_at timestamptz default null,
  p_duration_seconds integer default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner uuid; v_settled boolean; v_existing text;
  v_status public.line_call_status; v_terminal boolean;
  v_final public.line_call_status;
begin
  select user_id, allowance_settled, provider_call_session_id, status
    into v_owner, v_settled, v_existing, v_status
    from public.line_calls where id = p_call for update;
  if not found or v_owner is null then
    return jsonb_build_object('ok', false, 'reason', 'unknown_call');
  end if;
  if v_owner <> p_user then
    return jsonb_build_object('ok', false, 'reason', 'unknown_call');
  end if;
  if v_settled then
    return jsonb_build_object('ok', true, 'reason', 'already_settled');
  end if;
  if v_existing is not null and p_session is not null and v_existing <> p_session then
    return jsonb_build_object('ok', false, 'reason', 'session_conflict');
  end if;

  v_terminal := v_status in ('completed','missed','busy','failed','canceled');

  update public.line_calls
     set provider_call_session_id = coalesce(p_session, provider_call_session_id),
         provider_call_leg_id     = coalesce(p_leg, provider_call_leg_id),
         -- Once terminal, the status and the duration are FROZEN. A second
         -- report cannot turn a completed call into a canceled one, nor a
         -- real duration into 0.
         status                   = case when v_terminal then status
                                         else coalesce(p_status, status) end,
         answered_at              = coalesce(answered_at, p_answered_at),
         duration_seconds         = case when v_terminal then duration_seconds
                                         else coalesce(p_duration_seconds, duration_seconds) end,
         ended_at = case
           when v_terminal then ended_at
           when p_status in ('completed','missed','busy','failed','canceled')
             then coalesce(ended_at, now())
           else ended_at end
   where id = p_call;

  -- Whatever the row now says it is. Re-read rather than trusting p_status,
  -- because the freeze above may have kept an earlier terminal value.
  select status into v_final from public.line_calls where id = p_call;

  -- Hand the reservation back for a call that never connected. Zero billed
  -- seconds is the truth here, not an estimate, so this is a settlement and
  -- not a guess.
  if v_final in ('canceled','failed','busy','missed') then
    perform public.settle_call_claim(
      p_call, 0, null, v_final, 'client_reported_' || v_final::text);
    return jsonb_build_object('ok', true, 'reason', 'settled_unconnected');
  end if;

  return jsonb_build_object('ok', true,
                            'reason', case when v_terminal then 'already_terminal'
                                           else 'attached' end);
end;
$$;

revoke execute on function public.attach_line_call_session(
  uuid, uuid, text, text, public.line_call_status, timestamptz, integer)
  from public, anon, authenticated;

-- Repair: release any reservation still held by a never-connected call. This
-- is normally empty, because `settle_stale_calls()` catches them six hours
-- later — which is exactly the window this migration closes.
do $repair$
declare v_call record; v_n integer := 0;
begin
  for v_call in
    select id, status from public.line_calls
     where allowance_settled = false
       and status in ('canceled','failed','busy','missed')
  loop
    if public.settle_call_claim(v_call.id, 0, null, v_call.status, 'backfill_unconnected') then
      v_n := v_n + 1;
    end if;
  end loop;
  raise notice 'released reservations on % unconnected call(s)', v_n;
end
$repair$;
