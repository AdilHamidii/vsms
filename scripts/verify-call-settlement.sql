-- Behavioural checks for 20260820110000_never_bill_an_unconnected_call.sql.
-- Runs inside a transaction that ROLLS BACK: it inserts synthetic calls against
-- a real line, settles them, and asserts the money moved. A structural check
-- cannot catch this class — the functions exist and are correct-looking in both
-- the broken and the fixed state; only the credits tell you which one is live.
--
--   psql/db query --file scripts/verify-call-settlement.sql
begin;

do $$
declare
  v_line uuid; v_user uuid; v_call uuid;
  v_bal_before integer; v_bal_after integer;
  v_charged integer; v_cause text; v_secs integer;
  v_alw_before integer; v_alw_after integer;
begin
  select id, user_id into v_line, v_user
    from public.phone_lines where status in ('active','suspended') limit 1;
  if v_line is null then
    raise notice 'SKIP — no phone_lines row to test against';
    return;
  end if;

  -- Make sure the wallet can fund the reservation we are about to test.
  perform public.wallet_credit(v_user, 50, 'adjustment', null);

  -- ── 1. INTERNATIONAL, never reached the provider: bills ZERO ──────────────
  select balance into v_bal_before from public.wallets where user_id = v_user;
  insert into public.line_calls
    (line_id, user_id, direction, peer_e164, status, started_at, ended_at,
     reserved_seconds, credits_reserved, rate_credits_per_min,
     duration_seconds, allowance_settled, created_at)
  values (v_line, v_user, 'outbound', '+33123456789', 'missed', now(), now(),
          120, 2, 0.75, 0, false, now() - interval '10 hours')
  returning id into v_call;
  perform public.wallet_spend_line(v_user, 2, v_line);   -- what dial time did

  perform public.settle_stale_calls(360);
  select credits_charged, hangup_cause, billed_seconds
    into v_charged, v_cause, v_secs
    from public.line_calls where id = v_call;
  select balance into v_bal_after from public.wallets where user_id = v_user;

  assert v_charged = 0,
    format('FAIL 1a: unreached intl call charged %s credits, expected 0', v_charged);
  assert v_cause = 'no_cdr_unreached',
    format('FAIL 1b: hangup_cause %s, expected no_cdr_unreached', v_cause);
  assert v_bal_after = v_bal_before,
    format('FAIL 1c: balance %s -> %s, expected the 2-credit block refunded in full',
           v_bal_before, v_bal_after);
  raise notice 'PASS 1 — unreached international call: 0 credits, block refunded';

  -- ── 2. INTERNATIONAL, reached the provider: bills the FULL reservation ────
  -- This is the deliberate conservative case. If it ever starts billing 0, the
  -- status gate rejected in the header has been reintroduced and the exploit
  -- is back.
  select balance into v_bal_before from public.wallets where user_id = v_user;
  insert into public.line_calls
    (line_id, user_id, direction, peer_e164, status, started_at, ended_at,
     reserved_seconds, credits_reserved, rate_credits_per_min,
     duration_seconds, provider_call_session_id, allowance_settled, created_at)
  values (v_line, v_user, 'outbound', '+33123456789', 'canceled', now(), now(),
          120, 2, 0.75, 0, 'sess-'||gen_random_uuid()::text, false,
          now() - interval '10 hours')
  returning id into v_call;
  perform public.wallet_spend_line(v_user, 2, v_line);

  perform public.settle_stale_calls(360);
  select credits_charged, hangup_cause into v_charged, v_cause
    from public.line_calls where id = v_call;

  assert v_charged = 2,
    format('FAIL 2a: reached intl call charged %s credits, expected the full '
        || 'block of 2 — a client-reported "canceled" MUST NOT zero the bill',
           v_charged);
  assert v_cause = 'no_cdr_full',
    format('FAIL 2b: hangup_cause %s, expected no_cdr_full', v_cause);
  raise notice 'PASS 2 — reached international call: full block billed despite client "canceled"';

  -- ── 3. DOMESTIC, never reached the provider: consumes ZERO allowance ──────
  select voice_used_seconds into v_alw_before
    from public.phone_lines where id = v_line;
  insert into public.line_calls
    (line_id, user_id, direction, peer_e164, status, started_at, ended_at,
     reserved_seconds, credits_reserved, duration_seconds,
     allowance_settled, created_at)
  values (v_line, v_user, 'outbound', '+14155550123', 'missed', now(), now(),
          120, 0, 0, false, now() - interval '10 hours')
  returning id into v_call;
  update public.phone_lines set voice_used_seconds = voice_used_seconds + 120 where id = v_line;  -- what dial time did

  perform public.settle_stale_calls(360);
  select voice_used_seconds into v_alw_after
    from public.phone_lines where id = v_line;

  assert v_alw_after = v_alw_before,
    format('FAIL 3: unreached domestic call consumed %s allowance seconds, '
        || 'expected 0 (%s -> %s)',
           v_alw_after - v_alw_before, v_alw_before, v_alw_after);
  raise notice 'PASS 3 — unreached domestic call: whole 120 s reservation returned';

  raise notice 'ALL CHECKS PASSED';
end $$;

rollback;
