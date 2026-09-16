-- A client re-post of a mail subscription receipt may never make the row LESS
-- true than it already is (2026-09-16).
--
-- `record_email_subscription` has two callers. `apple-notifications` calls it
-- only when NO row exists (`ensureMailSubscriptionRow`), so the ON CONFLICT
-- branch is reached almost exclusively by `verify-email-subscription` — the
-- app posting a JWS it still holds, with `p_state = 'active'` and
-- `p_auto_renew = true` hard-coded, because a device cannot know either.
-- That branch overwrote three columns with whatever that receipt said:
--
--   1. state      → a lapsed row (`grace`, `billing_retry`) was flipped back to
--                   `active` by re-posting an OLD receipt whose period had
--                   already ended. Entitlement was never at risk —
--                   `has_email_subscription` is date-gated — but `/revenue`,
--                   `ops_subs` and `ops_trials` all read `state`, and reported
--                   dead subscribers as live.
--   2. expires_at → an old receipt could move expiry BACKWARDS, e.g. the
--                   original purchase JWS re-posted after a renewal had
--                   already advanced it. That one is not cosmetic: the
--                   predicate is `greatest(expires_at, grace_expires_at) >
--                   now()`, so a PAYING subscriber could be denied.
--   3. auto_renew → forced back to true, erasing a DID_CHANGE_RENEWAL_STATUS
--                   the notification handler had recorded.
--
-- Now: the state is kept when the posted period has already ended and the row
-- is in a lapsed state; expiry only ever moves forward; auto_renew on conflict
-- keeps what Apple last told us. A genuinely renewed receipt (future expiry)
-- still moves a lapsed row to `active`, which is the recovery path.
--
-- Returns `ok: true` either way — deliberately NOT a new refusal. A new error
-- string would need a matching `APIError` case in the client and a release;
-- the caller did nothing wrong by holding an old receipt.

create or replace function public.record_email_subscription(
  p_original_tx text, p_user uuid, p_product text, p_state line_sub_state,
  p_auto_renew boolean, p_environment text, p_expires_at timestamp with time zone,
  p_last_tx text, p_signed_tx text default null::text,
  p_storefront text default null::text, p_price_milli bigint default null::bigint,
  p_currency text default null::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_bound uuid;
  v_state public.line_sub_state;
  v_kept  boolean := false;
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

  -- 🔴 A TERMINAL STATE MAY NOT BE UPGRADED BACK TO `active` FROM HERE.
  -- `revoked` is absolute (Apple's own notification re-activates a genuine
  -- re-subscribe); `expired` is allowed only when the submitted period has
  -- genuinely not ended yet. Refusals, not errors — the caller returns 409.
  if p_state = 'active' and v_state = 'revoked' then
    return jsonb_build_object('ok', false, 'reason', 'subscription_revoked');
  end if;
  if p_state = 'active' and v_state = 'expired'
     and (p_expires_at is null or p_expires_at <= now()) then
    return jsonb_build_object('ok', false, 'reason', 'subscription_expired');
  end if;

  -- A LAPSED (not terminal) row keeps its state against a stale receipt.
  v_kept := p_state = 'active'
        and v_state in ('grace', 'billing_retry')
        and (p_expires_at is null or p_expires_at <= now());

  insert into public.email_subscriptions (
    original_transaction_id, user_id, product_id, state, auto_renew,
    environment, expires_at, last_transaction_id, latest_signed_transaction,
    storefront, price_milli, currency)
  values (
    p_original_tx, p_user, p_product, p_state, coalesce(p_auto_renew, true),
    coalesce(p_environment, 'Production'), p_expires_at, p_last_tx, p_signed_tx,
    p_storefront, p_price_milli, p_currency)
  on conflict (original_transaction_id) do update
    set state       = case when v_kept then email_subscriptions.state
                           else excluded.state end,
        -- The device cannot know the renewal flag; Apple's notification can.
        auto_renew  = email_subscriptions.auto_renew,
        -- Forward only. `greatest` ignores NULLs, so a receipt without an
        -- expiry never erases one.
        expires_at  = greatest(excluded.expires_at, email_subscriptions.expires_at),
        product_id  = excluded.product_id,
        -- coalesce so a post that omits these does not WIPE what the purchase
        -- recorded.
        last_transaction_id       = coalesce(excluded.last_transaction_id,
                                             email_subscriptions.last_transaction_id),
        latest_signed_transaction = coalesce(excluded.latest_signed_transaction,
                                             email_subscriptions.latest_signed_transaction),
        storefront   = coalesce(excluded.storefront, email_subscriptions.storefront),
        price_milli  = coalesce(excluded.price_milli, email_subscriptions.price_milli),
        currency     = coalesce(excluded.currency, email_subscriptions.currency),
        updated_at   = now();

  return jsonb_build_object('ok', true, 'state_kept', v_kept);
end;
$function$;

-- CREATE OR REPLACE keeps the existing ACL, but assert it rather than trust it:
-- PUBLIC holds EXECUTE by default on a newly created function.
revoke execute on function public.record_email_subscription(
  text, uuid, text, line_sub_state, boolean, text, timestamp with time zone,
  text, text, text, bigint, text) from public, anon, authenticated;
