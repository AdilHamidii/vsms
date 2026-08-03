-- HeroSMS fail-fast: close a dead order early WITHOUT giving up the number.
--
-- Measured 2026-08-03 over every HeroSMS order since the 07-30 cutover:
-- every code that has ever arrived did so between 19s and 86s, and of the 22
-- orders still alive at 90 seconds NOT ONE ever delivered. SMSPVA over the
-- same measure delivered 11 of 49 (22%) after 90s and as late as 337s, so this
-- is a HeroSMS property, not a general one (Fisher exact p = 0.014). Meanwhile
-- seven HeroSMS orders ran the full 8-minute window for nothing, burning 59.5
-- minutes of users sitting on a waiting screen that was already decided.
--
-- This is `expire_order_claim` plus ONE extra assignment: `late_watch_until`.
-- That single column is what makes closing early safe rather than a gamble on
-- a threshold. poll-active-orders keeps polling the number until its ORIGINAL
-- deadline and hands over any late code for free (the same rescue path a user
-- cancel already uses), so the worst case of being wrong about 150s is a
-- refund we were going to make anyway — never a lost code. Without it the
-- number would simply be abandoned: nothing releases a terminal order, and the
-- rescue sweep would never see it.
--
-- Kept as a SEPARATE function rather than a flag on expire_order_claim. That
-- one is called from two places (the natural-expiry sweep and check-order) and
-- both MUST keep releasing the number — the natural sweep markDead()s it right
-- after, which is what reclaims the wholesale. Adding a parameter would have
-- made the release conditional on a caller getting it right.
--
-- Status is 'expired', not 'canceled', deliberately. The user did not cancel;
-- we concluded the order was dead. It also puts the row inside the evidence
-- window (`status in ('received','expired')`), which is correct — a HeroSMS
-- number that never received anything IS evidence about that route, whereas a
-- cancel measures impatience and is excluded everywhere on purpose.
create or replace function public.expire_order_early_claim(p_order uuid)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $function$
declare rec record;
begin
    select user_id, cost_credits, status, expires_at, smspva_id
      into rec
      from public.orders
     where id = p_order
       for update;

    -- Another concurrent run claimed it, or it already closed. Not an error.
    if not found or rec.status <> 'waiting' then
        return false;
    end if;

    update public.orders
       set status           = 'expired',
           closed_at        = now(),
           -- Only a row that actually HOLDS a number can be rescued. A null
           -- smspva_id with a non-null late_watch_until would spin in the
           -- rescue sweep, which nulls the column and moves on.
           late_watch_until = case when rec.smspva_id is not null
                                   then rec.expires_at else null end
     where id = p_order;

    -- wallet_credit RAISES on a non-positive amount or a missing wallet row,
    -- which aborts this transaction and undoes the status flip above. That is
    -- the entire point: the order returns to `waiting` and the next sweep tries
    -- again, rather than sitting terminal and permanently unrefundable.
    perform public.wallet_credit(rec.user_id, rec.cost_credits, 'refund', p_order);
    return true;
end;
$function$;

-- CREATE FUNCTION grants EXECUTE to PUBLIC, and anon/authenticated are members
-- of PUBLIC — so revoking from those two alone is a no-op and the function
-- stays callable at /rest/v1/rpc/. PUBLIC must be named explicitly.
revoke execute on function public.expire_order_early_claim(uuid)
  from public, anon, authenticated;
