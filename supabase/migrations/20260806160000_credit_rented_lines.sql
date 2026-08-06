-- Rent numbers with CREDITS instead of a StoreKit subscription.
--
-- WHY, because it reverses a design rule this repo states explicitly ("the line
-- NEVER touches the credit wallet"): the requirement is now that a user can
-- rent SEVERAL numbers at once, and Apple cannot express that. One active
-- subscription per group, and `quantity` applies only to consumables — so 3×
-- line.monthly is not purchasable at any price. Credits have no such
-- constraint: three numbers is simply 60 credits a month.
--
-- The rule existed to keep this line clear of the claim/refund bugs that have
-- hit every other line. That protection is not abandoned, it is re-implemented:
-- every money move below is ONE transaction with its state change, the monthly
-- debit is tombstoned against replay, and the ledger gets a real FK.
--
-- Apple billing is NOT removed. `billing` distinguishes the two, the existing
-- subscription state machine keeps working untouched for any line already on
-- it, and the one-per-user rule is narrowed to Apple lines, where it is a real
-- Apple constraint rather than our own.
--
-- Pricing (owner decision 2026-08-06): 20 credits/month for 100 SMS + 50
-- minutes. A credit nets $0.397 blended, so 20 credits ≈ $7.94/month against
-- ~$1 rent + ~$2.15 worst-case usage. The smaller allowance is deliberate:
-- credits are cheaper in bulk, so a 150-pack buyer nets only ~$6.80 and the
-- full 200/100 allowance would leave ~$1.50.

-- ── 1. The ledger FK. ──────────────────────────────────────────────────────
-- Every other product line has one (order_id / esim_order_id / email_order_id)
-- and CLAUDE.md names this as a precondition for the line ever touching the
-- wallet. Without it a rent charge is an unattributed `spend` and the ledger
-- cannot be reconciled against what was actually rented.
--
-- SET NULL, never CASCADE: a released line must not delete the record of money
-- that genuinely moved. The ledger is the audit trail; it outlives its subject.
alter table public.wallet_transactions
  add column if not exists line_id uuid references public.phone_lines(id) on delete set null;

create index if not exists wallet_transactions_line_idx
  on public.wallet_transactions (line_id) where line_id is not null;

-- ── 2. Billing mode on the line. ───────────────────────────────────────────
alter table public.phone_lines
  add column if not exists billing text not null default 'apple'
    check (billing in ('apple', 'credits'));
alter table public.phone_lines
  add column if not exists rent_credits integer
    check (rent_credits is null or rent_credits > 0);
-- When the next month's rent comes due. NULL for Apple lines, which are driven
-- by App Store Server Notifications instead.
alter table public.phone_lines
  add column if not exists next_debit_at timestamptz;

create index if not exists phone_lines_due_idx
  on public.phone_lines (next_debit_at)
  where billing = 'credits' and next_debit_at is not null;

-- ── 3. One-per-user becomes one-APPLE-per-user. ────────────────────────────
-- The old index barred a second line outright. That is correct for Apple (one
-- active subscription per group is Apple's rule, not ours) and is exactly the
-- constraint being lifted for credits.
drop index if exists public.phone_lines_one_live_per_user;

create unique index if not exists phone_lines_one_apple_line_per_user
  on public.phone_lines (user_id)
  where billing = 'apple'
    and status in ('provisioning','active','grace','past_due','suspended','releasing');

-- How many credit-rented lines one user may hold at once. A cap exists because
-- every live line is $1/month of OUR float carried ahead of any revenue, and an
-- account that rents fifty is a funding event, not a customer.
insert into public.app_config (key, value)
values ('line_max_per_user', '5'::jsonb)
on conflict (key) do nothing;

-- ── 4. The monthly-debit tombstone. ────────────────────────────────────────
-- The idempotency guard for rent. Without it a cron that runs twice, or a
-- retried sweep, charges the same month twice — and unlike a failed order there
-- is nothing a user can point at to notice it.
create table if not exists public.line_rent_charges (
  line_id       uuid not null references public.phone_lines(id) on delete cascade,
  period_start  timestamptz not null,
  credits       integer not null check (credits > 0),
  charged_at    timestamptz not null default now(),
  primary key (line_id, period_start)
);

alter table public.line_rent_charges enable row level security;
revoke all on public.line_rent_charges from anon, authenticated;

-- ── 5. Ledger movers, mirroring wallet_move_email / wallet_move_esim. ──────
create or replace function public.wallet_move_line(
  p_user uuid, p_amount integer, p_reason public.wallet_reason, p_line uuid
) returns boolean
language plpgsql security definer set search_path to 'public' as $fn$
declare v_id bigint;
begin
  if p_amount is null or p_amount <= 0 then
    raise exception 'wallet_move_line: amount must be positive, got %', p_amount;
  end if;

  update public.wallets set balance = balance + p_amount
   where user_id = p_user
  returning 1 into v_id;
  if v_id is null then
    raise exception 'wallet_move_line: no wallet for user %', p_user;
  end if;

  insert into public.wallet_transactions (user_id, delta, reason, line_id)
  values (p_user, p_amount, p_reason, p_line);
  return true;
end $fn$;

revoke execute on function public.wallet_move_line(uuid, integer, public.wallet_reason, uuid)
  from public, anon, authenticated;

-- The spend half. Returns FALSE on insufficient funds rather than raising:
-- running out of credits is an ordinary, expected outcome for a recurring
-- charge (it is what starts the grace period), not an error condition. Raising
-- would abort the whole sweep and take every other line's debit down with it.
create or replace function public.wallet_spend_line(
  p_user uuid, p_amount integer, p_line uuid
) returns boolean
language plpgsql security definer set search_path to 'public' as $fn$
declare v_bal integer;
begin
  if p_amount is null or p_amount <= 0 then
    raise exception 'wallet_spend_line: amount must be positive, got %', p_amount;
  end if;

  -- Locked, so two concurrent debits cannot both read the same balance.
  select balance into v_bal from public.wallets where user_id = p_user for update;
  if v_bal is null then
    raise exception 'wallet_spend_line: no wallet for user %', p_user;
  end if;
  if v_bal < p_amount then
    return false;
  end if;

  update public.wallets set balance = balance - p_amount where user_id = p_user;
  insert into public.wallet_transactions (user_id, delta, reason, line_id)
  values (p_user, -p_amount, 'spend', p_line);
  return true;
end $fn$;

revoke execute on function public.wallet_spend_line(uuid, integer, uuid)
  from public, anon, authenticated;

-- ── 6. Renting. Charge and row in ONE transaction. ─────────────────────────
-- The ordering rule this repo rewrote begin_order for: the row exists before
-- any provider call, so a Telnyx failure can never leave a purchased number
-- with nothing pointing at it. And the charge commits with it, so there is no
-- window where money moved and no line explains it.
create or replace function public.begin_credit_line_rental(
  p_user uuid, p_e164 text, p_country text, p_number_type text,
  p_rent_credits integer default 20,
  p_sms_allowance integer default 100,
  p_voice_allowance_seconds integer default 3000
) returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_line uuid;
  v_live integer;
  v_cap integer;
  v_paused boolean;
begin
  if p_user is null or p_e164 is null or p_country is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;
  if p_rent_credits is null or p_rent_credits <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  select coalesce((value #>> '{}')::boolean, false) into v_paused
    from public.app_config where key = 'lines_paused';
  if coalesce(v_paused, false) then
    return jsonb_build_object('ok', false, 'reason', 'lines_paused');
  end if;

  -- Serialise per user, exactly as begin_order / begin_esim_order do. The cap
  -- check below is only meaningful under this lock: without it two concurrent
  -- requests both count N-1 and both insert.
  perform pg_advisory_xact_lock(hashtext(p_user::text));

  select coalesce((value #>> '{}')::integer, 5) into v_cap
    from public.app_config where key = 'line_max_per_user';

  select count(*) into v_live from public.phone_lines
   where user_id = p_user
     and status in ('provisioning','active','grace','past_due','suspended','releasing');
  if v_live >= coalesce(v_cap, 5) then
    return jsonb_build_object('ok', false, 'reason', 'line_limit_reached',
                              'limit', coalesce(v_cap, 5));
  end if;

  insert into public.phone_lines (
    user_id, e164, country_code, number_type, status, billing,
    rent_credits, sms_allowance, voice_allowance_seconds,
    allowance_period_start, current_period_start, current_period_end,
    next_debit_at)
  values (
    p_user, p_e164, p_country, coalesce(p_number_type, 'local'), 'provisioning',
    'credits', p_rent_credits, p_sms_allowance, p_voice_allowance_seconds,
    now(), now(), now() + interval '30 days', now() + interval '30 days')
  returning id into v_line;

  -- Charged AFTER the row exists so the ledger FK can point at it, and in the
  -- same transaction so neither can survive without the other. A false return
  -- rolls the insert back with it.
  if not public.wallet_spend_line(p_user, p_rent_credits, v_line) then
    raise exception using
      errcode = 'P0001',
      message = 'insufficient_credits';
  end if;

  insert into public.line_rent_charges (line_id, period_start, credits)
  values (v_line, date_trunc('second', now()), p_rent_credits);

  return jsonb_build_object('ok', true, 'line_id', v_line,
                            'rent_credits', p_rent_credits);
exception
  when sqlstate 'P0001' then
    if sqlerrm = 'insufficient_credits' then
      return jsonb_build_object('ok', false, 'reason', 'insufficient_credits');
    end if;
    raise;
end $fn$;

revoke execute on function public.begin_credit_line_rental(uuid, text, text, text, integer, integer, integer)
  from public, anon, authenticated;

-- ── 7. Refund a rental whose provisioning failed. ──────────────────────────
-- One transaction: the status flip and the money move together, the rule seven
-- other close paths had to be rewritten for. The tombstone row is deleted so a
-- retry can charge again legitimately.
create or replace function public.refund_credit_line_claim(p_line uuid)
returns boolean
language plpgsql security definer set search_path to 'public' as $fn$
declare rec record;
begin
  select id, user_id, rent_credits, status, billing
    into rec
    from public.phone_lines
   where id = p_line
     for update;

  if not found or rec.billing <> 'credits' then return false; end if;
  -- Only a line that never came up is refundable here. A live line's rent is
  -- spent; that is what renting means.
  if rec.status not in ('provisioning','failed') then return false; end if;

  delete from public.line_rent_charges where line_id = p_line;

  update public.phone_lines
     set status = 'failed', updated_at = now()
   where id = p_line;

  if rec.rent_credits is not null and rec.rent_credits > 0 then
    perform public.wallet_move_line(rec.user_id, rec.rent_credits, 'refund', p_line);
  end if;
  return true;
end $fn$;

revoke execute on function public.refund_credit_line_claim(uuid)
  from public, anon, authenticated;

-- ── 8. The monthly sweep. PURE SQL, on pg_cron. ────────────────────────────
-- Deliberately not an edge function: this is the only thing that collects rent,
-- and it must keep running when the edge layer is down — the same reasoning
-- that keeps run_watchdog and reclaim_lapsed_lines in SQL. It calls no
-- provider, so it cannot fail on a network hop.
--
-- Insufficient credits is NOT an error: it starts the grace period. The user
-- keeps the number and inbound keeps working while they top up, then
-- reclaim_lapsed_lines releases it through the existing suspend → hold →
-- release path once grace expires.
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
    select id, user_id, rent_credits, status
      from public.phone_lines
     where billing = 'credits'
       and status in ('active','grace')
       and next_debit_at is not null
       and next_debit_at <= now()
     order by next_debit_at
     limit 500
     for update skip locked
  loop
    v_period := date_trunc('second', now());

    -- The tombstone IS the idempotency check, claimed BEFORE the money moves.
    -- A second sweep in the same period finds the row and charges nothing.
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
  -- `releasing` is what release-lines drains, and reclaim_lapsed_lines already
  -- watches for rows stuck in it.
  update public.phone_lines
     set status = 'releasing', updated_at = now()
   where billing = 'credits'
     and status = 'grace'
     and grace_until is not null
     and grace_until < now();

  -- The watchdog heartbeat. "Nothing was due" and "this job stopped running"
  -- must not look the same.
  insert into public.app_config (key, value)
  values ('line_rent_heartbeat', to_jsonb(now()))
  on conflict (key) do update set value = excluded.value;

  return jsonb_build_object('charged', v_charged, 'grace', v_grace);
end $fn$;

revoke execute on function public.debit_credit_lines(integer)
  from public, anon, authenticated;

-- ── 9. Assertions. ─────────────────────────────────────────────────────────
do $$
begin
  if has_function_privilege('anon', 'public.begin_credit_line_rental(uuid, text, text, text, integer, integer, integer)', 'execute')
     or has_function_privilege('authenticated', 'public.wallet_spend_line(uuid, integer, uuid)', 'execute')
     or has_function_privilege('anon', 'public.debit_credit_lines(integer)', 'execute') then
    raise exception 'credit-line functions are reachable from a client role';
  end if;

  if exists (select 1 from pg_indexes where indexname = 'phone_lines_one_live_per_user') then
    raise exception 'the blanket one-line-per-user index still exists; multi-number cannot work';
  end if;

  if not exists (select 1 from pg_indexes where indexname = 'phone_lines_one_apple_line_per_user') then
    raise exception 'the Apple one-line-per-user guard was dropped without a replacement';
  end if;
end $$;
