-- Behavioural checks for migration 20260901100000: the signup domain block,
-- the device-keyed free-e-mail tombstone and the per-IP daily cap.
--
--   supabase db query --linked --file scripts/verify-signup-block-free-email-keys.sql
--
-- 🔴 EVERYTHING RUNS INSIDE A TRANSACTION THAT ROLLS BACK. It inserts real
-- auth.users rows, push tokens and email_orders and throws all of it away.
-- Expect a single 'ALL CHECKS PASSED' notice; any failure raises.

begin;

update public.app_config set value = 'true'::jsonb where key = 'email_subscription_enforced';
update public.app_config set value = '1'::jsonb    where key = 'email_free_lifetime_grants';
update public.app_config set value = '3'::jsonb    where key = 'email_free_ip_daily_cap';

do $$
declare
  v_svc  text;
  v_res  jsonb;
  v_a    uuid := gen_random_uuid();
  v_b    uuid := gen_random_uuid();
  v_c    uuid := gen_random_uuid();
  v_d    uuid := gen_random_uuid();
  v_e    uuid := gen_random_uuid();
  v_f    uuid := gen_random_uuid();
  v_tok  text := 'verify-shared-token-' || gen_random_uuid()::text;
  v_ip   text := 'verify-ip-' || gen_random_uuid()::text;
  v_raised boolean;
begin
  select id into v_svc from public.services order by id limit 1;

  -- ── 1. Blocked domain cannot sign up ──────────────────────────────────────
  v_raised := false;
  begin
    insert into auth.users (id, email, email_confirmed_at, created_at, updated_at)
    values (gen_random_uuid(), 'farm1@utiluan.com', now(), now(), now());
  exception when others then
    v_raised := sqlerrm like '%signup_blocked_domain%';
  end;
  if not v_raised then raise exception 'FAIL 1: utiluan.com signup was accepted'; end if;
  raise notice 'PASS 1 blocked domain refused at signup';

  -- ── 2. Subdomain of a blocked domain is refused too ──────────────────────
  v_raised := false;
  begin
    insert into auth.users (id, email, email_confirmed_at, created_at, updated_at)
    values (gen_random_uuid(), 'farm2@bd.5secmail.com', now(), now(), now());
  exception when others then
    v_raised := sqlerrm like '%signup_blocked_domain%';
  end;
  if not v_raised then raise exception 'FAIL 2: subdomain signup was accepted'; end if;
  raise notice 'PASS 2 subdomain of blocked domain refused';

  -- ── 3. A mainstream address signs up normally ────────────────────────────
  insert into auth.users (id, email, email_confirmed_at, created_at, updated_at)
  values (v_a, 'real.person.' || v_a::text || '@gmail.com', now(), now(), now());
  raise notice 'PASS 3 mainstream domain accepted';

  -- ── 4. Device key: a second mailbox on the SAME phone is refused ─────────
  insert into public.push_devices (user_id, token, environment, bundle_id)
  values (v_a, v_tok, 'production', 'com.anthersystems.VirtualSIM');

  v_res := public.begin_email_order(v_a, v_svc, 'facebook.com', 'outlook.com', 0);
  if coalesce((v_res->>'ok')::boolean, false) is not true then
    raise exception 'FAIL 4a: first free address on a fresh phone refused: %', v_res;
  end if;
  if (select used_count from public.free_email_device_grants where token_hash = md5(v_tok)) is distinct from 1 then
    raise exception 'FAIL 4a: device tombstone not written';
  end if;

  insert into auth.users (id, email, email_confirmed_at, created_at, updated_at)
  values (v_b, 'another.' || v_b::text || '@gmail.com', now(), now(), now());
  insert into public.push_devices (user_id, token, environment, bundle_id)
  values (v_b, v_tok, 'production', 'com.anthersystems.VirtualSIM');

  v_res := public.begin_email_order(v_b, v_svc, 'facebook.com', 'outlook.com', 0);
  if v_res->>'reason' is distinct from 'subscription_required' then
    raise exception 'FAIL 4b: new mailbox on a spent phone got a free address: %', v_res;
  end if;
  raise notice 'PASS 4 one free address per device (%)', v_res;

  -- ── 5. A fresh phone AND fresh mailbox is still granted ──────────────────
  insert into auth.users (id, email, email_confirmed_at, created_at, updated_at)
  values (v_c, 'third.' || v_c::text || '@gmail.com', now(), now(), now());
  insert into public.push_devices (user_id, token, environment, bundle_id)
  values (v_c, 'verify-fresh-token-' || v_c::text, 'production', 'com.anthersystems.VirtualSIM');
  v_res := public.begin_email_order(v_c, v_svc, 'facebook.com', 'outlook.com', 0);
  if coalesce((v_res->>'ok')::boolean, false) is not true then
    raise exception 'FAIL 5: genuine new user refused: %', v_res;
  end if;
  raise notice 'PASS 5 fresh phone + fresh mailbox granted';

  -- ── 6. IP cap: 3 free addresses per IP per day, the 4th is refused ───────
  -- Three distinct users, three distinct phones, one IP.
  insert into auth.users (id, email, email_confirmed_at, created_at, updated_at) values
    (v_d, 'ip1.' || v_d::text || '@gmail.com', now(), now(), now()),
    (v_e, 'ip2.' || v_e::text || '@gmail.com', now(), now(), now()),
    (v_f, 'ip3.' || v_f::text || '@gmail.com', now(), now(), now());
  v_res := public.begin_email_order(v_d, v_svc, 'facebook.com', 'outlook.com', 0, v_ip);
  if coalesce((v_res->>'ok')::boolean, false) is not true then raise exception 'FAIL 6a: %', v_res; end if;
  v_res := public.begin_email_order(v_e, v_svc, 'facebook.com', 'outlook.com', 0, v_ip);
  if coalesce((v_res->>'ok')::boolean, false) is not true then raise exception 'FAIL 6b: %', v_res; end if;
  v_res := public.begin_email_order(v_f, v_svc, 'facebook.com', 'outlook.com', 0, v_ip);
  if coalesce((v_res->>'ok')::boolean, false) is not true then raise exception 'FAIL 6c: %', v_res; end if;
  if (select used_count from public.free_email_ip_grants where ip_hash = v_ip and day = (now() at time zone 'utc')::date) is distinct from 3 then
    raise exception 'FAIL 6: ip counter is not 3';
  end if;

  -- A 4th genuine-looking user from the same IP.
  v_a := gen_random_uuid();
  insert into auth.users (id, email, email_confirmed_at, created_at, updated_at)
  values (v_a, 'ip4.' || v_a::text || '@gmail.com', now(), now(), now());
  v_res := public.begin_email_order(v_a, v_svc, 'facebook.com', 'outlook.com', 0, v_ip);
  if v_res->>'reason' is distinct from 'ip_limit_reached' then
    raise exception 'FAIL 6d: 4th free address from one IP granted: %', v_res;
  end if;
  raise notice 'PASS 6 IP cap refuses the 4th free address (%)', v_res;

  -- ── 7. A subscriber is never IP-capped ───────────────────────────────────
  v_b := gen_random_uuid();
  insert into auth.users (id, email, email_confirmed_at, created_at, updated_at)
  values (v_b, 'sub.' || v_b::text || '@gmail.com', now(), now(), now());
  perform public.record_email_subscription(
    'verify-ipcap-tx-' || v_b::text, v_b,
    'com.anthersystems.VirtualSIM.mail.monthly', 'active'::public.line_sub_state,
    true, 'Production', now() + interval '30 days', 'verify-ipcap-last');
  v_res := public.begin_email_order(v_b, v_svc, 'facebook.com', 'outlook.com', 0, v_ip);
  if coalesce((v_res->>'ok')::boolean, false) is not true then
    raise exception 'FAIL 7: subscriber was IP-capped: %', v_res;
  end if;
  raise notice 'PASS 7 subscriber unaffected by the IP cap';

  raise notice 'ALL CHECKS PASSED';
end $$;

rollback;
