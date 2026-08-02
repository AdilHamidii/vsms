-- Close-and-refund must be ONE transaction on every product line, not just SMS.
--
-- 20260731140000 fixed exactly this for SMS expiry (`expire_order_claim`) and
-- the 2026-08-02 audit found the same two-round-trip shape still live in four
-- places: poll-active-orders' provider-close branch and check-order's twin
-- (both fixed in TS by calling expire_order_claim), create-esim-order's
-- failEsim, create-email-order's failEmail, and check-email-order's terminal
-- patch. In each, the status flip commits and the refund is a separate
-- round-trip — a worker killed between the two (or a refund error) leaves a
-- terminal row with the charge kept, and the sweeps select only live rows so
-- nothing ever retries it. That is the exact bug class that once let every
-- failed eSIM purchase keep the user's money.
--
-- Same shape as expire_order_claim: lock, re-check live, flip, refund — and
-- the wallet_move_* functions RAISE on failure, which rolls the flip back with
-- the refund. The row returns to its live status and the next closer retries.
-- Double refunds stay impossible via the existing partial unique indexes
-- (wallet_transactions_*_refund_once_idx).

create or replace function public.fail_esim_order_claim(p_order uuid)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $$
declare rec record;
begin
    select user_id, cost_credits, status
      into rec
      from public.esim_orders
     where id = p_order
       for update;

    -- Another closer got there first, or it was never provisioning. Not an error.
    if not found or rec.status <> 'provisioning' then
        return false;
    end if;

    -- 'failed', NOT 'canceled' — esim_status is a different enum from
    -- order_status and 'canceled' is not a member (the 22P02 that once made
    -- every failed eSIM purchase silently keep the money).
    update public.esim_orders
       set status = 'failed', updated_at = now()
     where id = p_order;

    if rec.cost_credits > 0 then
        -- Raises on failure => the flip above rolls back with it.
        perform public.wallet_move_esim(rec.user_id, rec.cost_credits, 'refund', p_order);
    end if;
    return true;
end;
$$;

-- One closer for every email terminal transition. p_status = 'waiting' is
-- legal and means "record a code/provider_status without closing" — the refund
-- branch is unreachable in that case by construction.
create or replace function public.close_email_order_claim(
    p_order uuid,
    p_status public.email_status,
    p_code text default null,
    p_raw text default null,
    p_provider_status text default null
)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $$
declare rec record;
begin
    select user_id, cost_credits, status, code
      into rec
      from public.email_orders
     where id = p_order
       for update;

    if not found or rec.status <> 'waiting' then
        return false;
    end if;

    update public.email_orders
       set status          = p_status,
           code            = coalesce(p_code, code),
           raw_message     = coalesce(p_raw, raw_message),
           provider_status = coalesce(p_provider_status, provider_status),
           closed_at       = case when p_status <> 'waiting' then now() else closed_at end,
           updated_at      = now()
     where id = p_order;

    -- Refund a PAID activation that ended with no code. `code is not null` is
    -- the authority for "a code arrived", never status — the SMS rescue rule.
    if p_status <> 'waiting'
       and coalesce(p_code, rec.code) is null
       and rec.cost_credits > 0 then
        perform public.wallet_move_email(rec.user_id, rec.cost_credits, 'refund', p_order);
    end if;
    return true;
end;
$$;

revoke execute on function public.fail_esim_order_claim(uuid)
  from public, anon, authenticated;
revoke execute on function public.close_email_order_claim(uuid, public.email_status, text, text, text)
  from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- expire_email_orders: the per-row exception handler swallowed a failed
-- refund while the CTE's status flip stayed committed — a plpgsql exception
-- block rolls back only its own subtransaction (the refund), not the outer
-- statement that already claimed the row. Result: a terminal paid row the
-- 5-minute cron never re-selects. The handler now puts the row back to
-- 'waiting' so the next sweep retries; the partial unique refund index makes
-- the eventual success safe. Everything else is byte-identical to
-- 20260731070000 (diffed before applying, per the watchdog-refactor rule).
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.expire_email_orders()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_n integer := 0;
  r record;
begin
  for r in
    with claimed as (
      update public.email_orders
         -- Explicit cast: a CASE yields text, and Postgres will not implicitly
         -- coerce that to email_status in an UPDATE SET. Without it the whole
         -- function raises 42804 on every run.
         set status     = (case when code is not null then 'received' else 'expired' end)::email_status,
             closed_at  = now(),
             updated_at = now()
       where status = 'waiting'                        -- THE atomic claim
         and created_at < now() - interval '22 minutes'
      returning id, user_id, cost_credits, code
    )
    select * from claimed
  loop
    v_n := v_n + 1;
    -- Refund only a PAID order that produced no code. `code is not null` is the
    -- authority for "a code arrived", never status — the same rule the SMS side
    -- had to learn when a rescued code started living on a canceled row.
    if r.cost_credits > 0 and r.code is null then
      begin
        perform public.wallet_move_email(r.user_id, r.cost_credits, 'refund', r.id);
      exception when others then
        -- The subtransaction rollback undoes only the refund; the claim above
        -- is part of the OUTER statement and would commit. Revert the row so
        -- the next 5-minute sweep re-claims and retries — a double refund is
        -- already impossible: wallet_transactions_email_refund_once_idx is a
        -- partial unique on (email_order_id) where reason='refund'.
        update public.email_orders
           set status = 'waiting', closed_at = null, updated_at = now()
         where id = r.id;
        v_n := v_n - 1;
        raise warning 'expire_email_orders: refund failed order=% user=%: % — reverted to waiting',
          r.id, r.user_id, sqlerrm;
      end;
    end if;
  end loop;

  insert into public.app_config (key, value)
  values ('email_expiry_heartbeat', jsonb_build_object('at', now(), 'expired', v_n))
  on conflict (key) do update set value = excluded.value;

  return v_n;
end;
$function$;

revoke execute on function public.expire_email_orders() from public, anon, authenticated;
