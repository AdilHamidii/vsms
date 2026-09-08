-- Behavioural checks for auto-reprovisioning a number when a renewal lands on
-- a released line (migration 20260908110000 + apple-notifications'
-- `reprovisionAfterRenewal`). Everything runs inside a transaction that is
-- ROLLED BACK, so production state is untouched.
--
-- Run: supabase db query --linked --file scripts/verify-line-reprovision.sql
-- Expect: a single 'ALL CHECKS PASSED' notice. Any failure raises.
--
-- A structural check cannot catch this class. `line_reprovision_target` and
-- `begin_line_rental` both EXIST and both look right; what has to be proven is
-- that two deliveries of one notification produce ONE number, that a mail
-- renewal can never reach phone_lines, and that the row the second half writes
-- survives the next `reclaim_lapsed_lines` sweep — which is the difference
-- between provisioning a number and buying one every fifteen minutes forever.

begin;

do $$
declare
  v_user      uuid;
  v_user2     uuid;
  v_before    bigint;
  v_after     bigint;
  v_line      uuid;
  v_line2     uuid;
  v_r         jsonb;
  v_r2        jsonb;
  v_status    public.line_status;
  v_tx        text := 'verify-reprov-tx-1';
  v_tx_nolines text := 'verify-reprov-tx-2';
  v_tx_expired text := 'verify-reprov-tx-3';
  v_tx_mail   text := 'verify-reprov-tx-mail';
begin
  -- Two users that hold no Apple line today, so nothing real is disturbed.
  select u.id into v_user from auth.users u
   where not exists (select 1 from public.phone_lines p
                      where p.user_id = u.id and p.billing = 'apple'
                        and p.status <> 'released' and p.status <> 'failed')
   limit 1;
  select u.id into v_user2 from auth.users u
   where u.id <> v_user
     and not exists (select 1 from public.phone_lines p
                      where p.user_id = u.id and p.billing = 'apple'
                        and p.status <> 'released' and p.status <> 'failed')
   limit 1;
  if v_user is null or v_user2 is null then
    raise exception 'setup: need two line-less users to test with';
  end if;

  select count(*) into v_before from public.phone_lines;

  -- ════════════════════════════════════════════════════════════════════════
  -- A. A renewal for a subscriber who STILL HOLDS a line must not provision.
  -- ════════════════════════════════════════════════════════════════════════
  insert into public.line_subscriptions (
    original_transaction_id, user_id, product_id, state, environment, expires_at)
  values (v_tx, v_user, 'com.anthersystems.VirtualSIM.line.monthly',
          'active', 'Production', now() + interval '30 days');

  insert into public.phone_lines (
    user_id, e164, country_code, number_type, status, billing,
    original_transaction_id, locality, current_period_end)
  values (v_user, '+15550001111', 'US', 'local', 'active', 'apple',
          v_tx, 'new-york', now() + interval '30 days')
  returning id into v_line;

  v_r := public.line_reprovision_target(v_tx);
  if (v_r->>'ok')::boolean is not false or v_r->>'reason' <> 'line_exists' then
    raise exception 'A: a live line did not refuse reprovisioning (%)', v_r;
  end if;

  -- ════════════════════════════════════════════════════════════════════════
  -- B. The same subscriber after the line was RELEASED: provision, and put
  --    them back in their own country and city.
  -- ════════════════════════════════════════════════════════════════════════
  update public.phone_lines
     set status = 'released', released_at = now(), e164 = null
   where id = v_line;

  v_r := public.line_reprovision_target(v_tx);
  if (v_r->>'ok')::boolean is not true then
    raise exception 'B: released line did not qualify for reprovisioning (%)', v_r;
  end if;
  if v_r->>'user_id' <> v_user::text then
    raise exception 'B: wrong user attributed (%)', v_r;
  end if;
  if v_r->>'country_code' <> 'US' or v_r->>'locality' <> 'new-york'
     or v_r->>'number_type' <> 'local' then
    raise exception 'B: did not carry the prior place forward (%)', v_r;
  end if;

  -- ════════════════════════════════════════════════════════════════════════
  -- C. THE IDEMPOTENCE CHECK. Two deliveries of the same notification —
  --    `begin_line_rental` is the mutex, and the number is only ordered after
  --    it succeeds, so the second delivery must buy nothing.
  -- ════════════════════════════════════════════════════════════════════════
  v_r := public.begin_line_rental(v_user, '+15550002222', 'US', 'local',
                                  v_tx, 'com.anthersystems.VirtualSIM.line.monthly');
  if (v_r->>'ok')::boolean is not true then
    raise exception 'C: first delivery could not begin a rental (%)', v_r;
  end if;
  v_line2 := (v_r->>'line_id')::uuid;

  -- Delivery two, arriving before the first has activated (worst case: the
  -- row is still `provisioning`).
  v_r2 := public.line_reprovision_target(v_tx);
  if v_r2->>'reason' <> 'line_exists' then
    raise exception 'C: a provisioning row did not stop the retry (%)', v_r2;
  end if;
  v_r2 := public.begin_line_rental(v_user, '+15550003333', 'US', 'local',
                                   v_tx, 'com.anthersystems.VirtualSIM.line.monthly');
  if (v_r2->>'ok')::boolean is not false or v_r2->>'reason' <> 'line_exists' then
    raise exception 'C: the second delivery started a SECOND rental (%)', v_r2;
  end if;

  if (select count(*) from public.phone_lines
       where user_id = v_user and billing = 'apple'
         and status in ('provisioning','active','grace','past_due','suspended','releasing')) <> 1 then
    raise exception 'C: more than one live line for one subscriber';
  end if;

  -- ════════════════════════════════════════════════════════════════════════
  -- D. A FAILED attempt must leave the next retry able to succeed. `failed`
  --    is outside the partial unique index, which is why this works and why
  --    a notification-uuid tombstone would have locked the recovery out.
  -- ════════════════════════════════════════════════════════════════════════
  if public.fail_line_claim(v_line2, 'order_BALANCE_ERROR') is not true then
    raise exception 'D: could not fail a provisioning line';
  end if;
  v_r := public.line_reprovision_target(v_tx);
  if (v_r->>'ok')::boolean is not true then
    raise exception 'D: a failed attempt blocked the retry (%)', v_r;
  end if;
  v_r := public.begin_line_rental(v_user, '+15550002222', 'US', 'local',
                                  v_tx, 'com.anthersystems.VirtualSIM.line.monthly');
  if (v_r->>'ok')::boolean is not true then
    raise exception 'D: the retry could not begin a rental (%)', v_r;
  end if;
  v_line2 := (v_r->>'line_id')::uuid;

  -- ════════════════════════════════════════════════════════════════════════
  -- E. THE PERIOD END. `activate_line_claim` is handed the RENEWAL's own
  --    period end; the new line must survive the very next reclaim sweep.
  --    Getting this wrong buys and releases a $1 number every 15 minutes.
  -- ════════════════════════════════════════════════════════════════════════
  if public.activate_line_claim(
       v_line2, 'test-number-id', null, null, null, null,
       now() + interval '365 days', 100, 'test-order-id') is not true then
    raise exception 'E: could not activate the reprovisioned line';
  end if;
  perform public.reclaim_lapsed_lines();
  select status into v_status from public.phone_lines where id = v_line2;
  if v_status <> 'active' then
    raise exception 'E: the reprovisioned line was reclaimed immediately (status=%)', v_status;
  end if;

  -- E2. The control, so E cannot pass vacuously: the SAME row with a stale
  --     period end IS swept. If this stops firing, E proves nothing.
  update public.phone_lines
     set current_period_end = now() - interval '7 hours' where id = v_line2;
  perform public.reclaim_lapsed_lines();
  select status into v_status from public.phone_lines where id = v_line2;
  if v_status <> 'releasing' then
    raise exception 'E2: a stale period end was NOT swept (status=%) — check E', v_status;
  end if;

  -- ════════════════════════════════════════════════════════════════════════
  -- F. A MAIL renewal must never touch phone_lines. A mail product has no
  --    row in line_subscriptions at all, so even without the family dispatch
  --    in apple-notifications there is nothing here for it to act on.
  -- ════════════════════════════════════════════════════════════════════════
  insert into public.email_subscriptions (
    original_transaction_id, user_id, product_id, state, environment, expires_at)
  values (v_tx_mail, v_user2, 'com.anthersystems.VirtualSIM.mail.monthly',
          'active', 'Production', now() + interval '30 days');

  v_r := public.line_reprovision_target(v_tx_mail);
  if (v_r->>'ok')::boolean is not false or v_r->>'reason' <> 'unknown_subscription' then
    raise exception 'F: a mail subscription was treated as a line (%)', v_r;
  end if;
  if exists (select 1 from public.phone_lines where user_id = v_user2) then
    raise exception 'F: a mail renewal created a phone line';
  end if;

  -- ════════════════════════════════════════════════════════════════════════
  -- G. A subscription that has NEVER held a number is refused — a different
  --    failure with a different fix, and the shape of a first purchase
  --    racing our own client call, which owns that path.
  -- ════════════════════════════════════════════════════════════════════════
  insert into public.line_subscriptions (
    original_transaction_id, user_id, product_id, state, environment, expires_at)
  values (v_tx_nolines, v_user2, 'com.anthersystems.VirtualSIM.line.yearly',
          'active', 'Production', now() + interval '365 days');
  v_r := public.line_reprovision_target(v_tx_nolines);
  if (v_r->>'ok')::boolean is not false or v_r->>'reason' <> 'no_prior_line' then
    raise exception 'G: a never-provisioned subscription was reprovisioned (%)', v_r;
  end if;

  -- ════════════════════════════════════════════════════════════════════════
  -- H. An expired/revoked subscription earns nothing, even if a renewal
  --    notification is replayed against it.
  -- ════════════════════════════════════════════════════════════════════════
  insert into public.line_subscriptions (
    original_transaction_id, user_id, product_id, state, environment, expires_at)
  values (v_tx_expired, v_user2, 'com.anthersystems.VirtualSIM.line.monthly',
          'expired', 'Production', now() - interval '1 day');
  insert into public.phone_lines (
    user_id, e164, country_code, number_type, status, billing,
    original_transaction_id)
  values (v_user2, '+15550004444', 'CA', 'local', 'released', 'apple', v_tx_expired);
  v_r := public.line_reprovision_target(v_tx_expired);
  if (v_r->>'ok')::boolean is not false
     or v_r->>'reason' <> 'subscription_not_active' then
    raise exception 'H: an expired subscription was reprovisioned (%)', v_r;
  end if;

  -- I. An unknown transaction is refused rather than guessed at.
  v_r := public.line_reprovision_target('verify-reprov-does-not-exist');
  if v_r->>'reason' <> 'unknown_subscription' then
    raise exception 'I: an unknown transaction was not refused (%)', v_r;
  end if;

  -- Nothing above touched a line that existed before this script ran.
  select count(*) into v_after from public.phone_lines;
  -- Four: A's line, C's first attempt (failed in D), D's retry, H's released
  -- row. Counted so a stray insert cannot hide in a passing run.
  if v_after - v_before <> 4 then
    raise exception 'sanity: expected 4 new rows, got %', v_after - v_before;
  end if;

  raise notice 'ALL CHECKS PASSED';
end $$;

rollback;
