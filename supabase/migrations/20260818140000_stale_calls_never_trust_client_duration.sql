-- ─────────────────────────────────────────────────────────────────────────────
-- settle_stale_calls(): the 6h backstop must NEVER bill from a client number
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Found by the 2026-08-18 red-team pass. Migration 20260817170000 correctly
-- stopped `attach_line_call_session` from settling a call on the client's say-so
-- — "if a value decides money and the device can set it, the device must not be
-- the one that settles". But the same commit relies on this backstop for calls
-- the CDR never matched, and this backstop billed
--
--     v_secs := greatest(coalesce(v_call.duration_seconds, 0), 0)
--
-- — and `duration_seconds` is written by `attach_line_call_session` from the
-- REQUEST BODY of `report-line-call`. Its own comment said "duration_seconds is
-- real". It is not; it is whatever the phone sent.
--
-- The exploit, verified by reading the live functions:
--   1. Dial internationally. `begin-line-call` is deliberately off the ring
--      path, so nothing tears the call down.
--   2. Report `{status:"canceled", duration_seconds:0}` and DO NOT report the
--      real Telnyx `session_id`/`leg_id` — nothing forces the client to. Or
--      report nothing at all.
--   3. `sync-telnyx-cdr` matches ONLY on those two client-supplied ids, so the
--      real detail record stays `unmatched` on every 10-minute sweep.
--   4. After 6h this function fires and settles at 0 seconds:
--      `settle_call_claim` refunds the ENTIRE international credit block and
--      hands back the whole 120s domestic reservation.
--   5. Repeat. Free international calling — including to the premium ranges
--      the same day's migration priced out — while the owner pays Telnyx
--      wholesale for every minute.
--
-- THE FIX is the direction the CDR poller already states as policy
-- ("over-reserve, refund late"): a call the provider never confirmed is billed
-- at the FULL reservation, never at the client's figure. `reserved_seconds`
-- and `credits_reserved` were both set server-side at dial time and cannot be
-- influenced afterwards. A user who genuinely had a short failed call and was
-- never matched loses at most one reservation block — bounded, visible in the
-- ledger, recoverable by hand. A user gaming it gains nothing.
--
-- `duration_seconds` is left exactly as it was: a UI-facing value the app
-- shows in call history. It simply no longer decides money anywhere.
--
-- Also: an `unmatched` counter already exists on the CDR heartbeat. A call
-- settled here at full reservation now records `hangup_cause = 'no_cdr_full'`
-- so the ones that hit this path can be counted and, if the CDR matcher is
-- what is broken, fixed — rather than silently over- or under-billing.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.settle_stale_calls(p_older_minutes integer default 360)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_call record; v_count integer := 0; v_secs integer;
begin
  for v_call in
    select id, duration_seconds, reserved_seconds, status
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
    -- 🔴 NEVER `duration_seconds` here — it is client-supplied (see header).
    -- No CDR ever matched this call, so the provider's figure is unknown, and
    -- the only number we hold that the device could not set is the
    -- reservation made at dial time. Bill that. Over-billing a real short
    -- call by one block is bounded and recoverable; under-billing on the
    -- client's word is unbounded and was the exploit.
    v_secs := greatest(coalesce(v_call.reserved_seconds, 0), 0);
    if public.settle_call_claim(
         v_call.id, v_secs, null,
         -- Status is UI-only after 20260817170000; keep the shape callers
         -- expect. A reservation-billed call is not "completed" in any
         -- evidential sense, so keep whatever the row already carries when it
         -- is terminal, else mark it missed.
         case when v_call.status in ('completed','answered') then 'completed'
              else 'missed' end::public.line_call_status,
         'no_cdr_full') then
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end;
$function$;

revoke execute on function public.settle_stale_calls(integer) from public, anon, authenticated;
