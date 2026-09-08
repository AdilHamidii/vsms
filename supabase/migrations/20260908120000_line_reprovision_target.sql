-- A renewal that lands on a released line must GIVE THE SUBSCRIBER A NUMBER,
-- not just page the owner (owner decision 2026-09-08: "if we don't have their
-- number anymore just give them a new one").
--
-- Since 20260905130000 a lapsed line is released within ~30 minutes, and the
-- accepted residual was that a billing recovery — Apple retries a declined card
-- for up to 60 days — finds no line: the customer has paid and holds nothing.
-- That residual fired on 2026-09-08 on a $59.99 yearly (DID_RENEW /
-- BILLING_RECOVERY, original tx 700002748363888), which is what closes it.
--
-- This function answers ONE question for `apple-notifications`, read-only:
-- *should this renewal provision a number, and where?* The provisioning itself
-- stays in the edge function, because it calls Telnyx — the same split as the
-- reclaim sweep (pure SQL claim) and `release-lines` (the provider DELETE).
--
-- 🔴 IT IS NOT AN IDEMPOTENCY GUARD AND MUST NOT BE READ AS ONE. Apple retries
-- a notification at 1h/12h/24h/48h/72h, and the thing that makes N deliveries
-- buy at most ONE number is `begin_line_rental`: an advisory lock on the user,
-- an occupancy check, and `phone_lines_one_apple_line_per_user` underneath it.
-- The number is bought only AFTER that row exists. This read is deliberately
-- cheap and repeatable; it merely stops the common case from getting that far.
--
-- Deliberately NOT tombstoned on the notification uuid either: a provisioning
-- attempt that FAILS (Telnyx out of funds, say) leaves the row `failed`, which
-- is outside the partial unique index — so the next retry, or a later manual
-- replay, can still succeed. A uuid tombstone would lock the recovery out
-- permanently in exactly the case it exists for.

create or replace function public.line_reprovision_target(p_original_tx text)
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_user    uuid;
  v_product text;
  v_state   public.line_sub_state;
  v_live    uuid;
  v_prior   record;
begin
  if p_original_tx is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  -- A MAIL subscription is not in this table at all, which is the point: the
  -- only way into here is a product `subscriptionFamily` already resolved to
  -- 'line', and even if that guard were ever lost, a $2.99 mail renewal finds
  -- no row and buys nothing.
  select user_id, product_id, state
    into v_user, v_product, v_state
    from public.line_subscriptions
   where original_transaction_id = p_original_tx;
  if v_user is null then
    -- Unattributable: our own purchase call never landed, so nothing anywhere
    -- says which account this entitlement belongs to. Inventing one would bind
    -- an Apple entitlement to the wrong user — the exact replay
    -- `subscription_bound` exists to refuse. A human has to resolve it.
    return jsonb_build_object('ok', false, 'reason', 'unknown_subscription');
  end if;

  -- Only an entitlement that is actually live earns a number. `expired` and
  -- `revoked` reaching here would mean a renewal and a lapse crossed; the
  -- lapse wins, because provisioning against it pays rent for nothing.
  if v_state not in ('active', 'grace') then
    return jsonb_build_object('ok', false, 'reason', 'subscription_not_active',
                              'state', v_state);
  end if;

  -- Scoped to billing='apple' to match phone_lines_one_apple_line_per_user: a
  -- credits-billed line is allowed to coexist and must not block this.
  select id into v_live from public.phone_lines
   where user_id = v_user
     and billing = 'apple'
     and status in ('provisioning','active','grace','past_due','suspended','releasing')
   limit 1;
  if v_live is not null then
    return jsonb_build_object('ok', false, 'reason', 'line_exists',
                              'line_id', v_live);
  end if;

  -- The place to put them back. Their OWN last number's country and city, so a
  -- subscriber who chose Toronto is not silently moved to New York. The caller
  -- re-checks sellability and falls back to the server default if that country
  -- has since been blocked.
  select country_code, number_type, locality, e164
    into v_prior
    from public.phone_lines
   where original_transaction_id = p_original_tx
   order by created_at desc
   limit 1;

  if v_prior is null then
    -- Paid, but never held a line: the purchase call never provisioned one.
    -- Refused here on purpose — that is a different failure with a different
    -- fix (find out why the purchase call never landed), and it is the shape
    -- of a first-purchase notification racing our own client call, which owns
    -- that path and lets the user pick their own number.
    return jsonb_build_object('ok', false, 'reason', 'no_prior_line');
  end if;

  return jsonb_build_object(
    'ok', true,
    'user_id', v_user,
    'product_id', v_product,
    'country_code', v_prior.country_code,
    'number_type', v_prior.number_type,
    'locality', v_prior.locality,
    'previous_e164', v_prior.e164);
end;
$fn$;

revoke execute on function public.line_reprovision_target(text)
  from public, anon, authenticated;
