begin;

-- Pay something, so the grant path is actually exercised (live value is 0).
update public.app_config set value = '{"credits":3}'::jsonb
 where key = 'signup_bonus_credits';

do $$
declare
  v_apple uuid := gen_random_uuid();
  v_mail  uuid := gen_random_uuid();
  v_tag   uuid := gen_random_uuid();
  v_bal   integer;
  v_rows  integer;
  v_before integer;
begin
  select count(*) into v_before from public.signup_grants;

  -- ── 1. Apple-shaped signup: arrives ALREADY CONFIRMED, paid at INSERT ─────
  insert into auth.users (id, email, email_confirmed_at, created_at, updated_at)
  values (v_apple, 'relayhex1@privaterelay.appleid.com', now(), now(), now());

  select balance into v_bal from public.wallets where user_id = v_apple;
  if v_bal is distinct from 3 then
    raise exception 'FAIL apple: expected balance 3, got %', v_bal;
  end if;
  select count(*) into v_rows from public.wallet_transactions
   where user_id = v_apple and reason = 'signup_bonus';
  if v_rows <> 1 then raise exception 'FAIL apple: % ledger rows', v_rows; end if;
  raise notice 'PASS apple signup paid at insert (balance %)', v_bal;

  -- ── 2. Email signup: UNCONFIRMED, wallet exists at zero, nothing paid ─────
  insert into auth.users (id, email, created_at, updated_at)
  values (v_mail, 'Test.User+alpha@gmail.com', now(), now());

  select balance into v_bal from public.wallets where user_id = v_mail;
  if v_bal is distinct from 0 then
    raise exception 'FAIL unconfirmed: expected balance 0, got %', v_bal;
  end if;
  if exists (select 1 from public.wallet_transactions
              where user_id = v_mail and reason = 'signup_bonus') then
    raise exception 'FAIL unconfirmed: grant paid before confirmation';
  end if;
  raise notice 'PASS unconfirmed email signup pays nothing, wallet exists at 0';

  -- ── 3. Confirm it: paid exactly once ─────────────────────────────────────
  update auth.users set email_confirmed_at = now() where id = v_mail;

  select balance into v_bal from public.wallets where user_id = v_mail;
  if v_bal is distinct from 3 then
    raise exception 'FAIL confirm: expected balance 3, got %', v_bal;
  end if;
  select count(*) into v_rows from public.wallet_transactions
   where user_id = v_mail and reason = 'signup_bonus';
  if v_rows <> 1 then raise exception 'FAIL confirm: % ledger rows', v_rows; end if;
  raise notice 'PASS confirmation pays the grant once (balance %)', v_bal;

  -- ── 4. Any later UPDATE must not re-fire (GoTrue writes on every sign-in) ─
  update auth.users set last_sign_in_at = now() where id = v_mail;
  update auth.users set email_confirmed_at = now() where id = v_mail;
  select balance into v_bal from public.wallets where user_id = v_mail;
  if v_bal is distinct from 3 then
    raise exception 'FAIL re-fire: balance moved to % on a later update', v_bal;
  end if;
  raise notice 'PASS later updates do not re-grant';

  -- ── 5. Same mailbox, different plus-tag and dots: NOT paid again ─────────
  insert into auth.users (id, email, email_confirmed_at, created_at, updated_at)
  values (v_tag, 'testuser+beta@googlemail.com', now(), now(), now());

  select balance into v_bal from public.wallets where user_id = v_tag;
  if v_bal is distinct from 0 then
    raise exception 'FAIL plus-tag: farmed % credits from the same mailbox', v_bal;
  end if;
  raise notice 'PASS plus-tag/dot variant of the same mailbox is refused';

  -- ── 6. Exactly one new tombstone across all three users ─────────────────
  select count(*) - v_before into v_rows from public.signup_grants;
  if v_rows <> 2 then
    raise exception 'FAIL tombstones: expected 2 new (apple + gmail), got %', v_rows;
  end if;
  raise notice 'PASS tombstone count';

  -- ── 7. The replay attempt was counted ───────────────────────────────────
  select grant_count into v_rows from public.signup_grants
   where email_hash_norm = md5(public.normalize_email('testuser@gmail.com'));
  if v_rows < 2 then
    raise exception 'FAIL grant_count: replay not counted (got %)', v_rows;
  end if;
  raise notice 'PASS replay attempt counted (grant_count %)', v_rows;
end;
$$;

rollback;
