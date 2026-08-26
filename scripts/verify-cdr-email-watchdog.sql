-- verify-cdr-email-watchdog.sql — BEHAVIOURAL checks for the two outcome
-- checks added by 20260826140000_watchdog_delivery_checks.sql.
--
-- Run AFTER applying that migration:
--   supabase db query --linked --file scripts/verify-cdr-email-watchdog.sql
-- or paste into the SQL editor. Everything happens inside ONE transaction that
-- ends in ROLLBACK, so the temporary rows and edits below never persist.
--
-- ⚠️ It is not read-only: groups 1–4 only READ, but groups 5–8 MUTATE live
-- rows to simulate recovery and outage states. Each is bracketed by
-- `rollback to savepoint before_mutation`, so every group starts from the real
-- live state rather than from the previous group's edits, and the whole thing
-- ends in ROLLBACK. Do not run it under autocommit, and do not comment out the
-- final ROLLBACK.
--
-- Why behavioural and not structural: a structural check proves a function
-- exists. This repo's scars are all functions that existed, ran, returned 200
-- and matched nothing — an ON CONFLICT that could not reach its own index, a
-- watchdog clause whose threshold was above the achievable volume, a guard
-- reading a config key nobody writes. The only thing that catches those is
-- evaluating the predicate and reading what comes back.

begin;

-- ── 1. The function exists, is service-role only, and returns a JSON array ──
do $$
declare v jsonb;
begin
  v := public.watchdog_delivery_checks();
  if jsonb_typeof(v) <> 'array' then
    raise exception 'FAIL 1a: watchdog_delivery_checks did not return a jsonb array (got %)', jsonb_typeof(v);
  end if;
  if has_function_privilege('anon', 'public.watchdog_delivery_checks()', 'execute')
     or has_function_privilege('authenticated', 'public.watchdog_delivery_checks()', 'execute') then
    raise exception 'FAIL 1b: watchdog_delivery_checks is executable by anon/authenticated';
  end if;
  raise notice 'PASS 1: function exists, returns an array, service-role only';
end $$;

-- ── 2. run_watchdog actually composes it ────────────────────────────────────
-- The companion function is worthless if nothing calls it. This is the same
-- failure class as `reclaim_lapsed_lines()` shipping scheduled in no cron job,
-- and as the six line_subscriptions updaters that shipped with no INSERT.
do $$
declare src text;
begin
  select prosrc into src from pg_proc where proname = 'run_watchdog'
    and pronamespace = 'public'::regnamespace;
  if src not like '%watchdog_delivery_checks%' then
    raise exception 'FAIL 2: run_watchdog does not call watchdog_delivery_checks';
  end if;
  if src not like '%run_watchdog_core%' or src not like '%watchdog_money_checks%' then
    raise exception 'FAIL 2: run_watchdog lost core or money checks';
  end if;
  raise notice 'PASS 2: run_watchdog composes core + money + delivery';
end $$;

-- ── 3. AGAINST LIVE DATA, both defects are reported ─────────────────────────
-- This is the assertion that would have been meaningless a week ago and is the
-- point of the whole migration: both checks fire RIGHT NOW, on real rows,
-- because both defects are real and live.
--
-- ⚠️ Group 3 is the one part of this file that depends on production state. If
-- the CDR poller is fixed, 3a stops firing and that is a PASS of a different
-- kind — read the notice, do not "fix" the assertion.
do $$
declare v jsonb; checks text[];
begin
  v := public.watchdog_delivery_checks();
  select array_agg(x->>'check') into checks from jsonb_array_elements(v) x;
  raise notice 'live failing checks: %', coalesce(checks::text, '{}');

  if not (checks @> array['cdr-never-matched']) then
    raise notice 'NOTE 3a: cdr-never-matched is NOT firing. Either sync-telnyx-cdr has finally matched a record (check line_calls for a hangup_cause that is not no_cdr%%), or no call has reached Telnyx in the last 30 days.';
  else
    raise notice 'PASS 3a: cdr-never-matched fires on live data (expected — the defect is live)';
  end if;

  if not exists (select 1 from unnest(coalesce(checks, '{}')) c where c like 'email-domain-%') then
    raise notice 'NOTE 3b: no email-domain check is firing. Expected gmail.com as of 2026-08-26 (30 orders / 0 codes in 14d).';
  else
    raise notice 'PASS 3b: an email-domain check fires on live data (expected — gmail.com)';
  end if;
end $$;

-- ── 4. The e-mail check names the DEAD domain and only the dead domain ──────
do $$
declare v jsonb; checks text[]; dead text[]; alive text[];
begin
  v := public.watchdog_delivery_checks();
  select array_agg(x->>'check') into checks from jsonb_array_elements(v) x;

  -- Every domain the check COULD have flagged, computed independently of the
  -- function so a shared bug cannot make both agree on the wrong answer.
  select array_agg(domain) into dead from (
    select domain from email_orders
     where created_at >= now() - interval '14 days'
       and created_at <  now() - interval '1 hour'
       and user_id <> '825688de-6117-4251-9f90-93b83b41b572'
     group by domain
    having count(*) >= 8 and count(*) filter (where code is not null) = 0) d;

  select array_agg(domain) into alive from (
    select domain from email_orders
     where created_at >= now() - interval '14 days'
       and created_at <  now() - interval '1 hour'
       and user_id <> '825688de-6117-4251-9f90-93b83b41b572'
     group by domain
    having count(*) filter (where code is not null) > 0) a;

  if alive is null then
    raise notice 'SKIP 4: no domain delivered in the window — the cross-domain guard correctly suppresses everything';
  else
    if coalesce(array_length(dead, 1), 0) > 0
       and not (checks @> array['email-domain-' || dead[1]]) then
      raise exception 'FAIL 4a: % has >=8 orders and 0 codes but was not flagged', dead[1];
    end if;
    -- and nothing healthy was flagged
    if exists (select 1 from unnest(alive) a
                where checks @> array['email-domain-' || a]) then
      raise exception 'FAIL 4b: a delivering domain was flagged';
    end if;
    raise notice 'PASS 4: flagged exactly the dead domain(s) %, spared the delivering ones %', dead, alive;
  end if;
end $$;

savepoint before_mutation;

-- ── 5. RECOVERY: one CDR-settled call clears cdr-never-matched ──────────────
-- Mutates, then rolls back with the transaction. `no_cdr%` is written ONLY by
-- the stale-call backstop, so any other hangup cause on a settled, provider-
-- reached call is proof the poller matched a detail record.
do $$
declare v jsonb; checks text[]; n int;
begin
  update line_calls
     set hangup_cause = 'normal_clearing'
   where id = (select id from line_calls
                where allowance_settled = true
                  and provider_call_session_id is not null
                order by created_at desc limit 1);
  get diagnostics n = row_count;
  if n = 0 then
    raise notice 'SKIP 5: no settled provider-reached call to simulate against';
  else
    v := public.watchdog_delivery_checks();
    select array_agg(x->>'check') into checks from jsonb_array_elements(v) x;
    if checks @> array['cdr-never-matched'] then
      raise exception 'FAIL 5: cdr-never-matched still fires after a CDR-settled call exists';
    end if;
    raise notice 'PASS 5: one CDR-settled call clears cdr-never-matched';
  end if;
end $$;

rollback to savepoint before_mutation;

-- ── 6. SILENCE: no provider-reached call ⇒ no CDR page ──────────────────────
-- A check that pages about a subsystem with no work is how alert fatigue
-- starts, and this whole product line is one test line today.
do $$
declare v jsonb; checks text[];
begin
  update line_calls set provider_call_session_id = null, provider_call_leg_id = null
   where created_at < now() - interval '24 hours';
  v := public.watchdog_delivery_checks();
  select array_agg(x->>'check') into checks from jsonb_array_elements(v) x;
  if coalesce(checks, '{}') @> array['cdr-never-matched'] then
    raise exception 'FAIL 6: cdr-never-matched fires with no provider-reached call';
  end if;
  raise notice 'PASS 6: silent when nothing reached Telnyx';
end $$;

rollback to savepoint before_mutation;

-- ── 7. RECOVERY + the cross-domain guard, on the e-mail side ────────────────
do $$
declare v jsonb; checks text[]; dead text;
begin
  select domain into dead from email_orders
   where created_at >= now() - interval '14 days'
     and created_at <  now() - interval '1 hour'
     and user_id <> '825688de-6117-4251-9f90-93b83b41b572'
   group by domain
  having count(*) >= 8 and count(*) filter (where code is not null) = 0
   limit 1;

  if dead is null then
    raise notice 'SKIP 7: no dead domain to recover';
  else
    -- (a) ONE delivered code clears that domain.
    update email_orders set code = '123456'
     where id = (select id from email_orders
                  where domain = dead
                    and created_at >= now() - interval '14 days'
                    and created_at <  now() - interval '1 hour'
                  order by created_at desc limit 1);
    v := public.watchdog_delivery_checks();
    select array_agg(x->>'check') into checks from jsonb_array_elements(v) x;
    if coalesce(checks, '{}') @> array['email-domain-' || dead] then
      raise exception 'FAIL 7a: % still flagged after delivering a code', dead;
    end if;
    raise notice 'PASS 7a: one delivered code clears email-domain-%', dead;

    -- (b) THE CROSS-DOMAIN GUARD. Put the domain back to zero, then take every
    -- OTHER domain to zero as well — a global HeroSMS outage. Nothing may fire
    -- here: that failure is the existing checks' job, and paging three more
    -- times for one incident is exactly the alert fatigue this file keeps
    -- warning about.
    update email_orders set code = null
     where created_at >= now() - interval '14 days'
       and created_at <  now() - interval '1 hour';
    v := public.watchdog_delivery_checks();
    select array_agg(x->>'check') into checks from jsonb_array_elements(v) x;
    if exists (select 1 from unnest(coalesce(checks, '{}')) c where c like 'email-domain-%') then
      raise exception 'FAIL 7b: an email-domain check fired during a GLOBAL outage — the cross-domain guard is not working';
    end if;
    raise notice 'PASS 7b: silent during a global outage (cross-domain guard holds)';
  end if;
end $$;

rollback to savepoint before_mutation;

-- ── 8. In-flight orders are not counted as failures ─────────────────────────
-- The provider window is ~21 minutes; an order 5 minutes old has not failed,
-- it is waiting. Without the 1-hour floor a burst of fresh orders on a healthy
-- domain would page.
do $$
declare v jsonb; checks text[]; d text := 'probe-fresh.example';
begin
  insert into email_orders (user_id, site, domain, email, status, cost_credits, created_at)
  select u.user_id, 'probe.example', d, 'probe-' || gs || '@' || d,
         'waiting'::email_status, 0, now() - interval '5 minutes'
    from (select user_id from email_orders
           where user_id <> '825688de-6117-4251-9f90-93b83b41b572'
           limit 1) u,
         generate_series(1, 12) gs;
  v := public.watchdog_delivery_checks();
  select array_agg(x->>'check') into checks from jsonb_array_elements(v) x;
  if coalesce(checks, '{}') @> array['email-domain-' || d] then
    raise exception 'FAIL 8: 12 orders placed 5 minutes ago were counted as delivery failures';
  end if;
  raise notice 'PASS 8: orders younger than 1 hour are excluded';
exception when others then
  -- The INSERT depends on email_orders' NOT NULL set, which this script does
  -- not own. A schema mismatch here is a skipped check, never a false pass.
  if sqlstate = 'P0001' then raise; end if;
  raise notice 'SKIP 8: could not synthesise fresh orders (%) — assert the 1-hour floor by reading the function body', sqlerrm;
end $$;

rollback to savepoint before_mutation;
rollback;

-- ════════════════════════════════════════════════════════════════════════════
-- POST-REDEPLOY ASSERTIONS for the CDR fix (2026-08-26). Read-only, run these
-- AFTER redeploying the _shared/telnyx.ts consumers and letting one
-- relay-sync-telnyx-cdr run (*/10). They are commented out because they belong
-- outside the transaction above.
--
-- 🔴 DO NOT EXPECT THE 2026-08-24 CALLS TO SETTLE. They were already written
-- off by the 6h backstop, so `allowance_settled = true` and the pending query
-- (`allowance_settled = false`, last 24h) cannot see them. THE FIRST RUN PROVES
-- THE FETCH, NOT THE SETTLEMENT — settlement needs a NEW call. Anyone reading
-- "settled: 0" as failure will revert a working fix.
--
-- (1) The heartbeat. BEFORE: {pages:4, records:0, settled:0}. AFTER, expect
--     raw_rows ≈ 93 (43 webrtc + 50 sip-trunking), records ≈ 50 after merging
--     the two record types per call, window 'last_30_days', types listing
--     webrtc and sip-trunking, pending 0, settled 0.
--     ⚠️ raw_rows > 0 with records = 0 means the id fields are STILL wrong.
--
-- select value from public.app_config where key = 'telnyx_cdr_heartbeat';
--
-- (2) The probe key must now hold a session id that EXISTS in line_calls. This
--     is the assertion that actually proves the bug is dead: before the fix it
--     would have held 5ea3db0a-… (the SDK's uuid), which matches nothing.
--
-- select value->'parsed'->>'sessionId' as parsed_session,
--        exists (select 1 from public.line_calls
--                 where provider_call_session_id = value->'parsed'->>'sessionId')
--          as matches_a_real_call
--   from public.app_config where key = 'telnyx_cdr_probe';
--
-- (3) The watchdog check added above stays RED until a call settles from a
--     detail record — which is correct, and is the point. Expect
--     cdr-never-matched to still be listed here on the first run.
--
-- select public.watchdog_delivery_checks();
--
-- (4) After the NEXT real outbound call (place one, hang up, wait ~10-20 min
--     for the CDR plus one sweep), that call's row must show provider
--     evidence rather than a backstop write:
--       hangup_cause  → 'NORMAL_CLEARING' (or another Telnyx cause), NOT 'no_cdr%'
--       billed_seconds→ the real connected seconds (call_sec), NOT a flat 120
--       provider_cost_usd / cost → the SUM of the webrtc and sip-trunking legs
--     and `watchdog_delivery_checks()` must stop reporting cdr-never-matched.
--
-- select id, status, hangup_cause, billed_seconds, allowance_settled, created_at
--   from public.line_calls order by created_at desc limit 5;
--
-- (5) OPTIONAL, owner decision, NOT part of this change: the 11 historical
--     calls stay mis-billed (flat 120s) because nothing re-opens a settled row.
--     Correcting them means clearing `allowance_settled` on those ids so the
--     next sweep re-settles from the real records. No credits moved on them
--     (`credits_reserved = 0` on every row), so this is a data-accuracy
--     correction, not a refund — do it deliberately or not at all.
