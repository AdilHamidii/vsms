-- A paying subscriber who never received a number must be able to get one
-- WITHOUT reopening the app.
--
-- 🔴 THE INCIDENT. Original transaction 700002748363888 — a $59.99 yearly
-- bought 2026-08-22 — produced four Apple notifications and ZERO rows in
-- `line_subscriptions` and `phone_lines`. Our `verify-line-subscription` call
-- never landed, and every recovery this product had was client-side:
-- `SubscriptionStore.handle` deliberately leaves the StoreKit transaction
-- unfinished so `IAPStore.restorePurchases()` sweeps it on the next launch.
-- That is correct and it is not enough — it requires the user to come back,
-- and someone who paid and got nothing has no reason to. They were billed
-- again on the billing-recovery retry seventeen days later and refunded.
--
-- Two halves land together; neither works alone:
--   • the CLIENT now sets `appAccountToken`, so a notification alone can say
--     which account paid (see `PurchaseOptions.swift`);
--   • this migration lets a SWEEP act on that, every 15 minutes, with no user
--     interaction at all.

-- ── 1. line_reprovision_target gains p_allow_first ────────────────────────
--
-- DROP + CREATE, never `or replace`: the argument list changes, and an
-- overload makes PostgREST refuse the RPC outright (the same trap
-- `complete_line_swap` documents).
--
-- The DID_RENEW path keeps its exact behaviour by keeping the default false.
-- `no_prior_line` stays a refusal there because a first-purchase notification
-- genuinely races our own client call, which owns that path and lets the user
-- pick their own number. The sweep passes true only for subscriptions old
-- enough that no such race can still be running.
drop function if exists public.line_reprovision_target(text);
drop function if exists public.line_reprovision_target(text, boolean);

create function public.line_reprovision_target(
  p_original_tx text,
  p_allow_first boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_user    uuid;
  v_product text;
  v_state   public.line_sub_state;
  v_live    uuid;
  v_prior   record;
  v_had_line boolean;
  v_sub_age timestamptz;
begin
  if p_original_tx is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  -- A MAIL subscription is not in this table at all, which is the point: the
  -- only way into here is a product `subscriptionFamily` already resolved to
  -- 'line', and even if that guard were ever lost, a $2.99 mail renewal finds
  -- no row and buys nothing.
  select user_id, product_id, state, created_at
    into v_user, v_product, v_state, v_sub_age
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
  -- `found` rather than `v_prior is null`: IS NULL on a composite is true only
  -- when EVERY field is null, so it would answer wrongly for a prior line that
  -- happened to record no country or locality.
  v_had_line := found;

  if not v_had_line then
    -- Paid, but never held a line: our own purchase call never provisioned
    -- one. Two different situations wear this shape and only the CLOCK tells
    -- them apart.
    --
    --   • Minutes old — a first-purchase notification racing our own client
    --     call, which owns that path and lets the user pick their own number.
    --     Provisioning here would take that choice away and then refuse their
    --     call with `line_exists`.
    --   • Hours or days old — the client call is never coming. The subscriber
    --     has paid for a number that does not exist, and only the server can
    --     still fix it.
    if not p_allow_first
       or v_sub_age is null
       or v_sub_age > now() - interval '30 minutes' then
      return jsonb_build_object('ok', false, 'reason', 'no_prior_line');
    end if;
  end if;

  return jsonb_build_object(
    'ok', true,
    'user_id', v_user,
    'product_id', v_product,
    -- Nulls are correct and expected in the first-provision case: the caller
    -- already falls back to DEFAULT_LINE_COUNTRY / 'local' when the country a
    -- subscriber previously held is no longer sellable, so the same branch
    -- covers "no country recorded at all". Never invent one here — the caller
    -- owns the sellability gate and it fails closed.
    'country_code', v_prior.country_code,
    'number_type',  v_prior.number_type,
    'locality',     v_prior.locality,
    'previous_e164', v_prior.e164,
    'first_provision', (not v_had_line));
end;
$$;

revoke execute on function public.line_reprovision_target(text, boolean)
  from public, anon, authenticated;

-- ── 2. Who the sweep should act on ────────────────────────────────────────
--
-- Read-only. It NAMES candidates; it never provisions — buying a number is a
-- provider call and cannot live in SQL.
create or replace function public.line_unprovisioned_subscriptions(
  p_min_age_minutes int default 30,
  p_limit int default 3
) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(t), '[]'::jsonb) from (
    select s.original_transaction_id, s.user_id, s.product_id, s.state,
           s.created_at
      from public.line_subscriptions s
     where s.environment = 'Production'
       -- ENTITLED, byte-identical to has_email_subscription() and the `/subs`
       -- predicate. NEVER coalesce: a subscriber who went through grace and
       -- then renewed carries a stale `grace_expires_at` in the past beside a
       -- fresh, later `expires_at`, and coalesce takes the first non-null
       -- regardless of which is later.
       and s.state in ('active','grace')
       and greatest(s.expires_at, s.grace_expires_at) > now()
       -- Old enough that our own client call cannot still be in flight. The
       -- client owns the happy path and lets the user pick their own number;
       -- this only ever runs after that has demonstrably not happened.
       and s.created_at < now() - make_interval(mins => greatest(p_min_age_minutes, 5))
       -- No live Apple-billed line. Same status set and the same billing scope
       -- as phone_lines_one_apple_line_per_user, so a candidate here is always
       -- one `begin_line_rental` will accept.
       and not exists (
         select 1 from public.phone_lines l
          where l.user_id = s.user_id
            and l.billing = 'apple'
            and l.status in ('provisioning','active','grace','past_due',
                             'suspended','releasing'))
       -- 🔴 ONE ATTEMPT PER DAY. A failed attempt ends `failed`, which sits
       -- OUTSIDE that partial unique index — deliberately, so a retry can
       -- succeed — but without this the sweep would retry a permanently broken
       -- subscription every 15 minutes, and each attempt that gets past the
       -- order call has already spent $1 at Telnyx.
       and not exists (
         select 1 from public.phone_lines f
          where f.user_id = s.user_id
            and f.status = 'failed'
            and f.created_at > now() - interval '24 hours')
     order by s.created_at
     limit greatest(p_limit, 0)
  ) t;
$$;

revoke execute on function public.line_unprovisioned_subscriptions(int, int)
  from public, anon, authenticated;
