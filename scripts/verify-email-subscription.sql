-- Behavioural checks for the e-mail subscription entitlement.
-- Run: supabase db query --linked --file scripts/verify-email-subscription.sql
-- Everything happens inside a transaction that is rolled back at the end, so
-- none of the app_config writes below (including flipping the enforcement
-- flag to true) ever reach production.
begin;

do $$
declare
  v_user uuid := '00000000-0000-0000-0000-0000000000e1';
  v_res  jsonb;
  v_cap  integer;
begin
  -- ── 0a. Provision the test users. ─────────────────────────────────────────
  -- `wallets.user_id` and `email_subscriptions.user_id`-adjacent fixtures are
  -- not FK-constrained the same way `wallets` is: `wallets_user_id_fkey`
  -- requires the row to exist in `auth.users` first, or the very first insert
  -- below dies with a bare 23503 before any check runs. Same pattern as
  -- `scripts/verify-line-lifecycle.sql`. Only the columns auth.users actually
  -- requires are set; `on conflict do nothing` keeps this rerunnable.
  insert into auth.users (id, instance_id, aud, role, email,
                          encrypted_password, created_at, updated_at)
  select x.id, '00000000-0000-0000-0000-000000000000', 'authenticated',
         'authenticated', 'email-sub-check-' || x.id || '@example.invalid',
         '', now(), now()
    from (values
      ('00000000-0000-0000-0000-0000000000e1'::uuid),
      ('00000000-0000-0000-0000-0000000000e2'::uuid)
    ) as x(id)
  on conflict (id) do nothing;

  -- A wallet is required by begin_email_order's paid path; the free path never
  -- touches it, but the row keeps the fixture honest.
  insert into public.wallets (user_id, balance) values (v_user, 0)
    on conflict (user_id) do nothing;

  -- 0. ENFORCEMENT OFF (the state this migration lands in): the pre-2.2 daily
  --    rule still applies and still refuses with `free_limit_reached`. This is
  --    the check that proves the migration is safe to apply to a live database
  --    while 2.1 is the shipped client.
  update public.app_config set value = 'false'::jsonb
   where key = 'email_subscription_enforced';
  update public.app_config set value = '1'::jsonb
   where key = 'email_free_daily_cap';
  v_res := public.begin_email_order(v_user, 'google', 'google.com', 'outlook.com', 0);
  if (v_res->>'ok')::boolean is not true then
    raise exception 'CHECK 0 FAILED: first free address refused with enforcement off: %', v_res;
  end if;
  v_res := public.begin_email_order(v_user, 'google', 'google.com', 'hotmail.com', 0);
  if v_res->>'reason' is distinct from 'free_limit_reached' then
    raise exception 'CHECK 0 FAILED: expected free_limit_reached with enforcement off, got %', v_res;
  end if;
  raise notice 'ok  0. enforcement OFF keeps the shipped per-day rule';

  -- Everything from here tests the NEW rule.
  update public.app_config set value = 'true'::jsonb
   where key = 'email_subscription_enforced';

  -- 1. No prior LIFETIME free orders under the new rule, no subscription → the
  --    first free address is allowed. Check 0 already used one free order on
  --    this fixture user under the old (per-day) rule, so the lifetime
  --    allowance is raised to 2 here and lowered back to 1 before check 2 —
  --    the new rule counts every cost_credits=0, non-failed order ever placed,
  --    including the one check 0 made.
  update public.app_config set value = '2'::jsonb
   where key = 'email_free_lifetime_grants';
  v_res := public.begin_email_order(v_user, 'google', 'google.com', 'yahoo.com', 0);
  if (v_res->>'ok')::boolean is not true then
    raise exception 'CHECK 1 FAILED: first free address refused: %', v_res;
  end if;
  raise notice 'ok  1. first free address allowed';

  -- 2. Lifetime allowance now exhausted (2 used), no subscription → refused,
  --    and the reason must be subscription_required (NOT free_limit_reached,
  --    which the client renders as "try again tomorrow" and would be a lie).
  update public.app_config set value = '1'::jsonb
   where key = 'email_free_lifetime_grants';
  v_res := public.begin_email_order(v_user, 'google', 'google.com', 'hotmail.com', 0);
  if v_res->>'reason' is distinct from 'subscription_required' then
    raise exception 'CHECK 2 FAILED: expected subscription_required, got %', v_res;
  end if;
  raise notice 'ok  2. second free address refused with subscription_required';

  -- 3. gmail is NOT part of the subscription and must stay purchasable with
  --    credits even while the free allowance is exhausted.
  update public.wallets set balance = 5 where user_id = v_user;
  v_res := public.begin_email_order(v_user, 'google', 'google.com', 'gmail.com', 1);
  if (v_res->>'ok')::boolean is not true then
    raise exception 'CHECK 3 FAILED: paid gmail refused: %', v_res;
  end if;
  raise notice 'ok  3. gmail still purchasable with credits';

  -- 4. An ACTIVE subscription lifts the wall.
  perform public.record_email_subscription(
    'tx-fixture-1', v_user, 'com.anthersystems.VirtualSIM.mail.monthly',
    'active'::public.line_sub_state, true, 'Production',
    now() + interval '30 days', 'tx-fixture-1-last', null, null, null, null);
  if public.has_email_subscription(v_user) is not true then
    raise exception 'CHECK 4 FAILED: active subscription not entitled';
  end if;
  v_res := public.begin_email_order(v_user, 'discord', 'discord.com', 'outlook.com', 0);
  if (v_res->>'ok')::boolean is not true then
    raise exception 'CHECK 4 FAILED: subscriber refused: %', v_res;
  end if;
  raise notice 'ok  4. active subscription lifts the wall';

  -- 5. An EXPIRED subscription does not.
  update public.email_subscriptions
     set state = 'expired'::public.line_sub_state, expires_at = now() - interval '1 day'
   where original_transaction_id = 'tx-fixture-1';
  if public.has_email_subscription(v_user) is not false then
    raise exception 'CHECK 5 FAILED: expired subscription still entitled';
  end if;
  raise notice 'ok  5. expired subscription is not entitled';

  -- 6. A GRACE subscription IS entitled — Apple is still trying to bill, and
  --    cutting service off during billing retry loses a customer we still have.
  update public.email_subscriptions
     set state = 'grace'::public.line_sub_state,
         grace_expires_at = now() + interval '10 days'
   where original_transaction_id = 'tx-fixture-1';
  if public.has_email_subscription(v_user) is not true then
    raise exception 'CHECK 6 FAILED: grace subscription not entitled';
  end if;
  raise notice 'ok  6. grace period is entitled';

  -- 7. A renewed subscriber carrying a STALE past grace_expires_at must still
  --    be entitled. This is the exact defect coalesce(grace_expires_at,
  --    expires_at) had: coalesce picks whichever column is non-null first
  --    regardless of which is LATER, so a subscriber who went through grace
  --    and then renewed (expires_at pushed forward, grace_expires_at left
  --    behind in the past) would read as not entitled even though they are an
  --    active, fully paid subscriber. greatest() must win here.
  update public.email_subscriptions
     set state = 'active'::public.line_sub_state,
         expires_at = now() + interval '30 days',
         grace_expires_at = now() - interval '5 days'
   where original_transaction_id = 'tx-fixture-1';
  if public.has_email_subscription(v_user) is not true then
    raise exception 'CHECK 7 FAILED: stale past grace_expires_at wrongly refused an active, renewed subscriber';
  end if;
  raise notice 'ok  7. a stale past grace stamp does not shadow a later expires_at';

  -- 8. The subscriber daily sanity cap is a HARD stop and reports the cap.
  update public.email_subscriptions
     set state = 'active'::public.line_sub_state, expires_at = now() + interval '30 days'
   where original_transaction_id = 'tx-fixture-1';
  select coalesce((value #>> '{}')::integer, 25) into v_cap
    from public.app_config where key = 'email_sub_daily_cap';
  -- Terminal status, not 'waiting': begin_email_order's OWN duplicate-request
  -- guard matches on (user, site, domain, status='waiting', created within 2
  -- minutes), so 'waiting' fixture rows for the exact site/domain the probe
  -- call below reuses would trip that guard first and never reach the cap
  -- check at all. A real day's worth of completed free orders looks like this.
  -- Domain is 'hotmail.com', not 'outlook.com': check 0 left a still-'waiting'
  -- google.com/outlook.com order on this same fixture user (never resolved to
  -- a terminal state), which would trip the very same dedupe guard for the
  -- probe call below if reused.
  insert into public.email_orders (user_id, service_id, site, domain, cost_credits, status)
  select v_user, 'google', 'google.com', 'hotmail.com', 0, 'received'
    from generate_series(1, v_cap);
  v_res := public.begin_email_order(v_user, 'google', 'google.com', 'hotmail.com', 0);
  if v_res->>'reason' is distinct from 'daily_cap_reached' then
    raise exception 'CHECK 8 FAILED: expected daily_cap_reached, got %', v_res;
  end if;
  if (v_res->>'cap')::integer is distinct from v_cap then
    raise exception 'CHECK 8 FAILED: cap not reported: %', v_res;
  end if;
  raise notice 'ok  8. subscriber daily cap is a hard stop and reports the cap';

  -- 9. Replay: the same Apple transaction presented by a SECOND user is
  --    refused. This is the delete-account replay, and rebinding it would hand
  --    a new account an entitlement the old one is still paying for.
  v_res := public.record_email_subscription(
    'tx-fixture-1', '00000000-0000-0000-0000-0000000000e2',
    'com.anthersystems.VirtualSIM.mail.monthly',
    'active'::public.line_sub_state, true, 'Production',
    now() + interval '30 days', 'tx-fixture-1-last', null, null, null, null);
  if v_res->>'reason' is distinct from 'subscription_bound' then
    raise exception 'CHECK 9 FAILED: expected subscription_bound, got %', v_res;
  end if;
  raise notice 'ok  9. replay by a second account is refused';

  raise notice 'ALL CHECKS PASSED';
end $$;

rollback;
