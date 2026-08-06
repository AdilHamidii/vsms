-- Behavioural verification of the line lifecycle repairs.
-- Runs inside a transaction that ROLLS BACK: nothing here touches live data.
--
-- Structural checks prove a function exists. These prove it BEHAVES — which is
-- the only thing that caught the ON CONFLICT partial-index defect, where the
-- index was present and correct and simply unreachable from the code.
begin;

do $$
declare
  u1 uuid := 'ae282288-ade3-4458-9145-ccc0f18cf1fc';
  u2 uuid := 'efe48990-4e4e-4453-89f9-3fdaf156bef0';
  u3 uuid := 'd94e8cd2-3f52-471e-8a3c-52c7953f0d56';
  u4 uuid := '394df41e-aa15-4ec7-b9c7-293b281c1c64';
  v_line uuid; v_line2 uuid; v_line3 uuid;
  v_call uuid; v_call2 uuid; v_msg uuid;
  r jsonb; b boolean; n integer;
  v_used integer; v_status public.line_status;
  v_cents integer; v_usd numeric;
  v_tomb integer;
begin
  -- ── 1. apply_line_renewal must NOT claim the tombstone while provisioning ──
  insert into public.phone_lines (user_id, e164, country_code, number_type,
                                  status, original_transaction_id)
  values (u1, '+15550001001', 'CA', 'local', 'provisioning', 'TX-PROV-1')
  returning id into v_line;

  r := public.apply_line_renewal('TX-PROV-1', 'TXN-1', now() + interval '30 days',
                                 null, null, null, null);
  if coalesce(r->>'reason','') <> 'line_provisioning' then
    raise exception '1a FAILED: expected line_provisioning, got %', r;
  end if;
  select count(*) into v_tomb from public.line_renewals where transaction_id = 'TXN-1';
  if v_tomb <> 0 then
    raise exception '1b FAILED: tombstone claimed on a deferred renewal (%)', v_tomb;
  end if;
  raise notice '1 OK  renewal deferred while provisioning, tombstone NOT claimed';

  -- ...and once the line is live, the same call applies and resets the month.
  update public.phone_lines
     set status = 'active', sms_used = 42, voice_used_seconds = 900
   where id = v_line;
  r := public.apply_line_renewal('TX-PROV-1', 'TXN-1', now() + interval '30 days',
                                 null, null, null, null);
  if coalesce((r->>'ok')::boolean,false) is not true
     or coalesce((r->>'allowance_reset')::boolean,false) is not true then
    raise exception '2a FAILED: renewal did not apply: %', r;
  end if;
  select sms_used into v_used from public.phone_lines where id = v_line;
  if v_used <> 0 then raise exception '2b FAILED: allowance not reset (%)', v_used; end if;
  r := public.apply_line_renewal('TX-PROV-1', 'TXN-1', now() + interval '60 days',
                                 null, null, null, null);
  if coalesce(r->>'reason','') <> 'already_applied' then
    raise exception '2c FAILED: replay was not idempotent: %', r;
  end if;
  raise notice '2 OK  renewal applies when live, resets allowance, replay is a no-op';

  -- ── 3. Segment correction adjusts the allowance by the DIFFERENCE ─────────
  r := public.begin_outbound_message(u1, v_line, '+15550009999', 'hello', 1);
  if coalesce((r->>'ok')::boolean,false) is not true then
    raise exception '3a FAILED: begin_outbound_message: %', r;
  end if;
  v_msg := (r->>'message_id')::uuid;
  select sms_used into v_used from public.phone_lines where id = v_line;
  if v_used <> 1 then raise exception '3b FAILED: expected 1 segment spent, got %', v_used; end if;

  b := public.settle_outbound_message_claim(
         v_msg, 'PROV-1', 'sent'::public.line_msg_status, 0, null, 3, 0.004);
  select sms_used into v_used from public.phone_lines where id = v_line;
  if v_used <> 3 then raise exception '3c FAILED: expected 3 after correction, got %', v_used; end if;
  raise notice '3 OK  provider segment count corrects the allowance (1 -> 3)';

  -- ...and the exact cost survives where the rounded one is 0.
  select provider_cost_cents, provider_cost_usd into v_cents, v_usd
    from public.line_messages where id = v_msg;
  if v_cents <> 0 then raise exception '4a FAILED: expected 0 cents, got %', v_cents; end if;
  if v_usd <> 0.004 then raise exception '4b FAILED: exact cost lost, got %', v_usd; end if;
  raise notice '4 OK  $0.0040 rounds to 0 cents AND survives exactly as %', v_usd;

  -- ── 5. A failed send hands the whole thing back ───────────────────────────
  r := public.begin_outbound_message(u1, v_line, '+15550008888', 'bye', 2);
  v_msg := (r->>'message_id')::uuid;
  select sms_used into v_used from public.phone_lines where id = v_line;
  if v_used <> 5 then raise exception '5a FAILED: expected 5, got %', v_used; end if;
  b := public.settle_outbound_message_claim(
         v_msg, null, 'failed'::public.line_msg_status, null, 'x', null, null);
  select sms_used into v_used from public.phone_lines where id = v_line;
  if v_used <> 3 then raise exception '5b FAILED: allowance not returned, got %', v_used; end if;
  raise notice '5 OK  a failed send returns its segments';

  -- ── 6. attach_line_call_session: ownership and write-once ─────────────────
  r := public.record_line_call(v_line, 'outbound', '+15550007777', null,
                               'ringing'::public.line_call_status, 120);
  v_call := (r->>'call_id')::uuid;
  update public.phone_lines set voice_used_seconds = 120 where id = v_line;

  r := public.attach_line_call_session(u2, v_call, 'SESS-1', null, null, null, null);
  if coalesce(r->>'reason','') <> 'unknown_call' then
    raise exception '6a FAILED: another user could attach to this call: %', r;
  end if;

  r := public.attach_line_call_session(u1, v_call, 'SESS-1', 'LEG-1',
                                       'answered'::public.line_call_status, now(), 37);
  if coalesce((r->>'ok')::boolean,false) is not true then
    raise exception '6b FAILED: owner could not attach: %', r;
  end if;

  r := public.attach_line_call_session(u1, v_call, 'SESS-OTHER', null, null, null, null);
  if coalesce(r->>'reason','') <> 'session_conflict' then
    raise exception '6c FAILED: session id was repointed: %', r;
  end if;
  raise notice '6 OK  call session is owner-only and write-once';

  -- ── 7. settle_call_claim settles DOWN from the reservation ────────────────
  select voice_used_seconds into v_used from public.phone_lines where id = v_line;
  if v_used <> 120 then raise exception '7a FAILED: expected 120 reserved, got %', v_used; end if;
  b := public.settle_call_claim(v_call, 37, 0, 'completed'::public.line_call_status,
                                'normal', 0.0021);
  select voice_used_seconds into v_used from public.phone_lines where id = v_line;
  if v_used <> 37 then raise exception '7b FAILED: expected 37 after settle, got %', v_used; end if;
  b := public.settle_call_claim(v_call, 37, 0, 'completed'::public.line_call_status,
                                'normal', 0.0021);
  if b is not false then raise exception '7c FAILED: settle was not claim-gated'; end if;
  raise notice '7 OK  120s reservation settles down to 37s billed, once only';

  -- ── 8. settle_stale_calls rescues a call no CDR ever matched ──────────────
  r := public.record_line_call(v_line, 'outbound', '+15550006666', null,
                               'ringing'::public.line_call_status, 120);
  v_call2 := (r->>'call_id')::uuid;
  update public.phone_lines set voice_used_seconds = voice_used_seconds + 120
   where id = v_line;
  update public.line_calls set created_at = now() - interval '9 hours' where id = v_call2;
  select voice_used_seconds into v_used from public.phone_lines where id = v_line;
  if v_used <> 157 then raise exception '8a FAILED: expected 157, got %', v_used; end if;
  n := public.settle_stale_calls(360);
  select voice_used_seconds into v_used from public.phone_lines where id = v_line;
  if v_used <> 37 then raise exception '8b FAILED: stale reservation not returned, got %', v_used; end if;
  raise notice '8 OK  a call with no CDR gives its reservation back after 6h';

  -- ── 9. reclaim_lapsed_lines: the cancellation leak, and the lockout ───────
  insert into public.phone_lines (user_id, e164, country_code, number_type,
                                  status, hold_until, original_transaction_id)
  values (u3, '+15550002002', 'CA', 'local', 'suspended',
          now() - interval '1 day', 'TX-SUSP-1')
  returning id into v_line2;

  insert into public.phone_lines (user_id, e164, country_code, number_type,
                                  status, created_at, original_transaction_id)
  values (u4, '+15550003003', 'CA', 'local', 'provisioning',
          now() - interval '2 hours', 'TX-STUCK-1')
  returning id into v_line3;

  r := public.reclaim_lapsed_lines();

  select status into v_status from public.phone_lines where id = v_line2;
  if v_status <> 'releasing' then
    raise exception '9a FAILED: lapsed line not reclaimed, status %', v_status;
  end if;
  select status into v_status from public.phone_lines where id = v_line3;
  if v_status <> 'failed' then
    raise exception '9b FAILED: stuck provisioning not aged out, status %', v_status;
  end if;
  raise notice '9 OK  hold expiry -> releasing, stuck provisioning -> failed  (%)', r;

  -- ...and the freed user can rent again, which is the whole point of 9b.
  r := public.begin_line_rental(u4, '+15550003004', 'CA', 'local', 'TX-NEW-1', 'p');
  if coalesce((r->>'ok')::boolean,false) is not true then
    raise exception '10 FAILED: user still locked out after the sweep: %', r;
  end if;
  raise notice '10 OK  the freed user can rent again';

  -- ── 11. lines_awaiting_release finds exactly what release-lines drains ────
  select count(*) into n from public.lines_awaiting_release(50) where line_id = v_line2;
  if n <> 1 then raise exception '11 FAILED: reclaimed line not offered for release'; end if;
  raise notice '11 OK  the reclaimed line is queued for the provider DELETE';

  -- ── 12. A stale queued message hands its allowance back ──────────────────
  r := public.begin_outbound_message(u1, v_line, '+15550005555', 'stuck', 2);
  v_msg := (r->>'message_id')::uuid;
  update public.line_messages set created_at = now() - interval '1 hour' where id = v_msg;
  select sms_used into v_used from public.phone_lines where id = v_line;
  if v_used <> 5 then raise exception '12a FAILED: expected 5, got %', v_used; end if;
  r := public.reclaim_lapsed_lines();
  select sms_used into v_used from public.phone_lines where id = v_line;
  if v_used <> 3 then raise exception '12b FAILED: stale message allowance stuck at %', v_used; end if;
  raise notice '12 OK  a message stuck queued for 15m returns its segments';

  raise notice 'ALL 12 BEHAVIOURAL CHECKS PASSED';
end $$;

rollback;
