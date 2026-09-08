-- Watch the rescue sweep. A scheduled job with no freshness signal and no
-- check is this repo's most repeated outage shape — `reclaim_lapsed_lines`
-- shipped scheduled in no cron job at all and leaked $1/month per cancelled
-- subscriber, discoverable only on the Telnyx invoice.
--
-- 🔴 TWO CHECKS, AND THE SECOND IS THE LOAD-BEARING ONE. A heartbeat proves
-- the sweep RAN; it cannot prove the sweep WORKED. `sync-telnyx-cdr` ran every
-- ten minutes for twenty days matching nothing, perfectly green, because the
-- only check tested its heartbeat. So the second check reads the STATE — is
-- anyone paying us for a number they do not have — and it fires even if the
-- heartbeat is never written, which is exactly the case that ships broken.

create or replace function public.watchdog_line_rescue_checks()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  fails     jsonb := '[]'::jsonb;
  v_checked timestamptz;
  v_have    boolean;
  v_stuck   int;
  v_who     text;
begin
  -- ── (1) The sweep has stopped ────────────────────────────────────────────
  -- A scalar subquery, not `select … into … from app_config`: an INTO that
  -- matches no row writes NULL over the variable, so a deleted key would
  -- silently disarm the comparison. Same shape as the line-catalog check.
  select true, (value->>'checked_at')::timestamptz
    into v_have, v_checked
    from app_config where key = 'line_rescue_heartbeat';

  -- The cron runs at :08/:23/:38/:53, so 45 minutes is three missed runs —
  -- late enough not to page on one slow invocation, early enough that a
  -- paying customer is not waiting a day.
  if coalesce(v_have, false) is not true
     or v_checked is null
     or v_checked < now() - interval '45 minutes' then
    fails := fails || jsonb_build_object(
      'check', 'line-rescue-stale',
      'detail', 'the rescue sweep heartbeat is ' ||
                coalesce('from ' || v_checked::text, 'missing entirely') ||
                ' — a subscriber who paid and never received a number would ' ||
                'not be provisioned');
  end if;

  -- ── (2) 🔴 THE STATE ITSELF ──────────────────────────────────────────────
  -- Someone is paying and holds nothing. Two hours, not thirty minutes: the
  -- sweep's own window is 30 minutes and a rescue takes several provider
  -- calls, so anything under an hour would page on the normal path working.
  -- The entitlement predicate is byte-identical to
  -- `line_unprovisioned_subscriptions` and to `has_email_subscription` —
  -- NEVER coalesce, or a renewed subscriber carrying a stale
  -- `grace_expires_at` reads as inactive.
  select count(*), string_agg(s.original_transaction_id, ', ')
    into v_stuck, v_who
    from line_subscriptions s
   where s.environment = 'Production'
     and s.state in ('active','grace')
     and greatest(s.expires_at, s.grace_expires_at) > now()
     and s.created_at < now() - interval '2 hours'
     and not exists (
       select 1 from phone_lines l
        where l.user_id = s.user_id
          and l.billing = 'apple'
          and l.status in ('provisioning','active','grace','past_due',
                           'suspended','releasing'));

  if coalesce(v_stuck, 0) > 0 then
    fails := fails || jsonb_build_object(
      'check', 'line-paid-no-number',
      'detail', v_stuck || ' live subscription(s) with no number: ' ||
                left(coalesce(v_who, ''), 200) ||
                ' — they are paying for nothing. Check the Telnyx balance ' ||
                'first; a number order is refused outright below it');
  end if;

  return fails;
end;
$$;

revoke execute on function public.watchdog_line_rescue_checks()
  from public, anon, authenticated;

-- ── Hook it in ────────────────────────────────────────────────────────────
-- `run_watchdog` regenerated from `pg_get_functiondef`; the ONLY differences
-- are the `extra4` declaration, its assignment, and its term in the
-- concatenation. Every other clause is byte-identical — a one-line refactor
-- that changes a watchdog is a monitoring outage, and this repo has shipped
-- one already.
create or replace function public.run_watchdog()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare fails jsonb; extra jsonb; extra2 jsonb; extra3 jsonb; extra4 jsonb; prev jsonb;
begin
  fails := public.run_watchdog_core();
  extra := public.watchdog_money_checks();
  extra2 := public.watchdog_delivery_checks();
  extra3 := public.watchdog_line_catalog_checks();
  extra4 := public.watchdog_line_rescue_checks();
  fails := fails || extra || extra2 || extra3 || extra4;
  select value into prev from app_config where key = 'watchdog';
  insert into app_config (key, value)
  values ('watchdog', jsonb_build_object('checked_at', now(), 'failing', fails,
    'alerted', coalesce(prev->'alerted','[]'::jsonb), 'last_alert_at', prev->>'last_alert_at'))
  on conflict (key) do update set value = excluded.value;
  return fails;
end;
$$;

revoke execute on function public.run_watchdog() from public, anon, authenticated;
