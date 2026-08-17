-- 20260815100000_line_sub_truth.sql
--
-- Two things, both found because the App Store panel showed 2 cancelled trials
-- while our DB showed 1:
--
-- 1. `record_line_subscription` clobbered `auto_renew` back to true on every
--    client re-verify. The signed transaction the CLIENT submits carries no
--    auto-renew status at all (that lives in Apple's renewal-info JWS, which
--    only ASSN delivers), yet verify-line-subscription hardcodes
--    `p_auto_renew: true` and the upsert wrote `excluded.auto_renew`. Sequence
--    observed live 2026-08-15: 00:21:33 ASSN AUTO_RENEW_DISABLED wrote false;
--    00:21:41 a StoreKit-update re-verify wrote it back to true. ASSN is the
--    only authority on this column — the upsert now PRESERVES the existing
--    value and p_auto_renew only seeds the first insert.
--
-- 2. `ops_subs()` had no per-subscription view, so /subs could not answer
--    "which subs are running vs cancelled, and on which plan". It now returns
--    `subs_list` (newest first, capped at 20). `price_milli = 0` on an active
--    sub is rendered as a free period by the formatter — `offerType` is still
--    not persisted, so that heuristic lives in the formatter, labelled, rather
--    than being asserted as a column here.

create or replace function public.record_line_subscription(
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
declare v_bound uuid;
begin
  if p_original_tx is null or p_user is null or p_product is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  -- THE replay check, and the reason this returns {ok,reason} rather than
  -- upserting blindly. A subscription already bound to a DIFFERENT user means
  -- the same Apple entitlement is being presented by a second account — which
  -- is exactly what deleting and re-creating an account produces. Rebinding it
  -- would hand the new account a number while the old one keeps billing.
  select user_id into v_bound from public.line_subscriptions
   where original_transaction_id = p_original_tx;
  if v_bound is not null and v_bound <> p_user then
    return jsonb_build_object('ok', false, 'reason', 'subscription_bound');
  end if;

  insert into public.line_subscriptions (
    original_transaction_id, user_id, product_id, state, auto_renew,
    environment, expires_at, last_transaction_id, latest_signed_transaction,
    storefront, price_milli, currency)
  values (
    p_original_tx, p_user, p_product, p_state, coalesce(p_auto_renew, true),
    coalesce(p_environment, 'Production'), p_expires_at, p_last_tx, p_signed_tx,
    p_storefront, p_price_milli, p_currency)
  on conflict (original_transaction_id) do update
    set state       = excluded.state,
        -- NEVER excluded.auto_renew: the client's signed transaction carries
        -- no renewal status, so a re-verify asserting true would overwrite a
        -- cancellation ASSN just delivered (observed live 2026-08-15, 8s gap).
        -- apple-notifications updates this column directly; here it is
        -- write-once at insert.
        auto_renew  = line_subscriptions.auto_renew,
        expires_at  = excluded.expires_at,
        product_id  = excluded.product_id,
        -- coalesce so a notification that omits these does not WIPE what the
        -- purchase recorded. ASSN payloads legitimately carry less than the
        -- original transaction did, and losing the signed JWS would take
        -- revenue_snapshot's only source of the real billed price with it.
        last_transaction_id       = coalesce(excluded.last_transaction_id,
                                             line_subscriptions.last_transaction_id),
        latest_signed_transaction = coalesce(excluded.latest_signed_transaction,
                                             line_subscriptions.latest_signed_transaction),
        storefront   = coalesce(excluded.storefront, line_subscriptions.storefront),
        price_milli  = coalesce(excluded.price_milli, line_subscriptions.price_milli),
        currency     = coalesce(excluded.currency, line_subscriptions.currency),
        updated_at   = now();

  return jsonb_build_object('ok', true);
end;
$fn$;

revoke execute on function public.record_line_subscription(
  text, uuid, text, public.line_sub_state, boolean, text, timestamptz, text,
  text, text, bigint, text) from public, anon, authenticated;

do $$
begin
  if has_function_privilege('anon', 'public.record_line_subscription(text, uuid, text,'
       || ' public.line_sub_state, boolean, text, timestamptz, text, text, text,'
       || ' bigint, text)', 'execute') then
    raise exception 'record_line_subscription is callable by anon';
  end if;
end $$;

-- ── Data repair ──────────────────────────────────────────────────────────────
-- Sub 410003379188623 cancelled at 00:21:33Z (DID_CHANGE_RENEWAL_STATUS /
-- AUTO_RENEW_DISABLED in line_notifications) and was reset to true by the
-- re-verify at 00:21:41Z. Scoped to the one row the bug bit; any later
-- re-enable would have arrived as its own ASSN and there is none.
update public.line_subscriptions
   set auto_renew = false, updated_at = now()
 where original_transaction_id = '410003379188623'
   and auto_renew = true;

-- ── ops_subs: add the per-subscription list ─────────────────────────────────
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
                'subs',  (select subs from devl))
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
  'Second Number line state for /subs: per-subscription list (product, state, '
  'auto_renew, price, expiry), subscriptions by state, lines by status and '
  'billing, ASSN notifications over 7d, Telnyx balance. auto_renew is '
  'ASSN-authoritative as of 20260815100000; trials are inferred from a zero '
  'price in the formatter, never asserted here.';
