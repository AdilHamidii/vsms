-- The rent tombstone must key on the PERIOD, not on the instant of charging.
--
-- 20260806160000 used `date_trunc('second', now())`. `now()` is the transaction
-- timestamp and therefore CONSTANT within a transaction, so the initial rental
-- charge and a sweep running in the same transaction-second produced the same
-- key: the sweep hit a unique_violation, took its `continue`, and silently
-- charged nothing. Caught by scripts/verify-credit-lines.sql check 5a on the
-- first run — a structural check could not have seen it, because the table and
-- the constraint were both exactly right.
--
-- In production the rental and the first sweep are 30 days apart, so this would
-- not have fired for a month. It would then have fired as "rent was silently
-- not collected", which is the worst possible shape: revenue quietly missing
-- with the tombstone claiming it was billed.
--
-- The fix is to key on `next_debit_at` — the identity of the period being paid
-- for. It is stable, distinct per period, does not move until a charge
-- succeeds, and cannot collide with the initial rental (whose key is the
-- period start, 30 days earlier).

create or replace function public.debit_credit_lines(p_grace_days integer default 3)
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_line record;
  v_charged integer := 0;
  v_grace integer := 0;
  v_period timestamptz;
begin
  for v_line in
    select id, user_id, rent_credits, status, next_debit_at
      from public.phone_lines
     where billing = 'credits'
       and status in ('active','grace')
       and next_debit_at is not null
       and next_debit_at <= now()
     order by next_debit_at
     limit 500
     for update skip locked
  loop
    -- THE PERIOD BEING PAID FOR, not the moment we happen to be paying. See
    -- the header: `now()` is constant per transaction and collided.
    v_period := v_line.next_debit_at;

    -- The tombstone IS the idempotency check, claimed BEFORE the money moves.
    -- A second sweep for the same period finds the row and charges nothing.
    begin
      insert into public.line_rent_charges (line_id, period_start, credits)
      values (v_line.id, v_period, v_line.rent_credits);
    exception when unique_violation then
      continue;
    end;

    if public.wallet_spend_line(v_line.user_id, v_line.rent_credits, v_line.id) then
      update public.phone_lines
         set status = 'active',
             current_period_start = now(),
             current_period_end = now() + interval '30 days',
             next_debit_at = now() + interval '30 days',
             grace_until = null,
             -- A paid month is a new period, so the meter resets. Same rule as
             -- apply_line_renewal: only a genuinely new period earns a new
             -- allowance.
             allowance_period_start = now(),
             sms_used = 0,
             voice_used_seconds = 0,
             updated_at = now()
       where id = v_line.id;
      v_charged := v_charged + 1;
    else
      -- Could not pay. Roll the tombstone back so the retry inside grace can
      -- charge for this same period — leaving it would silently mark an unpaid
      -- month as collected.
      delete from public.line_rent_charges
       where line_id = v_line.id and period_start = v_period;

      update public.phone_lines
         set status = 'grace',
             grace_until = coalesce(grace_until,
                                    now() + make_interval(days => greatest(coalesce(p_grace_days, 3), 1))),
             -- Retried daily while in grace rather than waiting a month.
             next_debit_at = now() + interval '1 day',
             updated_at = now()
       where id = v_line.id;
      v_grace := v_grace + 1;
    end if;
  end loop;

  -- Grace expired with no payment: hand the line to the existing release path.
  update public.phone_lines
     set status = 'releasing', updated_at = now()
   where billing = 'credits'
     and status = 'grace'
     and grace_until is not null
     and grace_until < now();

  insert into public.app_config (key, value)
  values ('line_rent_heartbeat', to_jsonb(now()))
  on conflict (key) do update set value = excluded.value;

  return jsonb_build_object('charged', v_charged, 'grace', v_grace);
end $fn$;

revoke execute on function public.debit_credit_lines(integer)
  from public, anon, authenticated;
