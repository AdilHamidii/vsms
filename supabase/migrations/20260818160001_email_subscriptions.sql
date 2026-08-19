-- The temp-e-mail line becomes a subscription product.
--
-- One free address per account for LIFE (retroactive over existing rows), then
-- an auto-renewable subscription grants unlimited addresses on the FREE
-- domains. gmail.com stays a 1-credit purchase for everyone.
--
-- The table mirrors line_subscriptions rather than generalising it: that table
-- carries live paying subscribers and a lapse backstop, and restructuring live
-- money code to add a second product is the wrong order of risk.
--
-- 🔴 THE NEW RULE SHIPS DARK. Version 2.1 is LIVE on the App Store right now
-- and has no paywall for `subscription_required`, no way to subscribe, and no
-- string for that error — email is the app's highest-volume surface (177
-- orders / 54 users in 14 days as of 2026-08-19). Applying the lifetime wall
-- the instant this migration lands would refuse every existing user with an
-- error the shipped client renders as a generic failure. So `begin_email_order`
-- keeps TODAY'S per-UTC-day behaviour until `app_config.email_subscription_
-- enforced` is flipped to true, which only happens once 2.2 (with the
-- subscription paywall) is live and adopted. See the controller ruling for
-- Task 2, dated 2026-08-19.

create table if not exists public.email_subscriptions (
  original_transaction_id   text primary key,
  -- Deliberately NOT `references auth.users`. A FK here is exactly what would
  -- delete our record along with the account: delete-account → re-signin →
  -- StoreKit still reports the entitlement, and we would grant it twice while
  -- Apple bills once. `subscription_bound` is the replay catch.
  user_id                   uuid not null,
  product_id                text not null,
  -- Reuses the existing enum rather than declaring a second identical one:
  -- these values describe APPLE's subscription lifecycle, which is not
  -- line-specific. The `line_` prefix is therefore now a misnomer; renaming a
  -- live enum is not worth a migration, and this comment is the record that it
  -- is shared on purpose.
  state                     public.line_sub_state not null,
  auto_renew                boolean not null default true,
  environment               text not null,
  expires_at                timestamptz,
  grace_expires_at          timestamptz,
  last_transaction_id       text,
  -- Raw JWS of the latest transaction, so revenue work can decode the REAL
  -- billed price/currency/storefront with the existing jws_payload(). A
  -- hardcoded USD ladder mis-states revenue across storefronts.
  latest_signed_transaction text,
  revocation_date           timestamptz,
  revocation_reason         integer,
  storefront                text,
  price_milli               bigint,
  currency                  text,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now()
);

create index if not exists email_subscriptions_user_idx
  on public.email_subscriptions (user_id);
create index if not exists email_subscriptions_expiry_idx
  on public.email_subscriptions (state, expires_at);

alter table public.email_subscriptions enable row level security;
revoke all on public.email_subscriptions from anon, authenticated;

-- Config. All three are read live so the numbers (and the kill switch) move
-- without a deploy.
insert into public.app_config (key, value)
values ('email_free_lifetime_grants', '1'::jsonb)
on conflict (key) do nothing;

insert into public.app_config (key, value)
values ('email_sub_daily_cap', '25'::jsonb)
on conflict (key) do nothing;

-- 🔴 THE KILL SWITCH, AND IT DEFAULTS TO OFF ON PURPOSE.
--
-- 2.1 is live and has no paywall for `subscription_required`, no way to
-- subscribe, and no string for that error. Enforcing the lifetime wall before
-- 2.2 ships would refuse the app's highest-volume surface for every existing
-- user and render as a generic failure. Flip this to true only once 2.2 is
-- live and adopted.
--
-- Fails CLOSED to the OLD behaviour: a missing or unreadable row means "not
-- enforced", i.e. exactly what shipped. Losing the row cannot silently wall
-- anyone.
insert into public.app_config (key, value)
values ('email_subscription_enforced', 'false'::jsonb)
on conflict (key) do nothing;

-- `telegram_events.kind` is a CHECK constraint, not free text. The mail alerts
-- claim rows on new kinds, and an unlisted value raises 23514 — which would
-- make the alert path throw INSIDE the notification handler and hand Apple a
-- 500 for a subscription we recorded correctly.
alter table public.telegram_events drop constraint if exists telegram_events_kind_check;
alter table public.telegram_events add constraint telegram_events_kind_check
  check (kind = any (array[
    'signup', 'purchase', 'esim', 'email', 'line', 'line_refund',
    'line_orphan', 'line_provision_failed', 'iap_unknown', 'line_event',
    'mail_sub', 'mail_sub_event'
  ]));

-- ── The only creator of rows ─────────────────────────────────────────────────
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
declare v_bound uuid;
begin
  if p_original_tx is null or p_user is null or p_product is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  -- THE replay check. A subscription already bound to a DIFFERENT user means
  -- the same Apple entitlement is being presented by a second account, which
  -- is what deleting and re-creating an account produces.
  select user_id into v_bound from public.email_subscriptions
   where original_transaction_id = p_original_tx;
  if v_bound is not null and v_bound <> p_user then
    return jsonb_build_object('ok', false, 'reason', 'subscription_bound');
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

-- ── The entitlement ─────────────────────────────────────────────────────────
-- `grace` counts as entitled: Apple is still trying to bill, and cutting
-- service off mid-retry loses a customer we still have.
create or replace function public.has_email_subscription(p_user uuid)
returns boolean
language sql stable security definer set search_path to 'public' as $fn$
  select exists (
    select 1 from public.email_subscriptions
     where user_id = p_user
       and state in ('active', 'grace')
       and coalesce(grace_expires_at, expires_at) > now()
  );
$fn$;

-- ── The gate ────────────────────────────────────────────────────────────────
-- Replaces the per-UTC-day free cap with: one free address for LIFE, or a
-- subscription — but ONLY once `email_subscription_enforced` is true. Until
-- then this is byte-identical to the shipped 2.1 behaviour. The paid (gmail)
-- path is unconditional and unchanged either way.
create or replace function public.begin_email_order(
  p_user uuid, p_service text, p_site text, p_domain text, p_credits integer)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_existing uuid; v_order uuid; v_ok boolean;
  v_free_ever integer; v_grants integer;
  v_today integer; v_cap integer;
  v_enforced boolean;
begin
  if p_credits is null or p_credits < 0 then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  perform pg_advisory_xact_lock(hashtext(p_user::text));

  select id into v_existing from public.email_orders
   where user_id = p_user and site = p_site and domain = p_domain
     and status = 'waiting' and created_at > now() - interval '2 minutes'
   limit 1;
  if v_existing is not null then
    return jsonb_build_object('ok', false, 'reason', 'duplicate_request');
  end if;

  if p_credits = 0 then
    select coalesce((value #>> '{}')::boolean, false) into v_enforced
      from public.app_config where key = 'email_subscription_enforced';
    v_enforced := coalesce(v_enforced, false);

    if not v_enforced then
      -- PRE-2.2 BEHAVIOUR, deliberately byte-identical to what shipped: N free
      -- addresses per UTC day, refused as `free_limit_reached`. Do not "tidy"
      -- this branch away — it is what keeps the live 2.1 build working while
      -- the subscription ships dark.
      select coalesce((value #>> '{}')::integer, 3) into v_cap
        from public.app_config where key = 'email_free_daily_cap';
      v_cap := coalesce(v_cap, 3);
      select count(*) into v_today from public.email_orders
       where user_id = p_user and cost_credits = 0
         and status <> 'failed'
         and created_at >= date_trunc('day', now() at time zone 'utc');
      if v_today >= v_cap then
        return jsonb_build_object('ok', false, 'reason', 'free_limit_reached',
                                  'cap', v_cap);
      end if;

    elsif public.has_email_subscription(p_user) then
      -- Subscribed. Free domains cost us nothing, but the inventory is scarce
      -- and SHARED — one looping subscriber could drain it for every user. A
      -- stated hard stop, not a throttle.
      select greatest(0, least(10000, coalesce((value #>> '{}')::integer, 25)))
        into v_cap from public.app_config where key = 'email_sub_daily_cap';
      v_cap := coalesce(v_cap, 25);
      select count(*) into v_today from public.email_orders
       where user_id = p_user and cost_credits = 0
         and status <> 'failed'
         and created_at >= date_trunc('day', now() at time zone 'utc');
      if v_today >= v_cap then
        return jsonb_build_object('ok', false, 'reason', 'daily_cap_reached',
                                  'cap', v_cap);
      end if;

    else
      -- Not subscribed: a LIFETIME allowance, counted over all history.
      -- `status <> 'failed'` is retained from the old daily rule — an order
      -- that never provisioned a mailbox is not a grant.
      select greatest(0, least(50, coalesce((value #>> '{}')::integer, 1)))
        into v_grants from public.app_config
       where key = 'email_free_lifetime_grants';
      v_grants := coalesce(v_grants, 1);
      select count(*) into v_free_ever from public.email_orders
       where user_id = p_user and cost_credits = 0 and status <> 'failed';
      if v_free_ever >= v_grants then
        return jsonb_build_object('ok', false, 'reason', 'subscription_required',
                                  'used', v_free_ever, 'grants', v_grants);
      end if;
    end if;
  end if;

  insert into public.email_orders (user_id, service_id, site, domain, cost_credits, status)
  values (p_user, p_service, p_site, p_domain, p_credits, 'waiting')
  returning id into v_order;

  if p_credits > 0 then
    select public.wallet_spend(p_user, p_credits, 'spend', null) into v_ok;
    if not coalesce(v_ok, false) then
      delete from public.email_orders where id = v_order;
      return jsonb_build_object('ok', false, 'reason', 'insufficient');
    end if;
    update public.wallet_transactions set email_order_id = v_order
     where id = (select id from public.wallet_transactions
                  where user_id = p_user and reason = 'spend' and email_order_id is null
                  order by created_at desc, id desc limit 1);
  end if;

  return jsonb_build_object('ok', true, 'order_id', v_order);
end;
$function$;

-- ── Privileges ──────────────────────────────────────────────────────────────
-- The `public` half is the one that matters: CREATE FUNCTION grants EXECUTE to
-- PUBLIC by default and anon/authenticated are members, so revoking only those
-- two changes nothing at all.
revoke execute on function public.record_email_subscription(
  text, uuid, text, public.line_sub_state, boolean, text, timestamptz, text,
  text, text, bigint, text) from public, anon, authenticated;
revoke execute on function public.has_email_subscription(uuid)
  from public, anon, authenticated;
revoke execute on function public.begin_email_order(uuid, text, text, text, integer)
  from public, anon, authenticated;

do $$
begin
  if has_function_privilege('anon', 'public.has_email_subscription(uuid)', 'execute') then
    raise exception 'has_email_subscription is callable by anon';
  end if;
  if has_function_privilege('anon', 'public.record_email_subscription(text, uuid, text,'
       || ' public.line_sub_state, boolean, text, timestamptz, text, text, text,'
       || ' bigint, text)', 'execute') then
    raise exception 'record_email_subscription is callable by anon';
  end if;
  if has_function_privilege('anon',
       'public.begin_email_order(uuid, text, text, text, integer)', 'execute') then
    raise exception 'begin_email_order is callable by anon';
  end if;
end $$;
