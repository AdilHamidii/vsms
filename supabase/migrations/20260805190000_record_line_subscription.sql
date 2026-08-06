-- The missing writer for `line_subscriptions`.
--
-- 20260805170000 shipped SIX functions that UPDATE this table — apply_line_
-- renewal, enter_line_grace_claim, mark_line_past_due_claim, suspend_line_claim,
-- revoke_line_claim — and none that INSERTS one. So the very first subscribe
-- had nowhere to write its row, every later UPDATE would have matched zero
-- rows, and the whole lapse state machine would have run against a table that
-- was permanently empty. Silent, because an UPDATE matching nothing is not an
-- error.
--
-- ⚠️ The table is deliberately cascade-free (no FK to auth.users) because it is
-- the account-deletion tombstone: delete → re-signin → StoreKit still reports
-- the entitlement → without this row we provision a SECOND Telnyx number while
-- the first bills us forever with nothing pointing at it. That property only
-- holds if the row actually gets written, which is what this fixes.

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
        auto_renew  = excluded.auto_renew,
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

-- The `public` half is the one that matters: CREATE FUNCTION grants EXECUTE to
-- PUBLIC by default and anon/authenticated are members, so revoking only those
-- two leaves the function callable at /rest/v1/rpc/. See 20260727240000.
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
