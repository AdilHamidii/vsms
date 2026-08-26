-- Watchdog: two OUTCOME checks. Both cover a subsystem that runs, returns 200,
-- writes its heartbeat on schedule, and produces nothing — which every existing
-- freshness check reads as healthy.
--
-- ⚠️ THE E-MAIL CHECK FIRES THE FIRST TIME THE WATCHDOG RUNS AFTER THIS IS
-- APPLIED. That is a TRUE POSITIVE, not a bug in the check: measured
-- 2026-08-26 over the trailing 14 days, gmail.com is 30 orders / **0 codes**
-- while outlook.com is 58 of 110 and hotmail.com 16 of 28. The paid tier has
-- delivered nothing since ~2026-08-10 and nobody knew. Expect the page.
--
-- ⚠️ BEFORE APPLYING: re-read `select max(version) from
-- supabase_migrations.schema_migrations` and SELECT the row back by name after
-- recording it. `20260826100000_email_free_grant_tombstone` was applied from a
-- parallel session BETWEEN two reads while this file was being written — which
-- is exactly the case where `on conflict (version) do nothing` swallows the
-- record and leaves two migrations claiming one version.
--
-- ⚠️ ALSO: `run_watchdog` below was regenerated from the LIVE definition on
-- 2026-08-26. Re-diff it against `pg_get_functiondef('public.run_watchdog')`
-- before applying — if another session added a fourth composed function, this
-- CREATE OR REPLACE would silently drop it.
--
-- ── Why a COMPANION function and not an edit to run_watchdog_core ────────────
-- Same reasoning as 20260818120000 (watchdog_money_checks): run_watchdog_core
-- is 14.8 KB of clauses, each of which encodes an incident, and this repo has
-- already turned a one-line refactor of it into a monitoring outage (the
-- 24h/>=10 delivery gate silently narrowed to 6h/>=8 and became unreachable).
-- `run_watchdog` already composes core || money, so adding a third composed
-- function keeps the diff to ONE line in a 520-byte function and leaves every
-- existing clause byte-identical.
--
-- ── Check 1: cdr-never-matched ──────────────────────────────────────────────
-- `sync-telnyx-cdr` has matched ZERO Telnyx detail records in the product's
-- history: app_config.telnyx_cdr_heartbeat reads {pages:4, records:0,
-- settled:0} — i.e. the request shape parses, all four record types answer 200,
-- and nothing ever comes back — while 12 line_calls rows carry a
-- provider_call_session_id. Every call therefore settles through the 6-hour
-- `settle_stale_calls` backstop at its flat reservation, which is the
-- documented over-bill-rather-than-under-bill fallback being used as the
-- PRIMARY billing path for 100% of calls. The existing 'sync-telnyx-cdr' check
-- only tests the heartbeat's updated_at, so a sweep that runs forever and
-- matches nothing stays green forever.
--
-- The recovery signal is NOT the heartbeat payload: it is per-run and
-- overwritten every ten minutes, so a single matched record would clear it and
-- the next quiet run would re-fire. The durable, cumulative evidence lives in
-- our own rows — a call settled from a detail record does NOT carry a
-- 'no_cdr%' hangup cause, because those three values ('no_cdr',
-- 'no_cdr_full', 'no_cdr_unreached') are written only by the backstop.
--
-- Asymmetric windows, deliberately: the RED condition looks at provider-reached
-- calls in the last 30 days (so an abandoned product goes quiet instead of
-- paging forever), while the RECOVERY condition looks at ALL history (one
-- CDR-settled call ever is proof the poller can match, and re-arming after that
-- would be noise). A NULL hangup_cause on a settled row does not count as
-- proof of a match — that keeps the check red rather than clearing it on an
-- ambiguity, which is the safe direction for a billing signal.
--
-- ── Check 2: email-domain-<domain> ──────────────────────────────────────────
-- Nothing has ever watched e-mail DELIVERY. `email_expiry_heartbeat` covers
-- only that the sweep is alive. The cross-domain condition is what makes this
-- a pool-health signal rather than a second alarm for a provider outage: it
-- fires only while at least one other domain is delivering in the same window,
-- so a total HeroSMS failure pages once (through the existing checks) and not
-- three more times here.
--
-- `code is not null` is the authority for "a code arrived", never
-- status = 'received' — the same rule as the SMS side's `otp is not null`.
-- Verified against live data on 2026-08-26: over the trailing 14 days the two
-- predicates agree on every row (0 received-without-code, 0 code-not-received),
-- so this is a correctness choice rather than a behavioural one today, and it
-- stays correct if a future path ever promotes a status without a code.
--
-- N = 8 over 14 days: at outlook.com's measured 53% and hotmail.com's 57%, the
-- probability of 8 consecutive failures on a healthy pool is under 1%, and the
-- free-tier volume clears 8 in days. Orders newer than 1 hour are excluded —
-- the provider window is ~21 minutes, so anything younger may simply still be
-- waiting and would be counted as a failure.

create or replace function public.watchdog_delivery_checks()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  fails jsonb := '[]'::jsonb;
  v_reached int;
  v_matched boolean;
  v_oldest timestamptz;
  v_email jsonb;
  -- The dev account, excluded from every outcome measurement in this file.
  v_dev uuid := '825688de-6117-4251-9f90-93b83b41b572';
begin
  -- ── (1) The CDR poller has never matched a provider record ────────────────
  select count(*), min(created_at)
    into v_reached, v_oldest
    from line_calls
   where created_at < now() - interval '24 hours'
     and created_at > now() - interval '30 days'
     and (provider_call_session_id is not null
          or provider_call_leg_id is not null);

  -- All-history proof that the poller CAN match. 'no_cdr%' is written only by
  -- the stale-call backstop; anything else came from a detail record.
  select exists (
    select 1 from line_calls
     where allowance_settled = true
       and (provider_call_session_id is not null
            or provider_call_leg_id is not null)
       and hangup_cause is not null
       and hangup_cause not like 'no\_cdr%'
  ) into v_matched;

  if coalesce(v_reached, 0) > 0 and not v_matched then
    fails := fails || jsonb_build_object(
      'check', 'cdr-never-matched',
      'detail', v_reached || ' call(s) reached Telnyx (oldest ' ||
                coalesce(v_oldest::text, '?') ||
                ') and sync-telnyx-cdr has never matched a single detail ' ||
                'record — every call is billed its flat reservation by the 6h backstop');
  end if;

  -- ── (2) An e-mail domain that delivers nothing while others do ────────────
  with agg as (
    select domain,
           count(*)                                  as n,
           count(*) filter (where code is not null)  as codes
      from email_orders
     where created_at >= now() - interval '14 days'
       and created_at <  now() - interval '1 hour'
       and user_id <> v_dev
     group by 1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'check', 'email-domain-' || a.domain,
           'detail', a.domain || ' delivered 0 codes in ' || a.n ||
                     ' orders over 14 days while other domains delivered — ' ||
                     'the address pool is dead, not the users')), '[]'::jsonb)
    into v_email
    from agg a
   where a.codes = 0
     and a.n >= 8
     and exists (select 1 from agg b where b.codes > 0);

  fails := fails || coalesce(v_email, '[]'::jsonb);

  return fails;
end;
$function$;

revoke execute on function public.watchdog_delivery_checks() from public, anon, authenticated;

-- ── run_watchdog: regenerated from the LIVE pg_get_functiondef (2026-08-26),
-- with exactly one added line (`extra2`). Everything else is byte-identical:
-- the core || money composition, the `prev` read, the alerted/last_alert_at
-- carry-forward and the on-conflict upsert onto app_config.'watchdog'.
create or replace function public.run_watchdog()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare fails jsonb; extra jsonb; extra2 jsonb; prev jsonb;
begin
  fails := public.run_watchdog_core();
  extra := public.watchdog_money_checks();
  extra2 := public.watchdog_delivery_checks();
  fails := fails || extra || extra2;
  select value into prev from app_config where key = 'watchdog';
  insert into app_config (key, value)
  values ('watchdog', jsonb_build_object('checked_at', now(), 'failing', fails,
    'alerted', coalesce(prev->'alerted','[]'::jsonb), 'last_alert_at', prev->>'last_alert_at'))
  on conflict (key) do update set value = excluded.value;
  return fails;
end; $function$;

revoke execute on function public.run_watchdog() from public, anon, authenticated;
