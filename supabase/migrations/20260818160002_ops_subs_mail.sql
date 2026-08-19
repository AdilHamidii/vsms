-- Task 9 (temp-e-mail subscription: ops visibility). Extends ops_subs() with
-- a 'mail' key so `/subs` in Telegram can render the e-mail subscription
-- line alongside the Second Number line.
--
-- ⚠️ PROCEDURE FOLLOWED PER CONTROLLER RULING, because this repo has already
-- lost a whole branch of a function by regenerating it from a truncated dump
-- (`run_watchdog`, 2026-07-27). The function below was produced by capturing
-- `pg_get_functiondef('public.ops_subs()'::regprocedure)` in full (confirmed
-- untruncated: dump length 5244 vs `prosrc` length 5092 — the gap is exactly
-- the CREATE-OR-REPLACE/AS-$function$ boilerplate, not a cut body), diffing
-- the new version against the captured original clause by clause, and
-- confirming EXACTLY ONE hunk differs — the new 'mail' key appended after
-- 'dev_hidden'. Nothing else in the function changed.
--
-- FIX ROUND 1 (2026-08-19): the original 'mail'.'active' predicate used
-- `coalesce(grace_expires_at, expires_at) > now()`, copied verbatim from the
-- task-9 brief -- which was itself wrong, because `has_email_subscription()`
-- (the real entitlement check) uses `greatest(expires_at, grace_expires_at)
-- > now()` for a specific reason: `coalesce` can read a stale grace stamp
-- ahead of a later, real renewal and report an entitled subscriber as
-- inactive. Fixed here to `greatest`, matching `has_email_subscription()`
-- exactly. Re-applied following the SAME procedure: captured
-- `pg_get_functiondef` first (dump length 5002 vs `prosrc` length 4850, gap
-- matches the boilerplate exactly -- not truncated), changed only that one
-- clause, diffed clause by clause, confirmed exactly one hunk.
--
-- ⚠️ ALSO ON THIS ROUND: the PREVIOUS live apply of this function is missing
-- every inline `--` comment that is in this file, even though this file's
-- comments were written before that apply. Postgres does not strip `--`
-- comments from `prosrc` for a traditional `LANGUAGE SQL AS $$ ... $$`
-- function body (this is not a `prosqlbody`/SQL-standard-body function,
-- which WOULD reparse and lose them) -- the comments were dropped because
-- the SQL actually sent to `execute_sql` on the previous round had been
-- copy-edited down to a comment-free version for brevity before running,
-- not because any tool in the path strips them. This round applies the
-- COMPLETE text of this file, comments included, verbatim, and the fix
-- report verifies the live `prosrc` contains them afterwards.
create or replace function public.ops_subs()
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  with dev as (select '825688de-6117-4251-9f90-93b83b41b572'::uuid as id),
  subs as (
    select * from public.line_subscriptions where user_id <> (select id from dev)
  ),
  lns as (
    select * from public.phone_lines where user_id <> (select id from dev)
  ),
  sub_states as (
    select state::text as state, count(*)::int as n from subs group by 1
  ),
  line_states as (
    select status::text as status, count(*)::int as n from lns group by 1
  ),
  -- `billing` splits Apple subscriptions from credit-billed rentals
  -- (20260806160000). Only the Apple half produces the MRR below, so a
  -- credit-billed line must not be counted into it.
  line_billing as (
    select billing, count(*)::int as n from lns group by 1
  ),
  active_subs as (select count(*)::int as n from subs where state = 'active'),
  -- What Apple actually billed, per currency, for the ACTIVE subscriptions.
  -- Printed next to the list-price estimate for the same reason /revenue prints
  -- the FX rate: the estimate must be auditable rather than asserted.
  active_billed as (
    select coalesce(currency,'?') as currency,
           sum(price_milli)::bigint as milli, count(*)::int as n
    from subs where state = 'active' and price_milli is not null
    group by 1
  ),
  notifs as (
    select notification_type, coalesce(subtype,'') as subtype, count(*)::int as n,
           count(*) filter (where processed_at is null)::int as unprocessed,
           count(*) filter (where process_error is not null)::int as errored
    from public.line_notifications
    where created_at >= now() - interval '7 days'
    group by 1, 2
  ),
  telnyx as (select value as v from public.app_config where key = 'telnyx_health'),
  devl as (
    select (select count(*)::int from public.phone_lines
              where user_id = (select id from dev)) as lines,
           (select count(*)::int from public.line_subscriptions
              where user_id = (select id from dev)) as subs
  )
  select jsonb_build_object(
    'subs_total',   (select count(*)::int from subs),
    'subs_active',  (select n from active_subs),
    'subs_by_state', coalesce((select jsonb_agg(jsonb_build_object(
                        'state', state, 'n', n) order by n desc, state)
                      from sub_states), '[]'::jsonb),
    -- One row per subscription, newest first, capped at 20 with an explicit
    -- remainder count (a silently truncated list reads as "that was
    -- everything" — same rule as /orders). auto_renew is trustworthy as of
    -- this migration; before it a client re-verify could reset a cancellation.
    'subs_list', coalesce((select jsonb_agg(row order by created_at desc)
                    from (
                      select jsonb_build_object(
                          'product', product_id, 'state', state::text,
                          'auto_renew', auto_renew,
                          'price_milli', price_milli, 'currency', currency,
                          'expires_at', expires_at, 'environment', environment,
                          'created_at', created_at) as row,
                        created_at
                      from subs
                      order by created_at desc
                      limit 20) t), '[]'::jsonb),
    'subs_not_shown', greatest(0, (select count(*)::int from subs) - 20),
    'lines_total',  (select count(*)::int from lns),
    'lines_by_status', coalesce((select jsonb_agg(jsonb_build_object(
                        'status', status, 'n', n) order by n desc, status)
                      from line_states), '[]'::jsonb),
    'lines_by_billing', coalesce((select jsonb_agg(jsonb_build_object(
                        'billing', billing, 'n', n) order by n desc, billing)
                      from line_billing), '[]'::jsonb),
    'monthly_cost_cents', (select coalesce(sum(monthly_cost_cents),0)::int from lns
                             where status in ('active','grace','past_due','provisioning','releasing')),
    -- offerType is still not persisted; the formatter renders price_milli = 0
    -- as a free period, labelled as an inference. This flag stays false so no
    -- consumer treats trial counts as first-class data.
    'trials_tracked', false,
    'active_billed', coalesce((select jsonb_agg(jsonb_build_object(
                        'currency', currency, 'milli', milli, 'n', n)
                        order by milli desc) from active_billed), '[]'::jsonb),
    'notifications_7d', coalesce((select jsonb_agg(jsonb_build_object(
                        'type', notification_type, 'subtype', subtype, 'n', n,
                        'unprocessed', unprocessed, 'errored', errored)
                        order by n desc, notification_type)
                      from notifs), '[]'::jsonb),
    'telnyx', jsonb_build_object(
                'balance_usd', (select (v->>'balance_usd')::numeric from telnyx),
                'checked_at',  (select v->>'checked_at' from telnyx)),
    'dev_hidden', jsonb_build_object(
                'lines', (select lines from devl),
                'subs',  (select subs from devl)),
    -- Task 9 (ops visibility for the temp-e-mail subscription line), fix
    -- round 1 (2026-08-19): 'active' now matches has_email_subscription()'s
    -- own predicate EXACTLY. The task-9 brief's snippet said `coalesce
    -- (grace_expires_at, expires_at) > now()`, which was already wrong the
    -- day it was written -- has_email_subscription() uses `greatest`, not
    -- `coalesce`, specifically because a subscriber who went through a grace
    -- period and then renewed carries a STALE grace_expires_at in the past
    -- alongside a fresh, later expires_at. `coalesce` picks whichever column
    -- is non-null FIRST regardless of which is later, so it would read the
    -- stale grace stamp and report a fully-paid renewed subscriber as
    -- inactive -- which would then fire the /subs disagreement warning on a
    -- perfectly healthy system, training the owner to ignore it. `greatest`
    -- compares both and ignores NULLs, so it agrees with the real
    -- entitlement check in every case. If you ever touch this again: this
    -- key must read `greatest`, never `coalesce`, and so must
    -- has_email_subscription() -- keep the two in lockstep.
    'mail', jsonb_build_object(
      'total',    (select count(*) from public.email_subscriptions),
      'active',   (select count(*) from public.email_subscriptions
                    where state in ('active','grace')
                      and greatest(expires_at, grace_expires_at) > now()),
      'by_state', (select coalesce(jsonb_agg(jsonb_build_object('state', state, 'n', n)), '[]'::jsonb)
                     from (select state, count(*) n from public.email_subscriptions
                            group by 1 order by 2 desc) s),
      'auto_renew_on', (select count(*) from public.email_subscriptions
                         where auto_renew and state in ('active','grace'))
    )
  );
$function$;

revoke execute on function public.ops_subs() from public, anon, authenticated;

do $$
begin
  if has_function_privilege('anon', 'public.ops_subs()', 'execute') then
    raise exception 'ops_subs is callable by anon';
  end if;
end $$;

comment on function public.ops_subs() is
  'Reporting for /subs (Telegram). Second Number lines/subs plus, as of 20260818160002, the temp-e-mail subscription totals under the mail key. Read-only, SECURITY DEFINER, revoked from anon/authenticated.';
