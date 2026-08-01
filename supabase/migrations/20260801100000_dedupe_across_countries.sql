-- Close the double-charge that gates the 180s minimum hold.
--
-- The hold is currently opt-in (`enforce_min_hold`, sent only by 1.6+). The
-- stated reason: pre-1.6 `rerollNumber` does `try? await orders.cancel(...)`
-- and creates the replacement REGARDLESS of whether the cancel succeeded, so
-- enforcing for everyone would leave the original `waiting` AND charge for a
-- second order.
--
-- Measured 2026-08-01, that exposure is much narrower than the comment implies,
-- because begin_order already dedupes on (user, service, country, tier) within
-- 15s. A same-country reroll is therefore ALREADY protected — it returns
-- 'duplicate' and charges nothing. Only a DIFFERENT-country reroll slips
-- through: 7 occurrences in 30 days across 3 users, against 23 same-country
-- ones that were already caught.
--
-- Dropping `country_id` from the predicate closes that last hole, and it is a
-- no-op for every healthy flow, because the match still requires the earlier
-- order to be `waiting`:
--   * a 1.6+ reroll aborts client-side when the cancel is refused, so it never
--     reaches this function with a live order;
--   * a 1.6+ reroll AFTER the hold cancels successfully first, so the earlier
--     order is no longer `waiting` and cannot match;
--   * a pre-1.6 reroll after a refused cancel now returns the ORIGINAL order
--     instead of charging again — the user keeps the number they already paid
--     for, which is still live and can still deliver.
--
-- `tier` stays in the predicate on purpose: standard-then-premium in quick
-- succession is a deliberate upgrade, not a double-tap.
--
-- The cost is that ordering the same service in two countries within 15s now
-- returns the first order. That is a rare, arguably-unwanted flow (paying twice
-- for one verification), and 15s is a narrow window.

create or replace function public.begin_order(
  p_user uuid, p_service text, p_country text, p_credits integer,
  p_dedupe_seconds integer default 15, p_tier text default 'standard'
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_existing uuid;
  v_id uuid;
  v_ok boolean;
begin
  -- Serialize per user for the rest of this transaction (see 20260721094313).
  perform pg_advisory_xact_lock(hashtext(p_user::text));

  -- Dedupe on (user, service, tier) — deliberately NOT country. See header:
  -- a still-`waiting` order for this service means the previous one was never
  -- released, and charging for a second number in a different country is the
  -- double-charge that kept the 180s hold opt-in.
  select id into v_existing
  from public.orders
  where user_id = p_user
    and service_id = p_service
    and status = 'waiting'
    and tier = p_tier
    and created_at >= now() - make_interval(secs => p_dedupe_seconds)
  order by created_at desc
  limit 1;

  if v_existing is not null then
    return jsonb_build_object('status', 'duplicate', 'order_id', v_existing);
  end if;

  insert into public.orders (user_id, service_id, country_id, cost_credits, status, tier)
  values (p_user, p_service, p_country, p_credits, 'waiting', p_tier)
  returning id into v_id;

  select public.wallet_spend(p_user, p_credits, 'spend', v_id) into v_ok;

  if not coalesce(v_ok, false) then
    delete from public.orders where id = v_id;
    return jsonb_build_object('status', 'insufficient_credits');
  end if;

  return jsonb_build_object('status', 'ok', 'order_id', v_id);
end;
$$;

revoke execute on function public.begin_order(uuid, text, text, integer, integer, text)
  from public, anon, authenticated;
