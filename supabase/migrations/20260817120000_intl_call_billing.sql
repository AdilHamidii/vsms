-- Charging international calls to the credit wallet.
--
-- The allowance stays exactly what the subscription sells: 100 domestic (NANP)
-- minutes, hard stop. Anything else is priced from `voice_rates` at 5x and paid
-- in credits, because a minute-denominated bucket cannot tell a $0.005/min call
-- from a $3.62/min one — see 20260817110000 for why that is the whole feature.
--
-- SHAPE, and it mirrors `begin_order` deliberately: the credits are charged and
-- the call row written in ONE transaction under the caller's own lock, so a
-- failure can never leave a charge pointing at nothing. Settlement then refunds
-- the unused part of the block from the CDR.

alter table public.line_calls
  add column if not exists dest_iso2            text,
  add column if not exists rate_credits_per_min numeric(10,4),
  add column if not exists credits_reserved     integer not null default 0,
  add column if not exists credits_charged      integer;

comment on column public.line_calls.credits_reserved is
  'Credits taken up front for an INTERNATIONAL call. 0 means the call was '
  'domestic and billed against the minute allowance instead — the two are '
  'mutually exclusive and `settle_call_claim` branches on this being > 0.';

-- ── Reserve ───────────────────────────────────────────────────────────────
create or replace function public.begin_intl_call_claim(
  p_user            uuid,
  p_line            uuid,
  p_peer            text,
  p_reserve_seconds integer
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rate public.voice_rates;
  v_credits integer;
  v_status public.line_status;
  v_owner uuid;
  v_call uuid;
  v_bal integer;
begin
  if p_user is null or p_line is null or p_peer is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  -- Serialise per user, the same lock `begin_order` and `post_support_message`
  -- take. Without it a double-tap charges twice and races the balance check.
  perform pg_advisory_xact_lock(hashtext(p_user::text));

  select user_id, status into v_owner, v_status
    from public.phone_lines where id = p_line for update;
  if not found or v_owner <> p_user then
    return jsonb_build_object('ok', false, 'reason', 'line_unavailable');
  end if;
  if v_status not in ('active', 'grace') then
    return jsonb_build_object('ok', false, 'reason', 'line_suspended');
  end if;

  -- ⚠️ `voice_rate_for` returns SETOF precisely so this `not found` works. A
  -- destination we have no rate for is REFUSED, never guessed at — defaulting
  -- an unknown prefix to a cheap rate is how a premium range gets billed at a
  -- landline price.
  select * into v_rate from public.voice_rate_for(p_peer);
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'destination_unavailable');
  end if;

  -- Domestic is not this function's business; the caller uses the allowance.
  if v_rate.covered_by_allowance then
    return jsonb_build_object('ok', false, 'reason', 'domestic');
  end if;

  -- A PRICE IS NOT PERMISSION. Telnyx outbound profiles allow US/CA only by
  -- default and many destinations need Level 2 verification, so a rate row that
  -- is not `enabled` means the call would fail AFTER we took the money.
  if not v_rate.enabled then
    return jsonb_build_object('ok', false, 'reason', 'destination_unavailable',
                              'iso2', v_rate.iso2, 'label', v_rate.label);
  end if;

  -- Round UP: a partial block is a whole credit. `greatest(...,1)` so a very
  -- cheap destination still costs something rather than being free by rounding.
  v_credits := greatest(
    ceil(coalesce(p_reserve_seconds, 120) * v_rate.credits_per_min / 60.0)::int, 1);

  select balance into v_bal from public.wallets where user_id = p_user;
  if not public.wallet_spend_line(p_user, v_credits, p_line) then
    return jsonb_build_object(
      'ok', false, 'reason', 'insufficient_credits',
      'needed', v_credits, 'balance', coalesce(v_bal, 0),
      'shortfall', greatest(v_credits - coalesce(v_bal, 0), 0),
      'iso2', v_rate.iso2, 'label', v_rate.label,
      'credits_per_min', v_rate.credits_per_min);
  end if;

  insert into public.line_calls (
    line_id, user_id, direction, peer_e164, status, reserved_seconds,
    dest_iso2, rate_credits_per_min, credits_reserved)
  values (
    p_line, p_user, 'outbound', p_peer, 'ringing', 0,
    v_rate.iso2, v_rate.credits_per_min, v_credits)
  returning id into v_call;

  return jsonb_build_object(
    'ok', true, 'call_id', v_call,
    'credits_reserved', v_credits,
    'credits_per_min', v_rate.credits_per_min,
    'iso2', v_rate.iso2, 'label', v_rate.label,
    'balance', coalesce(v_bal, 0) - v_credits);
end;
$$;

revoke execute on function public.begin_intl_call_claim(uuid, uuid, text, integer)
  from public, anon, authenticated;

-- ── Settle ────────────────────────────────────────────────────────────────
-- ONE settle path, not two. `sync-telnyx-cdr`, `settle_stale_calls` and
-- `attach_line_call_session` all already call `settle_call_claim`; giving
-- international its own function would mean every one of those three had to
-- learn which to use, and the one that forgot would silently never refund.
create or replace function public.settle_call_claim(
  p_call           uuid,
  p_billed_seconds integer,
  p_cost_cents     integer,
  p_status         public.line_call_status,
  p_hangup_cause   text,
  p_cost_usd       numeric default null
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_settled boolean; v_line uuid; v_reserved integer;
  v_direction public.line_call_direction;
  v_user uuid; v_cr_reserved integer; v_rate numeric; v_used integer; v_delta integer;
begin
  select allowance_settled, line_id, reserved_seconds, direction,
         user_id, credits_reserved, rate_credits_per_min
    into v_settled, v_line, v_reserved, v_direction,
         v_user, v_cr_reserved, v_rate
    from public.line_calls where id = p_call for update;
  if not found or v_settled then return false; end if;

  -- The credits actually consumed, rounded UP to a whole block. A call that
  -- never connected bills nothing.
  if coalesce(v_cr_reserved, 0) > 0 then
    v_used := case
      when coalesce(p_billed_seconds, 0) <= 0 then 0
      else greatest(ceil(p_billed_seconds * coalesce(v_rate, 0) / 60.0)::int, 1)
    end;
  else
    v_used := 0;
  end if;

  update public.line_calls
     set billed_seconds = coalesce(p_billed_seconds, billed_seconds),
         provider_cost_cents = coalesce(p_cost_cents, provider_cost_cents),
         provider_cost_usd   = coalesce(p_cost_usd, provider_cost_usd),
         status = p_status,
         hangup_cause = coalesce(p_hangup_cause, hangup_cause),
         ended_at = coalesce(ended_at, now()),
         credits_charged = case when coalesce(v_cr_reserved,0) > 0 then v_used
                                else credits_charged end,
         allowance_settled = true
   where id = p_call;

  if coalesce(v_cr_reserved, 0) > 0 then
    -- INTERNATIONAL: reconcile the credit block. Nothing touches the minute
    -- allowance — the user paid cash for this call, so charging their domestic
    -- minutes too would be billing twice for one thing.
    v_delta := v_cr_reserved - v_used;
    if v_delta > 0 then
      perform public.wallet_move_line(v_user, v_delta, 'refund', v_line);
    elsif v_delta < 0 then
      -- Overran the block. Recover what we can; a wallet cannot go negative, so
      -- a user who spent their balance mid-call leaves a shortfall we absorb.
      -- Bounded by the block size and loud, because nothing else will notice.
      if not public.wallet_spend_line(v_user, -v_delta, v_line) then
        raise warning 'intl_call_overrun_unrecovered call=% credits=%',
          p_call, -v_delta;
      end if;
    end if;
  elsif v_direction = 'inbound' then
    perform public.settle_line_allowance(v_line, 'voice', 0, coalesce(v_reserved, 0));
  else
    perform public.settle_line_allowance(
      v_line, 'voice', coalesce(p_billed_seconds, 0), v_reserved);
  end if;
  return true;
end;
$$;

revoke execute on function public.settle_call_claim(
  uuid, integer, integer, public.line_call_status, text, numeric)
  from public, anon, authenticated;
