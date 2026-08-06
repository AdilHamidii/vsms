-- Two fixes, both instances of rules this repo already wrote down and then did
-- not apply to one more path.

-- ── 1. cancel_order_claim — the EIGHTH close path ──────────────────────────
--
-- "A status claim and its refund must be ONE transaction, never two
-- round-trips. Where they are split, a worker killed in between leaves a
-- TERMINAL row with the charge never returned — and the expiry sweeps only
-- select status='waiting', so nothing ever revisits it. No timeout value fixes
-- this; a TypeScript rollback cannot either, because the process is gone."
--
-- Seven paths were migrated to claim functions (expire_order_claim,
-- expire_order_early_claim, fail_esim_order_claim, close_email_order_claim).
-- `cancel-order` and `create-order`'s failOrder were not, and between them they
-- are the two busiest close paths in the product — failOrder absorbs
-- margin_too_low, stockouts, provider faults and order_persist_failed. Both
-- carried a TS rollback, which is precisely the mitigation the rule says does
-- not work.
--
-- It has never fired: a query for terminal orders with a charge and no matching
-- refund row returns zero. The window is one Postgres round-trip at the end of
-- a request, so it needs a deploy/OOM/restart landing in that millisecond. But
-- when it does fire it is silent and permanent, which is why it gets closed
-- now rather than after it costs someone their money.
--
-- `p_late_watch_until` carries cancel-order's late-code rescue: the number is
-- deliberately NOT released on cancel, and this stamp is what tells
-- poll-active-orders' sweep to keep watching it. NULL for failOrder, which
-- never reserved a number worth watching.
create or replace function public.cancel_order_claim(
  p_order uuid,
  p_late_watch_until timestamptz default null
) returns boolean
language plpgsql
security definer
set search_path to 'public'
as $$
declare rec record;
begin
    select user_id, cost_credits, status
      into rec
      from public.orders
     where id = p_order
       for update;

    -- Already closed by the expiry sweep, check-order, or a concurrent cancel.
    -- Not an error: the caller must NOT refund again on top of it.
    if not found or rec.status <> 'waiting' then
        return false;
    end if;

    update public.orders
       set status = 'canceled',
           closed_at = now(),
           late_watch_until = p_late_watch_until
     where id = p_order;

    -- wallet_credit RAISES on a non-positive amount or a missing wallet row,
    -- which aborts this transaction and undoes the status flip above. That is
    -- the whole point: the order stays `waiting` and remains recoverable,
    -- rather than sitting terminal and permanently unrefundable.
    perform public.wallet_credit(rec.user_id, rec.cost_credits, 'refund', p_order);
    return true;
end;
$$;

revoke execute on function public.cancel_order_claim(uuid, timestamptz)
  from public, anon, authenticated;

-- ── 2. settle_stale_calls must not settle a call that is still connected ────
--
-- The cursor selected purely on age with no `status` and no `ended_at` test,
-- and settles from `duration_seconds` — which is NULL until the client reports
-- an end. So a call still in progress at the 6-hour mark was written off as
-- `missed` with billed_seconds = 0 and its whole reservation refunded, while
-- the user was still talking. `settle_call_claim` then refuses to run again on
-- that row (`if not found or v_settled then return false`) and
-- sync-telnyx-cdr drops it from `pending` — so the genuine CDR, when it
-- arrived, could never be applied. The minutes became unrecoverable AND the
-- allowance was handed back.
--
-- Nothing caps call duration (that is deliberate — `settle_line_allowance` is
-- explicitly allowed to overshoot, and the hard stop gates NEW calls), so a
-- >6h call is reachable rather than theoretical.
--
-- The fix keeps the backstop for its actual purpose — a client that died
-- without reporting — while never touching a call that could still be live.
-- `answered` is the ONLY status a connected call can be in; a `ringing` row at
-- the six-hour mark is unambiguously dead, because nothing rings for six hours.
-- So only an answered-but-unreported call waits the longer horizon, and the
-- ordinary abandoned-reservation case still reclaims on schedule.
create or replace function public.settle_stale_calls(
  p_older_minutes integer default 360
) returns integer
language plpgsql security definer set search_path to 'public' as $fn$
declare v_call record; v_count integer := 0; v_secs integer;
begin
  for v_call in
    select id, duration_seconds
      from public.line_calls
     where allowance_settled = false
       and created_at < now() - make_interval(mins => greatest(coalesce(p_older_minutes, 360), 30))
       -- ⚠️ THE GUARD. Settle at the normal horizon when the device reported an
       -- end (duration_seconds is real), or when the call never reached a
       -- connected state at all. ONLY an `answered` call with no end report
       -- could still have someone talking on it, and that one waits a full day
       -- — comfortably longer than any real call, and still bounded so the
       -- reservation is never held forever.
       and (ended_at is not null
            or status <> 'answered'
            or created_at < now() - interval '24 hours')
     limit 200
  loop
    v_secs := greatest(coalesce(v_call.duration_seconds, 0), 0);
    if public.settle_call_claim(
         v_call.id, v_secs, null,
         case when v_secs > 0 then 'completed' else 'missed' end::public.line_call_status,
         'no_cdr') then
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end;
$fn$;
revoke execute on function public.settle_stale_calls(integer)
  from public, anon, authenticated;

-- Assert both are service-role only. `CREATE FUNCTION` grants EXECUTE to PUBLIC
-- and anon/authenticated are members of it, so the revokes above are the only
-- thing standing between these and /rest/v1/rpc/<name>.
do $$
begin
  if has_function_privilege('anon', 'public.cancel_order_claim(uuid, timestamptz)', 'execute')
     or has_function_privilege('authenticated', 'public.cancel_order_claim(uuid, timestamptz)', 'execute')
     or has_function_privilege('anon', 'public.settle_stale_calls(integer)', 'execute') then
    raise exception 'claim functions are reachable from a client role';
  end if;
end $$;
