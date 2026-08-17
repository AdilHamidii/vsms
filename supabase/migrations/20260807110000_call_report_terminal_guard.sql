-- The server half of the double-report fix.
--
-- `attach_line_call_session` guarded only on `allowance_settled`, which stays
-- false for up to ~10 minutes (the sync-telnyx-cdr cron interval). Inside that
-- window ANY non-null status/duration overwrote the row, so a late duplicate
-- report of `canceled` / 0s landed on top of a real `completed` call.
--
-- The client fix (CallController.reportFinalOnce + the endCall reentrancy
-- guard) stops ours from sending one. This is the belt: a report can also
-- arrive late from a retry, a backgrounded app, or a future caller, and the
-- corruption is not cosmetic — `settle_stale_calls` falls back to
-- `duration_seconds` to settle the allowance when no CDR ever arrives.
--
-- Write-once, like `provider_call_session_id` beside it: the FIRST terminal
-- status wins, and later reports may still fill in fields that are still null.
create or replace function public.attach_line_call_session(
  p_user uuid, p_call uuid, p_session text, p_leg text default null,
  p_status public.line_call_status default null,
  p_answered_at timestamptz default null,
  p_duration_seconds integer default null
) returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_owner uuid; v_settled boolean; v_existing text;
  v_status public.line_call_status; v_terminal boolean;
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

  return jsonb_build_object('ok', true,
                            'reason', case when v_terminal then 'already_terminal'
                                           else 'attached' end);
end;
$fn$;
revoke execute on function public.attach_line_call_session(
  uuid, uuid, text, text, public.line_call_status, timestamptz, integer)
  from public, anon, authenticated;
