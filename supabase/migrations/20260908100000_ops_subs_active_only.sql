-- /subs answers ONE question: which subscriptions are live right now, when
-- does each end, and how much is each paying per month. (Owner decision,
-- 2026-09-08.)
--
-- The previous rendering was subscription STATE counts against LINE status
-- counts plus a mail summary — a reconciliation view, not an answer. Nothing
-- in it listed the mail subscribers individually, and the line list showed
-- every row including expired/revoked ones.
--
-- ONE new CTE and ONE new key; nothing existing is removed, so the divergence
-- warning and every other consumer of this payload keep working.
-- Procedure per the standing rule: `pg_get_functiondef` captured in full
-- (dump 8392 vs prosrc 8240, gap 152 — the CREATE/AS boilerplate, byte-for-
-- byte the same gap as every prior round, so not truncated) and the live
-- prosrc verified md5-identical to 20260818160004's body before editing.
-- The text below is that body with exactly the two hunks marked in it.

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
  -- Every other count in this function excludes the dev account; the mail
  -- block shipped in 20260818160002 did not, so the owner's own test
  -- subscriptions were counted as customers in `/subs` while the line
  -- figures beside them excluded them. Same CTE shape as `subs`/`lns`, and
  -- the dev totals move to `dev_hidden` below so they are still visible.
  mail_subs as (
    select * from public.email_subscriptions where user_id <> (select id from dev)
  ),
  -- HUNK 1 (20260908100000): the ENTITLED set across BOTH subscription
  -- families, in one shape. `/subs` answers "which subscriptions are live
  -- right now, when does each end, what is each paying" and nothing else, so
  -- it needs the two groups side by side rather than a line list plus a mail
  -- summary. The predicate is byte-identical to has_email_subscription()'s
  -- and to the 'mail'->'active' key below: state in ('active','grace') AND
  -- greatest(expires_at, grace_expires_at) > now(). `greatest`, NEVER
  -- `coalesce` — a subscriber who went through a grace period and then
  -- renewed carries a STALE grace_expires_at in the past alongside a fresh,
  -- later expires_at, and coalesce picks whichever is non-null FIRST, which
  -- would report a fully-paid renewed subscriber as inactive.
  -- `ends_at` is that same greatest(), i.e. the moment the entitlement
  -- actually lapses, not the raw expires_at. Both CTEs already exclude the
  -- dev account.
  active_all as (
    select 'line' as family, original_transaction_id, product_id,
           state::text as state, auto_renew, price_milli, currency, environment,
           greatest(expires_at, grace_expires_at) as ends_at
      from subs
     where state in ('active','grace')
       and greatest(expires_at, grace_expires_at) > now()
    union all
    select 'mail', original_transaction_id, product_id,
           state::text, auto_renew, price_milli, currency, environment,
           greatest(expires_at, grace_expires_at)
      from mail_subs
     where state in ('active','grace')
       and greatest(expires_at, grace_expires_at) > now()
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
              where user_id = (select id from dev)) as subs,
           (select count(*)::int from public.email_subscriptions
              where user_id = (select id from dev)) as mail_subs
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
    -- HUNK 2 (20260908100000): the payload `/subs` now renders. Soonest
    -- expiry first, because the question is "what ends next". Uncapped here
    -- (the whole entitled set is small by construction — one live line per
    -- user); the FORMATTER caps and prints "... and N more".
    'active_subs', coalesce((select jsonb_agg(jsonb_build_object(
                      'family', family, 'product', product_id, 'state', state,
                      'auto_renew', auto_renew, 'price_milli', price_milli,
                      'currency', currency, 'environment', environment,
                      'ends_at', ends_at) order by ends_at)
                    from active_all), '[]'::jsonb),
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
                'subs',  (select subs from devl),
                'mail_subs', (select mail_subs from devl)),
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
      'total',    (select count(*) from mail_subs),
      'active',   (select count(*) from mail_subs
                    where state in ('active','grace')
                      and greatest(expires_at, grace_expires_at) > now()),
      'by_state', (select coalesce(jsonb_agg(jsonb_build_object('state', state, 'n', n)), '[]'::jsonb)
                     from (select state, count(*) n from mail_subs
                            group by 1 order by 2 desc) s),
      'auto_renew_on', (select count(*) from mail_subs
                         where auto_renew and state in ('active','grace')),
      -- The LIVE kill switch, read with the SAME predicate `begin_email_order`
      -- uses (`(value #>> '{}')::boolean`, defaulting false on a missing or
      -- unreadable row) so `/subs` and the order path can never disagree about
      -- whether the wall is up. The formatter used to hardcode "enforcement is
      -- OFF" -- true the day it was written and a lie the moment the flag is
      -- flipped, which is precisely the moment the owner is reading /subs to
      -- check.
      'enforced', coalesce((select (value #>> '{}')::boolean
                              from public.app_config
                             where key = 'email_subscription_enforced'), false)
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
  'Ops-bot /subs payload. active_subs is the ENTITLED set across BOTH '
  'subscription families (line + mail): state in (active,grace) AND '
  'greatest(expires_at, grace_expires_at) > now() -- the same predicate as '
  'has_email_subscription(). NEVER coalesce. Service role only.';
