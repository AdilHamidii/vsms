-- Behavioural checks for rescuing a subscriber who PAID AND NEVER RECEIVED A
-- NUMBER (migration 20260908150000). Runs inside a transaction that is ROLLED
-- BACK, so production state is untouched.
--
-- Run: supabase db query --linked --file scripts/verify-line-first-provision.sql
-- Expect: a single 'ALL CHECKS PASSED' notice. Any failure raises.
--
-- A structural check cannot catch this class: `line_reprovision_target` existed
-- and looked correct the whole time it was refusing the one case that had cost
-- a real customer $59.99. What has to be PROVEN is the pair of opposite
-- answers it must give to the same shape — refuse inside the 30-minute window
-- where our own client call may still be in flight, provision outside it — and
-- that the DID_RENEW caller's behaviour is unchanged when it does not opt in.

begin;

do $$
declare
  v_user   uuid;
  v_user2  uuid;
  v_r      jsonb;
  v_n      int;
  v_tx_old text := 'verify-first-old';
  v_tx_new text := 'verify-first-new';
  v_tx_dead text := 'verify-first-expired';
begin
  select u.id into v_user from auth.users u
   where not exists (select 1 from public.phone_lines p
                      where p.user_id = u.id and p.billing = 'apple'
                        and p.status not in ('released','failed'))
   limit 1;
  select u.id into v_user2 from auth.users u
   where u.id <> v_user
     and not exists (select 1 from public.phone_lines p
                      where p.user_id = u.id and p.billing = 'apple'
                        and p.status not in ('released','failed'))
   limit 1;
  if v_user is null or v_user2 is null then
    raise exception 'setup: need two line-less users to test with';
  end if;

  -- A paid, entitled subscription that never produced a line, old enough that
  -- our own purchase call is demonstrably not coming. This is the incident.
  insert into public.line_subscriptions (
    original_transaction_id, user_id, product_id, state, environment,
    expires_at, created_at)
  values (v_tx_old, v_user, 'com.anthersystems.VirtualSIM.line.yearly',
          'active', 'Production', now() + interval '300 days',
          now() - interval '3 days');

  -- ════════════════════════════════════════════════════════════════════════
  -- A. The DID_RENEW default is UNCHANGED. Opting in is explicit.
  -- ════════════════════════════════════════════════════════════════════════
  v_r := public.line_reprovision_target(v_tx_old);
  if v_r->>'reason' is distinct from 'no_prior_line' then
    raise exception 'A: default must still refuse a first provision, got %', v_r;
  end if;

  -- ════════════════════════════════════════════════════════════════════════
  -- B. With p_allow_first it provisions — and says so.
  -- ════════════════════════════════════════════════════════════════════════
  v_r := public.line_reprovision_target(v_tx_old, true);
  if (v_r->>'ok') is distinct from 'true' then
    raise exception 'B: an aged unprovisioned subscription must provision, got %', v_r;
  end if;
  if (v_r->>'first_provision') is distinct from 'true' then
    raise exception 'B: must be flagged first_provision, got %', v_r;
  end if;
  -- Null country is CORRECT: there is no earlier line to copy, and the caller
  -- falls back to DEFAULT_LINE_COUNTRY behind its own fail-closed gate.
  if v_r ? 'country_code' and v_r->>'country_code' is not null then
    raise exception 'B: first provision must not invent a country, got %', v_r;
  end if;
  if (v_r->>'user_id')::uuid <> v_user then
    raise exception 'B: wrong user attributed, got %', v_r;
  end if;

  -- ════════════════════════════════════════════════════════════════════════
  -- C. 🔴 THE RACE GUARD. A minutes-old subscription must be REFUSED even
  --    with p_allow_first — the client owns the first purchase and lets the
  --    user pick their own number.
  -- ════════════════════════════════════════════════════════════════════════
  insert into public.line_subscriptions (
    original_transaction_id, user_id, product_id, state, environment,
    expires_at, created_at)
  values (v_tx_new, v_user2, 'com.anthersystems.VirtualSIM.line.monthly',
          'active', 'Production', now() + interval '30 days',
          now() - interval '2 minutes');
  v_r := public.line_reprovision_target(v_tx_new, true);
  if v_r->>'reason' is distinct from 'no_prior_line' then
    raise exception 'C: a fresh purchase must not be provisioned from here, got %', v_r;
  end if;

  -- ════════════════════════════════════════════════════════════════════════
  -- D. A dead entitlement never buys a number, however old it is.
  -- ════════════════════════════════════════════════════════════════════════
  insert into public.line_subscriptions (
    original_transaction_id, user_id, product_id, state, environment,
    expires_at, created_at)
  values (v_tx_dead, v_user2, 'com.anthersystems.VirtualSIM.line.monthly',
          'expired', 'Production', now() - interval '1 day',
          now() - interval '60 days');
  v_r := public.line_reprovision_target(v_tx_dead, true);
  if v_r->>'reason' is distinct from 'subscription_not_active' then
    raise exception 'D: an expired subscription must not provision, got %', v_r;
  end if;

  -- ════════════════════════════════════════════════════════════════════════
  -- E. Unattributable stays unattributable. Never guess a user.
  -- ════════════════════════════════════════════════════════════════════════
  v_r := public.line_reprovision_target('verify-first-nobody', true);
  if v_r->>'reason' is distinct from 'unknown_subscription' then
    raise exception 'E: an unknown transaction must not resolve, got %', v_r;
  end if;

  -- ════════════════════════════════════════════════════════════════════════
  -- F. The candidate list sees the aged one and NOT the fresh one.
  -- ════════════════════════════════════════════════════════════════════════
  select count(*) into v_n
    from jsonb_array_elements(public.line_unprovisioned_subscriptions(30, 50)) e
   where e->>'original_transaction_id' = v_tx_old;
  if v_n <> 1 then
    raise exception 'F: the aged unprovisioned subscription must be a candidate';
  end if;
  select count(*) into v_n
    from jsonb_array_elements(public.line_unprovisioned_subscriptions(30, 50)) e
   where e->>'original_transaction_id' in (v_tx_new, v_tx_dead);
  if v_n <> 0 then
    raise exception 'F: a fresh or dead subscription must never be a candidate';
  end if;

  -- ════════════════════════════════════════════════════════════════════════
  -- G. 🔴 ONE ATTEMPT PER DAY. A recent failed attempt takes the subscriber
  --    out of the sweep — without this a permanently broken subscription is
  --    retried every fifteen minutes and each attempt past the order call has
  --    already spent $1 at Telnyx.
  -- ════════════════════════════════════════════════════════════════════════
  insert into public.phone_lines (
    user_id, e164, country_code, number_type, status, billing,
    original_transaction_id, created_at)
  values (v_user, '+15555550199', 'US', 'local', 'failed', 'apple',
          v_tx_old, now() - interval '1 hour');
  select count(*) into v_n
    from jsonb_array_elements(public.line_unprovisioned_subscriptions(30, 50)) e
   where e->>'original_transaction_id' = v_tx_old;
  if v_n <> 0 then
    raise exception 'G: a recent failed attempt must suppress the next sweep';
  end if;

  -- ════════════════════════════════════════════════════════════════════════
  -- H. A live line still wins. The sweep must never double-provision.
  -- ════════════════════════════════════════════════════════════════════════
  update public.phone_lines set status = 'active'
   where user_id = v_user and e164 = '+15555550199';
  v_r := public.line_reprovision_target(v_tx_old, true);
  if v_r->>'reason' is distinct from 'line_exists' then
    raise exception 'H: an existing live line must block provisioning, got %', v_r;
  end if;

  raise notice 'ALL CHECKS PASSED';
end $$;

rollback;
