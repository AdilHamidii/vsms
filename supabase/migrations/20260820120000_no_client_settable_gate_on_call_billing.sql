-- ─────────────────────────────────────────────────────────────────────────────
-- REVERT: `provider_call_session_id` IS NOT PROVIDER EVIDENCE. IT IS THE
-- CLIENT'S WORD UNDER A NAME THAT READS LIKE THE PROVIDER'S.
-- ─────────────────────────────────────────────────────────────────────────────
--
-- `20260820110000` made the 6-hour backstop settle a call to ZERO seconds when
-- `provider_call_session_id` and `provider_call_leg_id` are both null,
-- reasoning that such a call "never reached Telnyx". It rejected a `status`
-- gate — correctly — because `status` is client-supplied. **Both columns are
-- client-supplied.** They are written ONLY by `attach_line_call_session`, whose
-- argument comes verbatim out of `report-line-call`'s request body
-- (`p_session: body.session_id ?? null`), and `telnyx-webhook` handles no call
-- events at all. Nothing in this product ever writes a call identifier from a
-- source the device does not control.
--
-- 🔴 SO THE GATE MADE SILENCE THE WINNING MOVE. Never call `report-line-call`
-- — or force-quit mid-call — and after six hours this function billed
-- `v_secs = 0`: the entire domestic reservation handed back, the entire
-- international credit block refunded. `sync-telnyx-cdr` cannot correct it,
-- because it matches on the very ids the attacker suppressed. The only bound
-- left was the per-line Telnyx `daily_spend_limit` of $5.00/day — ~$150/month
-- of wholesale against $8.49/month net. Before the change, staying silent
-- still cost 2 credits per 120 s dial: a real, per-call tax. The "fix" strictly
-- weakened the client-controlled path, and it was live: all six `line_calls`
-- rows settled at `credits_reserved = 0`.
--
-- It also mis-billed honest users in the other direction. `report()` in
-- `CallController` is fire-and-forget with a single retry, so a genuinely
-- connected call whose two reports both fail carries no session id and settled
-- free.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- THE RULE, so neither gate is reintroduced
-- ─────────────────────────────────────────────────────────────────────────────
--
-- **The only correct source of a call's duration is the provider's detail
-- record.** Until `sync-telnyx-cdr` matches one — it has matched ZERO in the
-- product's history; every historical row closed `no_cdr` — this backstop
-- deliberately OVER-bills rather than under-bills, and any future gate must key
-- on data THE DEVICE CANNOT SET.
--
-- Two gates have been proposed and both are rejected permanently:
--
--   * the `status` gate (`p_status in ('missed','busy','failed','canceled')`
--     bills zero) — `status` arrives in `report-line-call`'s body. Rejected in
--     `20260820110000`, and that rejection stands. `settle_call_claim` stays
--     byte-identical so nobody "restores" the comment it appears to contradict.
--   * the session/leg-id gate (`provider_call_session_id is null` bills zero) —
--     rejected HERE, for exactly the same reason, which the column name hides.
--
-- The asymmetry that decides it: an over-charge is bounded (one reservation
-- block), lands in the ledger where we can see it, and is refundable by hand.
-- An under-charge is unbounded, invisible, and repeatable at will. With no
-- billing truth available at all today, settle conservatively — bill the
-- reservation, which was set server-side at dial time and cannot be influenced
-- afterwards.
--
-- Consequence, accepted knowingly: a genuinely missed or never-connected call
-- still consumes its reservation. That is the pre-existing `20260818140000`
-- behaviour and it is not exploitable. `hangup_cause = 'no_cdr_full'` marks
-- every row settled this way, so the size of the over-bill stays countable.
--
-- 🔴 THE REAL REPAIR REMAINS: make `sync-telnyx-cdr` match a record. Everything
-- here is a stand-in for a billing truth we are not currently reading.
--
-- Restores the body of `20260818140000` exactly — selection predicate, the
-- 24-hour hold on an `answered` call with no end report, the status mapping and
-- the 200-row limit are all unchanged from both prior versions.
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
    -- 🔴 THE SETTLEMENT SITE. Read the header before changing this line.
    --
    -- NEVER `duration_seconds` — client-supplied. NEVER gated on `status` —
    -- client-supplied. NEVER gated on `provider_call_session_id` /
    -- `provider_call_leg_id` — ALSO client-supplied, despite the name: they are
    -- written only by `attach_line_call_session` from `report-line-call`'s
    -- request body, so gating on them made never reporting the winning move.
    --
    -- The only correct source of a call's duration is the provider's detail
    -- record. Until `sync-telnyx-cdr` matches one, this backstop deliberately
    -- over-bills rather than under-bills: it charges the server-set reservation
    -- made at dial time, which the device cannot influence. Any future gate
    -- must key on data THE DEVICE CANNOT SET.
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
