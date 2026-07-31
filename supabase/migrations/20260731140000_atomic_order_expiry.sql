-- Make the expiry sweep's claim+refund ATOMIC, and give the relay a budget the
-- function was actually written for.
--
-- Found while investigating a watchdog `relay-http` alert: two pg_net timeouts
-- in six hours (739 successful relays), both exactly 30000 ms — the
-- `relay-poll-active-orders` cap. Every budget comment inside
-- `poll-active-orders` reasons about the ~150s edge limit and sizes
-- limit(200)/limit(50)/limit(50) against it, so the caller was granting 5× less
-- than the callee assumes and a slow run gets KILLED mid-sweep.
--
-- That mattered more than the alert did. The sweep claimed the order terminal
-- and refunded it in TWO separate round-trips:
--
--     update orders set status='expired' where id=? and status='waiting'
--     ...  <-- worker killed here = charge never refunded, forever
--     rpc wallet_credit(...)
--
-- A terminal row is never revisited, so a kill in that window leaves a user
-- charged with no refund and nothing to retry it. The rollback added earlier
-- today only covers wallet_credit RETURNING an error; it cannot run if the
-- process is gone.
--
-- check-order already had this right. `expire_order()` takes the row lock,
-- re-checks `waiting`, flips the status and refunds inside ONE transaction, so
-- a killed process rolls the whole thing back and the next sweep retries.
--
-- So: one implementation, two entry points, so the two cannot drift. The sweep
-- needs a boolean (it must know whether IT claimed the row, to push and count
-- exactly once); check-order keeps the void signature it already calls.

create or replace function public.expire_order_claim(p_order uuid)
returns boolean
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

    -- Another concurrent run claimed it, or it already closed. Not an error.
    if not found or rec.status <> 'waiting' then
        return false;
    end if;

    update public.orders
       set status = 'expired', closed_at = now()
     where id = p_order;

    -- wallet_credit RAISES on a non-positive amount or a missing wallet row,
    -- which aborts this transaction and undoes the status flip above. That is
    -- the entire point: the order returns to `waiting` and the next sweep tries
    -- again, rather than sitting terminal and permanently unrefundable.
    perform public.wallet_credit(rec.user_id, rec.cost_credits, 'refund', p_order);
    return true;
end;
$$;

-- Kept as a thin wrapper rather than a second copy of the body — check-order
-- calls this signature and a duplicated implementation is exactly the kind of
-- thing that drifts.
create or replace function public.expire_order(p_order uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
    perform public.expire_order_claim(p_order);
end;
$$;

-- CREATE FUNCTION grants EXECUTE to PUBLIC and anon/authenticated are members
-- of it, so revoking from them alone is a no-op. Verified before this ran:
-- expire_order is service_role-only, and expire_order_claim must match.
revoke execute on function public.expire_order_claim(uuid) from public, anon, authenticated;
revoke execute on function public.expire_order(uuid)       from public, anon, authenticated;

-- Grant the relay the budget the function is written against. 120s matches the
-- other heavyweight relays (daily-credit, sync-esim-plans) and stays under the
-- ~150s edge ceiling. Overlapping runs are safe by construction — every status
-- write in poll-active-orders is an atomic claim, which its own comments call
-- out as the reason two concurrent sweeps cannot both refund the same order.
select cron.schedule(
    'relay-poll-active-orders',
    '* * * * *',
    $cron$
    select net.http_post(
        url := 'https://enugzltysdmjzavisloy.supabase.co/functions/v1/poll-active-orders',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'x-cron-secret', private_cron_secret()
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 120000
    );
    $cron$
);
