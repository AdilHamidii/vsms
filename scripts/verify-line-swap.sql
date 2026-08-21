-- Behavioural verification of the line number swap.
-- Runs inside a transaction that ROLLS BACK: nothing here touches live data.
--
-- The structural checks (functions exist, nothing is client-callable) were run
-- when the migration landed. These prove BEHAVIOUR, which is the only kind of
-- check that has ever caught the failures this repo actually ships: a claim
-- that settles twice, a refund that fires twice, a guard that reads a config
-- key nobody wrote.
--
--   psql "$DATABASE_URL" -f scripts/verify-line-swap.sql
begin;

do $$
declare
  u1 uuid := '8c1d0e11-1111-4111-8111-111111111111';
  u2 uuid := '8c1d0e11-2222-4222-8222-222222222222';
  v_line uuid; v_line2 uuid; v_swap uuid; v_swap2 uuid;
  r jsonb; b boolean; n integer;
  v_bal integer; v_e164 text; v_numid text; v_att boolean;
  v_ledger integer;
begin
  -- ── 0. Test fixtures. Rolled back with everything else. ──────────────────
  insert into auth.users (id, instance_id, aud, role, email,
                          encrypted_password, created_at, updated_at)
  select x.id, '00000000-0000-0000-0000-000000000000', 'authenticated',
         'authenticated', 'swap-check-' || x.id || '@example.invalid',
         '', now(), now()
    from (values (u1), (u2)) as x(id)
  on conflict (id) do nothing;

  insert into public.wallets (user_id, balance) values (u1, 20)
    on conflict (user_id) do update set balance = 20;
  insert into public.wallets (user_id, balance) values (u2, 2)
    on conflict (user_id) do update set balance = 2;

  insert into public.phone_lines (user_id, e164, country_code, number_type,
                                  status, provider_number_id,
                                  provider_connection_id, provider_voice_attached)
  values (u1, '+14165550001', 'CA', 'local', 'active', 'NUM-OLD-1',
          'CONN-1', true)
  returning id into v_line;

  -- ── 1. A swap charges exactly the configured price, once. ────────────────
  r := public.begin_line_swap(u1, v_line);
  if coalesce(r->>'ok','false') <> 'true' then
    raise exception '1a FAILED: begin_line_swap refused: %', r;
  end if;
  if (r->>'credits_charged')::int <> 5 then
    raise exception '1b FAILED: expected 5 credits, got %', r->>'credits_charged';
  end if;
  if (r->>'old_provider_number_id') <> 'NUM-OLD-1' then
    raise exception '1c FAILED: old number id not returned: %', r;
  end if;
  v_swap := (r->>'swap_id')::uuid;

  select balance into v_bal from public.wallets where user_id = u1;
  if v_bal <> 15 then
    raise exception '1d FAILED: balance should be 15, got %', v_bal;
  end if;

  -- ── 2. A second swap on the same line is refused and charges NOTHING. ────
  -- This is the double-tap case. The partial unique index makes it impossible
  -- at the storage layer; this proves the function refuses cleanly rather than
  -- raising a 23505 the client cannot interpret.
  r := public.begin_line_swap(u1, v_line);
  if coalesce(r->>'reason','') <> 'swap_in_progress' then
    raise exception '2a FAILED: expected swap_in_progress, got %', r;
  end if;
  select balance into v_bal from public.wallets where user_id = u1;
  if v_bal <> 15 then
    raise exception '2b FAILED: refused swap moved the balance to %', v_bal;
  end if;

  -- ── 3. The cutover rewrites the line and disarms the voice attach flag. ──
  b := public.complete_line_swap(v_swap, '+14165559999', 'NUM-NEW-1', 'ORD-1');
  if b is not true then
    raise exception '3a FAILED: complete_line_swap returned %', b;
  end if;
  select e164, provider_number_id, provider_voice_attached
    into v_e164, v_numid, v_att
    from public.phone_lines where id = v_line;
  if v_e164 <> '+14165559999' or v_numid <> 'NUM-NEW-1' then
    raise exception '3b FAILED: line not cut over: % / %', v_e164, v_numid;
  end if;
  -- If this stayed true, provisionLineVoice would skip its attach step and the
  -- line would never ring again, silently. It is the whole reason the cutover
  -- touches this column at all.
  if v_att is not false then
    raise exception '3c FAILED: provider_voice_attached should be false, got %', v_att;
  end if;

  -- ── 4. A settled swap cannot be settled again. ───────────────────────────
  -- Settling twice would release a number the user is currently using.
  b := public.complete_line_swap(v_swap, '+14165558888', 'NUM-NEW-2', 'ORD-2');
  if b is not false then
    raise exception '4a FAILED: double cutover returned %', b;
  end if;
  select e164 into v_e164 from public.phone_lines where id = v_line;
  if v_e164 <> '+14165559999' then
    raise exception '4b FAILED: double cutover mutated the line to %', v_e164;
  end if;

  -- ── 5. The old number is queued for release, exactly once. ───────────────
  select count(*) into n from public.swaps_pending_release(50)
   where swap_id = v_swap;
  if n <> 1 then
    raise exception '5a FAILED: swap not pending release (found %)', n;
  end if;

  b := public.mark_swap_old_released(v_swap);
  if b is not true then
    raise exception '5b FAILED: mark_swap_old_released returned %', b;
  end if;

  select count(*) into n from public.swaps_pending_release(50)
   where swap_id = v_swap;
  if n <> 0 then
    raise exception '5c FAILED: swap still pending after release';
  end if;

  b := public.mark_swap_old_released(v_swap);
  if b is not false then
    raise exception '5d FAILED: second release mark returned %', b;
  end if;

  -- ── 6. A failed swap refunds, once and only once. ────────────────────────
  r := public.begin_line_swap(u1, v_line);
  if coalesce(r->>'ok','false') <> 'true' then
    raise exception '6a FAILED: second swap refused: %', r;
  end if;
  v_swap2 := (r->>'swap_id')::uuid;
  select balance into v_bal from public.wallets where user_id = u1;
  if v_bal <> 10 then
    raise exception '6b FAILED: balance should be 10, got %', v_bal;
  end if;

  b := public.fail_line_swap(v_swap2, 'order_TIMEOUT');
  if b is not true then
    raise exception '6c FAILED: fail_line_swap returned %', b;
  end if;
  select balance into v_bal from public.wallets where user_id = u1;
  if v_bal <> 15 then
    raise exception '6d FAILED: refund did not land, balance %', v_bal;
  end if;

  -- The double-refund guard. A retry, a duplicate webhook or a second worker
  -- must not be able to pay the user twice.
  b := public.fail_line_swap(v_swap2, 'order_TIMEOUT');
  if b is not false then
    raise exception '6e FAILED: double fail returned %', b;
  end if;
  select balance into v_bal from public.wallets where user_id = u1;
  if v_bal <> 15 then
    raise exception '6f FAILED: DOUBLE REFUND — balance %', v_bal;
  end if;

  -- ── 7. A line that is not active cannot be swapped, and is not charged. ──
  update public.phone_lines set status = 'suspended' where id = v_line;
  r := public.begin_line_swap(u1, v_line);
  if coalesce(r->>'reason','') <> 'line_not_active' then
    raise exception '7a FAILED: expected line_not_active, got %', r;
  end if;
  select balance into v_bal from public.wallets where user_id = u1;
  if v_bal <> 15 then
    raise exception '7b FAILED: refused swap charged, balance %', v_bal;
  end if;
  update public.phone_lines set status = 'active' where id = v_line;

  -- ── 8. Too few credits refuses BEFORE creating a swap row. ───────────────
  -- A claimed row with no charge behind it would block that line's future
  -- swaps forever via the in-flight index.
  insert into public.phone_lines (user_id, e164, country_code, number_type,
                                  status, provider_number_id)
  values (u2, '+14165550002', 'CA', 'local', 'active', 'NUM-OLD-2')
  returning id into v_line2;

  r := public.begin_line_swap(u2, v_line2);
  if coalesce(r->>'reason','') <> 'insufficient_credits' then
    raise exception '8a FAILED: expected insufficient_credits, got %', r;
  end if;
  if (r->>'shortfall')::int <> 3 then
    raise exception '8b FAILED: shortfall should be 3, got %', r->>'shortfall';
  end if;
  select count(*) into n from public.line_number_swaps where line_id = v_line2;
  if n <> 0 then
    raise exception '8c FAILED: refused swap left % row(s) behind', n;
  end if;
  select balance into v_bal from public.wallets where user_id = u2;
  if v_bal <> 2 then
    raise exception '8d FAILED: refused swap moved u2 balance to %', v_bal;
  end if;

  -- ── 9. Another user cannot swap someone else's line. ─────────────────────
  r := public.begin_line_swap(u2, v_line);
  if coalesce(r->>'reason','') <> 'line_unavailable' then
    raise exception '9a FAILED: cross-user swap not refused: %', r;
  end if;

  -- ── 10. The ledger reconciles with the balance. ──────────────────────────
  -- Two spends of 5 and one refund of 5 = -5 against a start of 20.
  select coalesce(sum(delta), 0) into v_ledger
    from public.wallet_transactions where user_id = u1;
  if v_ledger <> -5 then
    raise exception '10a FAILED: ledger sums to %, expected -5', v_ledger;
  end if;
  select balance into v_bal from public.wallets where user_id = u1;
  if v_bal <> 20 + v_ledger then
    raise exception '10b FAILED: balance % <> 20 + ledger %', v_bal, v_ledger;
  end if;

  raise notice 'ALL SWAP CHECKS PASSED (10 groups)';
end $$;

rollback;
