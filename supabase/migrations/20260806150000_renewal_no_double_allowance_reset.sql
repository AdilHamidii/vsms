-- A DEFERRED renewal retry must not wipe an allowance the user has been using.
--
-- 20260806100000 correctly stopped `apply_line_renewal` from claiming the
-- idempotency tombstone while the line is still `provisioning`: it returns
-- {retryable:true}, apple-notifications turns that into a 500, and Apple's
-- 1h/12h/24h/48h/72h ladder brings it back. That fix is right and stays.
--
-- What it left open: when the retry FINALLY lands — an hour or more later, long
-- after `verify-line-subscription` brought the line up and set the very same
-- period — the function unconditionally does
-- `sms_used = 0, voice_used_seconds = 0, allowance_period_start = now()`.
-- The user has been texting and calling in the meantime, so the retry hands
-- them a second full allowance (up to 200 SMS / 100 minutes) for one paid
-- period, on a hard-stop product with no overage revenue to earn it back.
--
-- The tombstone cannot prevent this: it is deliberately not claimed on the
-- deferred pass, which is the whole point of the earlier fix. So the guard has
-- to be the PERIOD itself. A renewal that does not advance `current_period_end`
-- is not a new period, and only a new period earns a new allowance — which is
-- also the rule the schema comment already states for why the reset must never
-- happen on a calendar boundary.
--
-- Everything else in this function is byte-identical to 20260806100000.

create or replace function public.apply_line_renewal(
  p_original_tx text, p_transaction_id text, p_period_end timestamptz,
  p_price_milli bigint, p_currency text, p_storefront text,
  p_signed_transaction text default null
) returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_line uuid;
  v_status public.line_status;
  v_prev_end timestamptz;
  v_fresh_period boolean;
begin
  if p_original_tx is null or p_transaction_id is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  -- 🔴 RESOLVE THE LINE BEFORE CLAIMING THE TOMBSTONE.
  --
  -- `provisioning` is TRANSIENT: verify-line-subscription is mid-flight and
  -- will set the period and reset the allowance itself in a few seconds. The
  -- old order claimed the tombstone first, so a renewal landing in that window
  -- was recorded as applied and then matched no row — the allowance never
  -- reset, and no retry could ever repair it because the tombstone said the
  -- work was done. Refusing here claims nothing, so Apple's retry ladder (and
  -- the unprocessed-notification sweep) can still apply it.
  select id, status, current_period_end
    into v_line, v_status, v_prev_end
    from public.phone_lines
   where original_transaction_id = p_original_tx
   order by created_at desc
   limit 1;

  if v_status = 'provisioning' then
    return jsonb_build_object('ok', false, 'reason', 'line_provisioning',
                              'retryable', true);
  end if;

  -- Does this renewal actually advance the period? If verify-line-subscription
  -- already recorded this exact `current_period_end`, we are looking at a
  -- deferred retry for a period that is already live and already being spent.
  v_fresh_period := v_prev_end is distinct from p_period_end;

  -- The tombstone IS the idempotency check. Apple retries notifications at
  -- 1h/12h/24h/48h/72h and the reprocess sweep replays the same renewal from
  -- another direction — without this, one renewal resets the allowance several
  -- times and hands out free capacity.
  insert into public.line_renewals (transaction_id, original_transaction_id)
  values (p_transaction_id, p_original_tx)
  on conflict (transaction_id) do nothing;
  if not found then
    return jsonb_build_object('ok', true, 'reason', 'already_applied');
  end if;

  update public.line_subscriptions
     set state = 'active', expires_at = p_period_end,
         last_transaction_id = p_transaction_id,
         latest_signed_transaction =
           coalesce(p_signed_transaction, latest_signed_transaction),
         price_milli = coalesce(p_price_milli, price_milli),
         currency = coalesce(p_currency, currency),
         storefront = coalesce(p_storefront, storefront),
         grace_expires_at = null, updated_at = now()
   where original_transaction_id = p_original_tx;

  v_line := null;
  update public.phone_lines
     set status = case when status in ('grace','past_due','suspended')
                       then 'active' else status end,
         current_period_start = case when v_fresh_period
                                     then now() else current_period_start end,
         current_period_end = p_period_end,
         grace_until = null,
         hold_until = null,
         -- ⚠️ ONLY a genuinely new period resets the meter. A retry for the
         -- period already in progress leaves real usage alone.
         allowance_period_start = case when v_fresh_period
                                       then now() else allowance_period_start end,
         sms_used = case when v_fresh_period then 0 else sms_used end,
         voice_used_seconds = case when v_fresh_period then 0 else voice_used_seconds end,
         updated_at = now()
   where original_transaction_id = p_original_tx
     and status in ('active','grace','past_due','suspended')
  returning id into v_line;

  -- `allowance_reset` is reported rather than assumed. A renewal for a line
  -- that is already released is legitimate (the subscription outlives the
  -- number) and must read as such, not as success. It now also reads false for
  -- a same-period retry, which genuinely did not reset anything.
  return jsonb_build_object('ok', true, 'line_id', v_line,
                            'allowance_reset', v_line is not null and v_fresh_period);
end;
$fn$;
revoke execute on function public.apply_line_renewal(
  text, text, timestamptz, bigint, text, text, text)
  from public, anon, authenticated;

do $$
begin
  if has_function_privilege('anon',
       'public.apply_line_renewal(text, text, timestamptz, bigint, text, text, text)',
       'execute') then
    raise exception 'apply_line_renewal is reachable from anon';
  end if;
end $$;
