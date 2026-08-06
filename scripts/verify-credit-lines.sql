-- Behavioural verification of credit-rented lines.
-- Runs inside a transaction that ROLLS BACK: nothing here touches live data.
--
-- Structural checks prove a function exists. These prove it BEHAVES — which is
-- the only thing that has ever caught the real defects in this schema (an index
-- that was present, correct, and unreachable from the code that needed it).
--
-- Every assertion below is about MONEY or about the multi-number requirement.
begin;

do $$
declare
  u1 uuid := '7a1c0de0-0000-4000-8000-000000000001';
  u2 uuid := '7a1c0de0-0000-4000-8000-000000000002';
  r jsonb; b boolean; n integer;
  v_line uuid; v_line2 uuid; v_bal integer; v_delta integer;
  v_period timestamptz;
begin
  -- ── 0. Test users + wallets. ────────────────────────────────────────────
  insert into auth.users (id, instance_id, aud, role, email,
                          encrypted_password, created_at, updated_at)
  select x.id, '00000000-0000-0000-0000-000000000000', 'authenticated',
         'authenticated', 'credit-line-check-' || x.id || '@example.invalid',
         '', now(), now()
    from (values (u1), (u2)) as x(id)
  on conflict (id) do nothing;

  insert into public.wallets (user_id, balance) values (u1, 100), (u2, 5)
  on conflict (user_id) do update set balance = excluded.balance;

  -- ── 1. Renting charges EXACTLY the rent, in one transaction. ────────────
  r := public.begin_credit_line_rental(u1, '+15550100001', 'CA', 'local', 20, 100, 3000);
  if coalesce(r->>'ok','') <> 'true' then
    raise exception '1a FAILED: rental refused: %', r;
  end if;
  v_line := (r->>'line_id')::uuid;

  select balance into v_bal from public.wallets where user_id = u1;
  if v_bal <> 80 then
    raise exception '1b FAILED: expected balance 80 after 20cr rent, got %', v_bal;
  end if;

  -- The ledger row must point AT THE LINE. Without the FK a rent charge is an
  -- unattributed spend and the ledger cannot be reconciled.
  select delta into v_delta from public.wallet_transactions
   where line_id = v_line and reason = 'spend';
  if v_delta is null or v_delta <> -20 then
    raise exception '1c FAILED: expected a -20 spend against the line, got %', v_delta;
  end if;

  -- ── 2. THE REQUIREMENT: a second live line is allowed. ───────────────────
  r := public.begin_credit_line_rental(u1, '+15550100002', 'CA', 'local', 20, 100, 3000);
  if coalesce(r->>'ok','') <> 'true' then
    raise exception '2a FAILED: second concurrent line refused: %', r;
  end if;
  v_line2 := (r->>'line_id')::uuid;

  select count(*) into n from public.phone_lines
   where user_id = u1 and status = 'provisioning';
  if n <> 2 then
    raise exception '2b FAILED: expected 2 live lines, got %', n;
  end if;

  select balance into v_bal from public.wallets where user_id = u1;
  if v_bal <> 60 then
    raise exception '2c FAILED: expected 60 after two rentals, got %', v_bal;
  end if;

  -- ── 3. The per-user cap holds. ──────────────────────────────────────────
  update public.app_config set value = '2'::jsonb where key = 'line_max_per_user';
  r := public.begin_credit_line_rental(u1, '+15550100003', 'CA', 'local', 20, 100, 3000);
  if coalesce(r->>'reason','') <> 'line_limit_reached' then
    raise exception '3a FAILED: cap not enforced, got %', r;
  end if;
  select balance into v_bal from public.wallets where user_id = u1;
  if v_bal <> 60 then
    raise exception '3b FAILED: a refused rental moved money (balance %)', v_bal;
  end if;
  update public.app_config set value = '5'::jsonb where key = 'line_max_per_user';

  -- ── 4. Insufficient credits refuses AND leaves no row and no charge. ────
  r := public.begin_credit_line_rental(u2, '+15550100004', 'CA', 'local', 20, 100, 3000);
  if coalesce(r->>'reason','') <> 'insufficient_credits' then
    raise exception '4a FAILED: expected insufficient_credits, got %', r;
  end if;
  select balance into v_bal from public.wallets where user_id = u2;
  if v_bal <> 5 then
    raise exception '4b FAILED: balance moved on a refused rental: %', v_bal;
  end if;
  select count(*) into n from public.phone_lines where user_id = u2;
  if n <> 0 then
    raise exception '4c FAILED: a refused rental left % phone_lines row(s)', n;
  end if;

  -- ── 5. The monthly debit charges once, and is idempotent. ───────────────
  update public.phone_lines
     set status = 'active', next_debit_at = now() - interval '1 minute'
   where id = v_line;
  -- Park the sibling out of the way so this test observes one line only.
  update public.phone_lines set next_debit_at = now() + interval '30 days'
   where id = v_line2;

  r := public.debit_credit_lines(3);
  if (r->>'charged')::int <> 1 then
    raise exception '5a FAILED: expected 1 charge, got %', r;
  end if;
  select balance into v_bal from public.wallets where user_id = u1;
  if v_bal <> 40 then
    raise exception '5b FAILED: expected 40 after the monthly debit, got %', v_bal;
  end if;

  -- Running again immediately must charge nothing: next_debit_at moved forward,
  -- and the tombstone would stop it even if it had not.
  r := public.debit_credit_lines(3);
  if (r->>'charged')::int <> 0 then
    raise exception '5c FAILED: a second sweep charged again: %', r;
  end if;
  select balance into v_bal from public.wallets where user_id = u1;
  if v_bal <> 40 then
    raise exception '5d FAILED: double charge, balance %', v_bal;
  end if;

  -- The tombstone blocks a replay for a period already collected, even when
  -- the line looks due. This is the guard that survives a cron misfire — and
  -- it is keyed on next_debit_at (the PERIOD), not on the instant of charging,
  -- because `now()` is constant within a transaction and the two collided.
  v_period := now() - interval '1 minute';
  update public.phone_lines set next_debit_at = v_period where id = v_line;
  insert into public.line_rent_charges (line_id, period_start, credits)
  values (v_line, v_period, 20) on conflict do nothing;
  select balance into v_bal from public.wallets where user_id = u1;
  r := public.debit_credit_lines(3);
  if (r->>'charged')::int <> 0 then
    raise exception '5e FAILED: tombstone did not prevent a collected-period recharge: %', r;
  end if;
  if (select balance from public.wallets where user_id = u1) <> v_bal then
    raise exception '5f FAILED: money moved despite the period tombstone';
  end if;

  -- ── 6. A failed debit opens grace and records NO charge. ────────────────
  update public.wallets set balance = 3 where user_id = u1;
  update public.phone_lines
     set status = 'active', next_debit_at = now() - interval '1 minute',
         grace_until = null
   where id = v_line;
  delete from public.line_rent_charges where line_id = v_line;

  r := public.debit_credit_lines(3);
  if (r->>'grace')::int <> 1 then
    raise exception '6a FAILED: expected 1 line in grace, got %', r;
  end if;
  if (select status from public.phone_lines where id = v_line) <> 'grace' then
    raise exception '6b FAILED: line not in grace';
  end if;
  select balance into v_bal from public.wallets where user_id = u1;
  if v_bal <> 3 then
    raise exception '6c FAILED: a failed debit moved money, balance %', v_bal;
  end if;
  -- 🔴 The one that matters: an UNPAID month must not be recorded as collected.
  select count(*) into n from public.line_rent_charges where line_id = v_line;
  if n <> 0 then
    raise exception '6d FAILED: unpaid month left % tombstone row(s) — it would never be retried', n;
  end if;
  -- Retried daily, not monthly.
  if (select next_debit_at from public.phone_lines where id = v_line)
       > now() + interval '2 days' then
    raise exception '6e FAILED: grace retry is not daily';
  end if;

  -- ── 7. Grace expiry hands the line to the release path. ─────────────────
  update public.phone_lines
     set grace_until = now() - interval '1 hour'
   where id = v_line;
  perform public.debit_credit_lines(3);
  if (select status from public.phone_lines where id = v_line) <> 'releasing' then
    raise exception '7a FAILED: expired grace did not move the line to releasing (got %)',
      (select status from public.phone_lines where id = v_line);
  end if;

  -- ── 8. Refunding a failed provision returns exactly the rent. ───────────
  update public.wallets set balance = 0 where user_id = u1;
  update public.phone_lines set status = 'provisioning' where id = v_line2;
  b := public.refund_credit_line_claim(v_line2);
  if not b then raise exception '8a FAILED: refund refused'; end if;
  select balance into v_bal from public.wallets where user_id = u1;
  if v_bal <> 20 then
    raise exception '8b FAILED: expected 20 refunded, balance %', v_bal;
  end if;
  if (select status from public.phone_lines where id = v_line2) <> 'failed' then
    raise exception '8c FAILED: refunded line not marked failed';
  end if;
  select count(*) into n from public.line_rent_charges where line_id = v_line2;
  if n <> 0 then
    raise exception '8d FAILED: refund left the tombstone, blocking a legitimate retry';
  end if;

  -- ── 9. Apple lines are STILL capped at one. ─────────────────────────────
  -- Lifting the limit for credits must not lift Apple's own constraint, which
  -- is a real App Store rule rather than one of ours.
  insert into public.phone_lines (user_id, e164, country_code, number_type,
                                  status, billing, original_transaction_id)
  values (u2, '+15550100010', 'CA', 'local', 'active', 'apple', 'TX-APPLE-1');
  begin
    insert into public.phone_lines (user_id, e164, country_code, number_type,
                                    status, billing, original_transaction_id)
    values (u2, '+15550100011', 'CA', 'local', 'active', 'apple', 'TX-APPLE-2');
    raise exception '9a FAILED: a SECOND Apple-billed line was accepted';
  exception when unique_violation then
    null; -- expected
  end;

  -- ...while a credit line alongside an Apple line is fine.
  update public.wallets set balance = 50 where user_id = u2;
  r := public.begin_credit_line_rental(u2, '+15550100012', 'CA', 'local', 20, 100, 3000);
  if coalesce(r->>'ok','') <> 'true' then
    raise exception '9b FAILED: credit line refused alongside an Apple line: %', r;
  end if;

  raise notice 'ALL CREDIT-LINE CHECKS PASSED';
end $$;

rollback;
