-- Six defects found by a multi-agent audit on 2026-08-07, every one of them
-- verified by reading the live definition rather than trusting the report.
-- None had a symptom: the line product has never been sold, so all of these
-- would have fired first against a paying customer or an App Store reviewer.
--
--   1. inbound calls consumed the caller's own voice allowance
--   2. a stuck credit-billed rental forfeited the user's credits forever
--   3. refund_credit_line_claim could pay out twice
--   4. a credits-line holder could never buy the Apple subscription
--   5. blocking a peer did not stop outbound sends to them
--   6. a YEARLY subscriber got one month of allowance for twelve months

-- ── 1. Inbound calls must not be billed to the allowance ───────────────────
-- `begin-line-call` reserves 0 seconds for inbound and its comment states
-- inbound is "RECORDED BUT NEVER BILLED". settle_call_claim never read
-- `direction`, so settle_line_allowance was handed (billed - 0) = the whole
-- call. A subscriber who ANSWERS three 20-minute calls — something they do not
-- control — burned 60 of the 100 minutes they were sold "in and out".
-- ⚠️ `p_cost_usd default null` must be REPRODUCED verbatim. `create or replace`
-- cannot drop an existing parameter default — it fails with 42P13 "cannot
-- remove parameter defaults from existing function", which reads like a
-- signature mismatch and is really just a missing `default`.
create or replace function public.settle_call_claim(
  p_call uuid, p_billed_seconds integer, p_cost_cents integer,
  p_status public.line_call_status, p_hangup_cause text,
  p_cost_usd numeric default null
) returns boolean
language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_settled boolean; v_line uuid; v_reserved integer;
  v_direction public.line_call_direction;
begin
  select allowance_settled, line_id, reserved_seconds, direction
    into v_settled, v_line, v_reserved, v_direction
    from public.line_calls where id = p_call for update;
  if not found or v_settled then return false; end if;

  update public.line_calls
     set billed_seconds = coalesce(p_billed_seconds, billed_seconds),
         provider_cost_cents = coalesce(p_cost_cents, provider_cost_cents),
         provider_cost_usd   = coalesce(p_cost_usd, provider_cost_usd),
         status = p_status,
         hangup_cause = coalesce(p_hangup_cause, hangup_cause),
         ended_at = coalesce(ended_at, now()),
         allowance_settled = true
   where id = p_call;

  -- Outbound settles real usage against what was reserved. Inbound reserved
  -- nothing and owes nothing, so it settles 0 against 0 — which still releases
  -- any reservation rather than skipping the call entirely.
  if v_direction = 'inbound' then
    perform public.settle_line_allowance(v_line, 'voice', 0, coalesce(v_reserved, 0));
  else
    perform public.settle_line_allowance(
      v_line, 'voice', coalesce(p_billed_seconds, 0), v_reserved);
  end if;
  return true;
end;
$fn$;
revoke execute on function public.settle_call_claim(
  uuid, integer, integer, public.line_call_status, text, numeric)
  from public, anon, authenticated;

-- ── 2 + 3. Make the credit refund idempotent, THEN sweep for stuck rentals ──
-- `refund_credit_line_claim` accepts status in ('provisioning','failed') and
-- unconditionally calls wallet_move_line, which has NO replay guard and
-- line_rent_charges has no unique index — so two callers on a 'failed' row
-- paid the user twice. The tombstone DELETE is now the claim: only the caller
-- that actually removes the charge row pays out.
create or replace function public.refund_credit_line_claim(p_line uuid)
returns boolean
language plpgsql security definer set search_path to 'public' as $fn$
declare rec record; v_deleted integer;
begin
  select id, user_id, rent_credits, status, billing
    into rec
    from public.phone_lines
   where id = p_line
     for update;

  if not found or rec.billing <> 'credits' then return false; end if;
  if rec.status not in ('provisioning','failed') then return false; end if;

  delete from public.line_rent_charges where line_id = p_line;
  get diagnostics v_deleted = row_count;

  update public.phone_lines
     set status = 'failed', updated_at = now()
   where id = p_line;

  -- v_deleted = 0 means someone already refunded this rental. Flipping the
  -- status again is harmless; paying again is not.
  if v_deleted > 0 and rec.rent_credits is not null and rec.rent_credits > 0 then
    perform public.wallet_move_line(rec.user_id, rec.rent_credits, 'refund', p_line);
  end if;
  return v_deleted > 0;
end $fn$;
revoke execute on function public.refund_credit_line_claim(uuid)
  from public, anon, authenticated;

-- `reclaim_lapsed_lines` ages a stuck 'provisioning' row to 'failed' with a
-- raw UPDATE and no refund. That was CORRECT when Apple was the only billing
-- mode ("Apple owns the money", as its comment says) and became a silent
-- forfeiture the moment credit billing landed: rent-line-credits charges in
-- one transaction and refunds in a SEPARATE round-trip, so any crash between
-- them strands the credits, and refund_credit_line_claim has no other caller.
--
-- A separate sweep rather than a rewrite of that 700-line function: it runs
-- AFTER the reclaim flip, matches on the tombstone still being present, and is
-- idempotent by construction thanks to the change above.
create or replace function public.refund_stuck_credit_lines()
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare v_line record; v_refunded integer := 0;
begin
  for v_line in
    select pl.id
      from public.phone_lines pl
     where pl.billing = 'credits'
       and pl.status in ('provisioning','failed')
       and pl.created_at < now() - interval '20 minutes'
       and exists (select 1 from public.line_rent_charges c where c.line_id = pl.id)
     limit 200
  loop
    if public.refund_credit_line_claim(v_line.id) then
      v_refunded := v_refunded + 1;
    end if;
  end loop;

  insert into public.app_config (key, value)
  values ('credit_refund_sweep_at', to_jsonb(now()))
  on conflict (key) do update set value = excluded.value;

  return jsonb_build_object('refunded', v_refunded);
end $fn$;
revoke execute on function public.refund_stuck_credit_lines()
  from public, anon, authenticated;

-- ── 4. One-line-per-user must mean one APPLE line per user ─────────────────
-- 20260806160000 deliberately dropped phone_lines_one_live_per_user and
-- replaced it with an index scoped to billing='apple', so a credits line and
-- an Apple line may coexist. begin_line_rental's occupancy check never
-- followed: a user holding a credits line who subscribed was charged by Apple
-- and then refused with 'line_exists'. Apple keeps the money.
create or replace function public.begin_line_rental(
  p_user uuid, p_e164 text, p_country text, p_number_type text,
  p_original_tx text, p_product text
) returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_line uuid;
  v_existing uuid;
  v_bound uuid;
  v_paused boolean;
begin
  if p_user is null or p_e164 is null or p_country is null
     or p_original_tx is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  select coalesce((value #>> '{}')::boolean, false) into v_paused
    from public.app_config where key = 'lines_paused';
  if coalesce(v_paused, false) then
    return jsonb_build_object('ok', false, 'reason', 'lines_paused');
  end if;

  perform pg_advisory_xact_lock(hashtext(p_user::text));

  -- Scoped to billing='apple' to match phone_lines_one_apple_line_per_user.
  select id into v_existing from public.phone_lines
   where user_id = p_user
     and billing = 'apple'
     and status in ('provisioning','active','grace','past_due','suspended','releasing')
   limit 1;
  if v_existing is not null then
    return jsonb_build_object('ok', false, 'reason', 'line_exists',
                              'line_id', v_existing);
  end if;

  select user_id into v_bound from public.line_subscriptions
   where original_transaction_id = p_original_tx;
  if v_bound is not null and v_bound <> p_user then
    return jsonb_build_object('ok', false, 'reason', 'subscription_bound');
  end if;

  insert into public.phone_lines (
    user_id, e164, country_code, number_type, status, original_transaction_id)
  values (p_user, p_e164, p_country, coalesce(p_number_type, 'toll_free'),
          'provisioning', p_original_tx)
  returning id into v_line;

  return jsonb_build_object('ok', true, 'line_id', v_line);
end;
$fn$;
revoke execute on function public.begin_line_rental(uuid, text, text, text, text, text)
  from public, anon, authenticated;

-- ── 5. Blocking a peer must actually stop outbound sends ───────────────────
-- `begin_outbound_message` checked ownership, status and allowance but never
-- line_threads.blocked, so the block was client-side only. The tell was dead
-- client code: APIError.swift and ErrorBanner.swift both handle a
-- `recipient_blocked` code that NO server path has ever emitted.
create or replace function public.begin_outbound_message(
  p_user uuid, p_line uuid, p_to text, p_body text, p_segments integer
) returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_line record; v_thread uuid; v_msg uuid; v_allow jsonb;
  v_segments integer; v_blocked boolean;
begin
  if p_to is null or p_body is null or length(p_body) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;
  v_segments := greatest(coalesce(p_segments, 1), 1);

  perform pg_advisory_xact_lock(hashtext(p_user::text));

  select id, user_id, e164, status into v_line
    from public.phone_lines where id = p_line;
  if not found or v_line.user_id <> p_user then
    return jsonb_build_object('ok', false, 'reason', 'line_unavailable');
  end if;
  if v_line.status not in ('active', 'grace') then
    return jsonb_build_object('ok', false, 'reason', 'line_suspended',
                              'status', v_line.status);
  end if;

  -- Checked BEFORE the allowance is spent: a refused send must cost nothing.
  select blocked into v_blocked from public.line_threads
   where line_id = p_line and peer_e164 = p_to;
  if coalesce(v_blocked, false) then
    return jsonb_build_object('ok', false, 'reason', 'recipient_blocked');
  end if;

  select public.consume_line_allowance(p_line, 'sms', v_segments) into v_allow;
  if not coalesce((v_allow ->> 'ok')::boolean, false) then
    return v_allow;
  end if;

  insert into public.line_threads (line_id, user_id, peer_e164)
  values (p_line, p_user, p_to)
  on conflict (line_id, peer_e164) do update set peer_e164 = excluded.peer_e164
  returning id into v_thread;

  insert into public.line_messages (
    thread_id, line_id, user_id, direction, e164_from, e164_to,
    body, status, segments)
  values (v_thread, p_line, p_user, 'outbound', v_line.e164, p_to,
          p_body, 'queued', v_segments)
  returning id into v_msg;

  update public.line_threads
     set last_message_at = now(), last_preview = left(p_body, 140)
   where id = v_thread;

  return jsonb_build_object('ok', true, 'message_id', v_msg,
                            'thread_id', v_thread, 'from', v_line.e164,
                            'remaining', v_allow -> 'remaining');
end;
$fn$;
revoke execute on function public.begin_outbound_message(uuid, uuid, text, text, integer)
  from public, anon, authenticated;

-- ── 6. A yearly subscriber must get a MONTHLY allowance ────────────────────
-- Allowances reset in exactly three places: activate_line_claim (once, at
-- provisioning), apply_line_renewal (on Apple's DID_RENEW) and
-- debit_credit_lines (scoped `where billing = 'credits'`). For the $99.99
-- YEARLY product Apple's next DID_RENEW is twelve months out, so the meter
-- rolled over once a year while the checkout screen sold "200 texts a month"
-- and "100 minutes a month". Month one worked; months two to twelve were a
-- hard stop.
--
-- Advancing allowance_period_start by whole elapsed months (rather than
-- setting it to now()) keeps the anniversary stable, so a user does not lose
-- days by the sweep running late. Monthly Apple lines are unaffected in
-- practice: apply_line_renewal already resets them, which leaves
-- allowance_period_start younger than a month.
create or replace function public.roll_line_allowance_periods()
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare v_rolled integer;
begin
  update public.phone_lines
     set allowance_period_start = allowance_period_start
           + (interval '1 month' * (
                extract(year  from age(now(), allowance_period_start)) * 12
              + extract(month from age(now(), allowance_period_start)))),
         sms_used = 0,
         voice_used_seconds = 0,
         updated_at = now()
   where billing = 'apple'
     and status in ('active', 'grace')
     and allowance_period_start is not null
     and age(now(), allowance_period_start) >= interval '1 month';
  get diagnostics v_rolled = row_count;

  insert into public.app_config (key, value)
  values ('allowance_roll_at', to_jsonb(now()))
  on conflict (key) do update set value = excluded.value;

  return jsonb_build_object('rolled', v_rolled);
end $fn$;
revoke execute on function public.roll_line_allowance_periods()
  from public, anon, authenticated;

-- ── Schedules. Pure SQL on pg_cron, no HTTP hop: both of these hand money or
-- allowance back, so they must keep running when the edge layer is down.
select cron.unschedule('refund-stuck-credit-lines')
 where exists (select 1 from cron.job where jobname = 'refund-stuck-credit-lines');
select cron.schedule('refund-stuck-credit-lines', '11,41 * * * *',
                     $$select public.refund_stuck_credit_lines();$$);

select cron.unschedule('roll-line-allowances')
 where exists (select 1 from cron.job where jobname = 'roll-line-allowances');
select cron.schedule('roll-line-allowances', '9 * * * *',
                     $$select public.roll_line_allowance_periods();$$);
