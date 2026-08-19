-- Two fixes from the final pre-merge review of the temp-e-mail subscription
-- branch (2026-08-19). Both are SQL-side because that is where they protect
-- every future caller rather than one edge function.
--
-- ── 1. A stored JWS must not resurrect a REFUNDED entitlement ───────────────
--
-- `verify-email-subscription` posts `p_state := 'active'` unconditionally --
-- it is the client's purchase call, and a client cannot know a state. The
-- `ON CONFLICT` below then overwrites `state` with it. So replaying a JWS the
-- device still holds AFTER a REFUND/REVOKE (Apple keeps serving the entitlement
-- in `currentEntitlements` for a while, and the raw JWS is trivially
-- re-postable in any case) silently upgraded `revoked` back to `active` and
-- handed the entitlement back to someone Apple had already refunded.
--
-- The guard lives here, not in the edge function, for the reason this repo
-- keeps re-learning: a rule enforced in TypeScript is enforced for exactly the
-- callers that exist today.
--
-- 🔴 THE TWO TERMINAL STATES NEED DIFFERENT RULES, and collapsing them would
-- break a legitimate flow:
--
--   * `revoked` is terminal FROM THIS PATH, full stop. Apple owns un-revoking:
--     a genuine re-subscribe after a refund arrives as a SUBSCRIBED
--     notification, which `apple-notifications` writes with a direct UPDATE
--     and never through this function. So refusing here cannot strand a
--     paying subscriber -- the ASSN handler still activates them.
--
--   * `expired` must stay re-activatable, because re-subscribing after a lapse
--     is ORDINARY and Apple reuses the same `original_transaction_id` for it.
--     Refusing it outright would permanently lock out every returning
--     customer. What separates a real re-subscribe from a replay is the
--     EXPIRY: a genuine one carries a period end in the future, a replayed old
--     JWS carries one in the past. So `expired` -> `active` is allowed only
--     when `p_expires_at` is genuinely still in the future.
--
-- Rows with no existing state (a first purchase) are untouched by all of this.
--
-- ── 2. `ops_subs()`'s mail block counted the DEV ACCOUNT ────────────────────
--
-- Every other figure in that function excludes it. See the CTE comment below.

create or replace function public.record_email_subscription(
  p_original_tx  text,
  p_user         uuid,
  p_product      text,
  p_state        public.line_sub_state,
  p_auto_renew   boolean,
  p_environment  text,
  p_expires_at   timestamptz,
  p_last_tx      text,
  p_signed_tx    text default null,
  p_storefront   text default null,
  p_price_milli  bigint default null,
  p_currency     text default null
) returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_bound uuid;
  v_state public.line_sub_state;
begin
  if p_original_tx is null or p_user is null or p_product is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  -- THE replay check. A subscription already bound to a DIFFERENT user means
  -- the same Apple entitlement is being presented by a second account, which
  -- is what deleting and re-creating an account produces.
  select user_id, state into v_bound, v_state from public.email_subscriptions
   where original_transaction_id = p_original_tx;
  if v_bound is not null and v_bound <> p_user then
    return jsonb_build_object('ok', false, 'reason', 'subscription_bound');
  end if;

  -- 🔴 A TERMINAL STATE MAY NOT BE UPGRADED BACK TO `active` FROM HERE. See
  -- the header: `revoked` is absolute (Apple's own notification re-activates a
  -- genuine re-subscribe), `expired` is allowed only when the submitted period
  -- has genuinely not ended yet. Refusals, not errors -- the caller returns
  -- 409, exactly like `subscription_bound`.
  if p_state = 'active' and v_state = 'revoked' then
    return jsonb_build_object('ok', false, 'reason', 'subscription_revoked');
  end if;
  if p_state = 'active' and v_state = 'expired'
     and (p_expires_at is null or p_expires_at <= now()) then
    return jsonb_build_object('ok', false, 'reason', 'subscription_expired');
  end if;

  insert into public.email_subscriptions (
    original_transaction_id, user_id, product_id, state, auto_renew,
    environment, expires_at, last_transaction_id, latest_signed_transaction,
    storefront, price_milli, currency)
  values (
    p_original_tx, p_user, p_product, p_state, coalesce(p_auto_renew, true),
    coalesce(p_environment, 'Production'), p_expires_at, p_last_tx, p_signed_tx,
    p_storefront, p_price_milli, p_currency)
  on conflict (original_transaction_id) do update
    set state       = excluded.state,
        auto_renew  = excluded.auto_renew,
        expires_at  = excluded.expires_at,
        product_id  = excluded.product_id,
        -- coalesce so a notification that omits these does not WIPE what the
        -- purchase recorded: ASSN payloads legitimately carry less than the
        -- original transaction did.
        last_transaction_id       = coalesce(excluded.last_transaction_id,
                                             email_subscriptions.last_transaction_id),
        latest_signed_transaction = coalesce(excluded.latest_signed_transaction,
                                             email_subscriptions.latest_signed_transaction),
        storefront   = coalesce(excluded.storefront, email_subscriptions.storefront),
        price_milli  = coalesce(excluded.price_milli, email_subscriptions.price_milli),
        currency     = coalesce(excluded.currency, email_subscriptions.currency),
        updated_at   = now();

  return jsonb_build_object('ok', true);
end;
$fn$;

revoke execute on function public.record_email_subscription(
  text, uuid, text, public.line_sub_state, boolean, text, timestamptz, text,
  text, text, bigint, text) from public, anon, authenticated;

-- ── ops_subs(): the mail block now excludes the dev account ─────────────────
-- Procedure per the standing rule (a regenerated function has already lost a
-- whole branch once, run_watchdog 2026-07-27): `pg_get_functiondef` was
-- captured in full and diffed line by line against 20260818160002 -- the two
-- were IDENTICAL apart from Postgres upper-casing the CREATE header, so that
-- file is the true baseline and the text below is that file with exactly
-- FOUR hunks: the new `mail_subs` CTE, the four `public.email_subscriptions`
-- references inside the `mail` key repointed at it, `devl` gaining a
-- `mail_subs` count, and `dev_hidden` rendering it. Nothing else changed.

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
  'Reporting for /subs (Telegram). Second Number lines/subs plus the temp-e-mail subscription totals under the mail key. The dev account is excluded from every figure and reported separately under dev_hidden. Read-only, SECURITY DEFINER, revoked from anon/authenticated.';
