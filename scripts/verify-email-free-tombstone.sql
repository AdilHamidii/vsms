-- Behavioural verification of the temp-e-mail free-grant tombstone
-- (`public.email_free_grants`, migration 20260826100000).
--
-- Structural checks prove a table exists. Only a behavioural one proves the
-- gate actually reads it — this repo has shipped an index that was present,
-- correct and unreachable from the code depending on it, and a migration whose
-- function was never called at all.
--
--   psql "$DATABASE_URL" -f scripts/verify-email-free-tombstone.sql
--   supabase db query --linked --file scripts/verify-email-free-tombstone.sql
--
-- 🔴 EVERYTHING RUNS INSIDE A TRANSACTION THAT ROLLS BACK. It creates real
-- auth.users rows, real email_orders and real tombstones and then throws all
-- of it away. Do not "helpfully" change the final `rollback` to `commit`.

begin;

-- Pin the policy this test reasons about, rather than reading whatever the
-- owner has the config set to today (enforced=true, grants=1 as of 08-26).
update public.app_config set value = 'true'::jsonb
 where key = 'email_subscription_enforced';
update public.app_config set value = '1'::jsonb
 where key = 'email_free_lifetime_grants';

do $$
declare
  v_spent  uuid := gen_random_uuid();   -- deleted-and-recreated farmer
  v_fresh  uuid := gen_random_uuid();   -- genuine new user
  v_sub    uuid := gen_random_uuid();   -- subscriber
  v_anon   uuid := gen_random_uuid();   -- no resolvable address
  v_svc    text;
  v_res    jsonb;
  v_rows   integer;
  v_count  integer;
  v_before integer;
begin
  select id into v_svc from public.services order by id limit 1;
  if v_svc is null then raise exception 'SETUP: no services rows to reference'; end if;

  -- ── 1. Tombstone alone refuses, with NO email_orders rows at all ─────────
  -- This IS the bug: the account is brand new, so the per-user count is zero.
  -- Only the mailbox-keyed tombstone can know the allowance is spent.
  insert into auth.users (id, email, email_confirmed_at, created_at, updated_at)
  values (v_spent, 'farmer@icloud.com', now(), now(), now());

  insert into public.email_free_grants
    (email_hash, email_hash_norm, used_count, first_used_at, last_used_at)
  values (md5('farmer@icloud.com'),
          md5(public.normalize_email('farmer@icloud.com')),
          1, now() - interval '30 days', now() - interval '30 days');

  if exists (select 1 from public.email_orders where user_id = v_spent) then
    raise exception 'SETUP: recreated account should have no email_orders';
  end if;

  v_res := public.begin_email_order(v_spent, v_svc, 'google.com', 'outlook.com', 0);
  if v_res->>'reason' is distinct from 'subscription_required' then
    raise exception 'FAIL 1: recreated account re-armed the free address: %', v_res;
  end if;
  if (v_res->>'used')::int < 1 then
    raise exception 'FAIL 1: refusal under-reports used: %', v_res;
  end if;
  raise notice 'PASS 1 delete-and-recreate no longer re-arms the free address (%)', v_res;

  -- ── 2. A genuinely new mailbox is granted, and is tombstoned ─────────────
  insert into auth.users (id, email, email_confirmed_at, created_at, updated_at)
  values (v_fresh, 'Brand.New+tag@gmail.com', now(), now(), now());

  v_res := public.begin_email_order(v_fresh, v_svc, 'google.com', 'outlook.com', 0);
  if coalesce((v_res->>'ok')::boolean, false) is not true then
    raise exception 'FAIL 2: fresh user refused a free address: %', v_res;
  end if;
  select used_count into v_count from public.email_free_grants
   where email_hash_norm = md5(public.normalize_email('brandnew@gmail.com'));
  if v_count is distinct from 1 then
    raise exception 'FAIL 2: tombstone missing or wrong (used_count %)', v_count;
  end if;
  raise notice 'PASS 2 fresh mailbox granted and tombstoned (used_count %)', v_count;

  -- The plus-tag/dot variant of that same mailbox is now walled too — the
  -- normalized key is doing the work the raw hash cannot.
  v_res := public.begin_email_order(v_fresh, v_svc, 'google.com', 'hotmail.com', 0);
  if v_res->>'reason' is distinct from 'subscription_required' then
    raise exception 'FAIL 2b: second free address granted at grants=1: %', v_res;
  end if;
  raise notice 'PASS 2b allowance is spent for that mailbox';

  -- ── 3. A subscriber is not subject to the lifetime gate at all ──────────
  insert into auth.users (id, email, email_confirmed_at, created_at, updated_at)
  values (v_sub, 'paying@outlook.com', now(), now(), now());

  -- Spent long ago, several times over: the lifetime gate would refuse this.
  insert into public.email_free_grants
    (email_hash, email_hash_norm, used_count, first_used_at, last_used_at)
  values (md5('paying@outlook.com'),
          md5(public.normalize_email('paying@outlook.com')),
          9, now() - interval '60 days', now() - interval '1 day');

  perform public.record_email_subscription(
    'verify-tombstone-tx-' || v_sub::text, v_sub,
    'com.anthersystems.VirtualSIM.mail.monthly', 'active'::public.line_sub_state,
    true, 'Production', now() + interval '30 days', 'verify-tombstone-last');
  if not public.has_email_subscription(v_sub) then
    raise exception 'SETUP: subscriber fixture is not entitled';
  end if;

  v_res := public.begin_email_order(v_sub, v_svc, 'google.com', 'outlook.com', 0);
  if coalesce((v_res->>'ok')::boolean, false) is not true then
    raise exception 'FAIL 3: subscriber blocked by the lifetime gate: %', v_res;
  end if;
  select used_count into v_count from public.email_free_grants
   where email_hash = md5('paying@outlook.com');
  if v_count <> 9 then
    raise exception 'FAIL 3: subscriber path touched the tombstone (%)', v_count;
  end if;
  raise notice 'PASS 3 subscriber bypasses the lifetime gate, tombstone untouched';

  -- ── 4. Unresolvable address FAILS OPEN ──────────────────────────────────
  -- Same policy as the other three grants: a missed grant on a legitimate
  -- signup costs more than a rare duplicate. And no tombstone may be written
  -- for an address we cannot key.
  insert into auth.users (id, created_at, updated_at)
  values (v_anon, now(), now());

  select count(*) into v_before from public.email_free_grants;
  v_res := public.begin_email_order(v_anon, v_svc, 'google.com', 'outlook.com', 0);
  if coalesce((v_res->>'ok')::boolean, false) is not true then
    raise exception 'FAIL 4: null-address user refused (should fail open): %', v_res;
  end if;
  select count(*) into v_count from public.email_free_grants;
  if v_count <> v_before then
    raise exception 'FAIL 4: tombstone written for an unkeyable address';
  end if;
  raise notice 'PASS 4 unresolvable address fails open and writes no tombstone';

  -- ── 5. A second grant INCREMENTS, it does not duplicate ─────────────────
  update public.app_config set value = '3'::jsonb
   where key = 'email_free_lifetime_grants';

  v_res := public.begin_email_order(v_fresh, v_svc, 'google.com', 'hotmail.com', 0);
  if coalesce((v_res->>'ok')::boolean, false) is not true then
    raise exception 'FAIL 5: second address refused at grants=3: %', v_res;
  end if;

  select count(*), max(used_count) into v_rows, v_count
    from public.email_free_grants
   where email_hash_norm = md5(public.normalize_email('brandnew@gmail.com'));
  if v_rows <> 1 then
    raise exception 'FAIL 5: % tombstone rows for one mailbox (expected 1)', v_rows;
  end if;
  if v_count <> 2 then
    raise exception 'FAIL 5: used_count is % (expected 2)', v_count;
  end if;
  raise notice 'PASS 5 repeat grant increments one row (used_count %)', v_count;

  -- ── 6. The tombstone must not cascade ───────────────────────────────────
  -- The whole point. A foreign key here would delete the record with the
  -- account and restore the bug silently.
  if exists (select 1 from pg_constraint
              where conrelid = 'public.email_free_grants'::regclass and contype = 'f') then
    raise exception 'FAIL 6: email_free_grants carries a foreign key';
  end if;
  delete from auth.users where id = v_fresh;
  select count(*) into v_rows from public.email_free_grants
   where email_hash_norm = md5(public.normalize_email('brandnew@gmail.com'));
  if v_rows <> 1 then
    raise exception 'FAIL 6: tombstone deleted with the account';
  end if;
  raise notice 'PASS 6 tombstone survives Delete Account';
end;
$$;

rollback;
