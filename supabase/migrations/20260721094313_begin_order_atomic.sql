-- Make every paid attempt visible, and make the dedupe check actually atomic.
--
-- create-order charged credits and only wrote the orders row AFTER a provider
-- reservation succeeded. Every failed attempt therefore left a spend and a
-- refund with no order row at all: 258 spends against 126 orders, 51% of paid
-- attempts invisible. The failure rate of the product was unmeasurable, and no
-- failure reason was recorded anywhere. It also meant wallet_spend was never
-- passed p_order, so 258 of 258 spends are unlinked from their order even on
-- SUCCESS, making margin and LTV analysis impossible.
--
-- The naive fix (insert the row, then charge, as two calls from the edge
-- function) just moves the race: a crash between them recreates the same bug
-- mirrored. And the existing dedupe is check-then-act across a multi-second
-- provider call, so two concurrent requests both pass it and both charge.
--
-- This does all of it in ONE transaction, serialized per user by an advisory
-- lock so a second concurrent request blocks until the first has committed its
-- row and then sees it via the normal dedupe path.
--
-- Deliberately NO new order_status values. The iOS OrderStatus enum
-- (Components/Pills.swift) is a plain String enum with no unknown case, so a
-- status it doesn't know would throw on decode and break the Orders tab for
-- everyone on the live 1.3 build and the 1.4 in review. A pre-reservation row
-- is therefore a normal 'waiting' row with a null smspva_id — which
-- poll-active-orders already skips (it filters smspva_id is not null) while
-- the expiry sweep does not, so a stranded row self-heals into a refund after
-- 8 minutes rather than sitting charged forever.

create or replace function public.begin_order(
  p_user uuid,
  p_service text,
  p_country text,
  p_credits integer,
  p_dedupe_seconds integer default 15
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_existing uuid;
  v_id uuid;
  v_ok boolean;
begin
  -- Serialize per user for the rest of this transaction. Two concurrent
  -- create-order calls for the same user now queue instead of racing.
  perform pg_advisory_xact_lock(hashtext(p_user::text));

  select id into v_existing
  from public.orders
  where user_id = p_user
    and service_id = p_service
    and country_id = p_country
    and status = 'waiting'
    and created_at >= now() - make_interval(secs => p_dedupe_seconds)
  order by created_at desc
  limit 1;

  if v_existing is not null then
    return jsonb_build_object('status', 'duplicate', 'order_id', v_existing);
  end if;

  -- Row first, so the charge always has something to point at.
  insert into public.orders (user_id, service_id, country_id, cost_credits, status)
  values (p_user, p_service, p_country, p_credits, 'waiting')
  returning id into v_id;

  -- Charge, linked to the order. wallet_spend is a single conditional UPDATE
  -- and returns false rather than raising when the balance is short.
  select public.wallet_spend(p_user, p_credits, 'spend', v_id) into v_ok;

  if not coalesce(v_ok, false) then
    -- Same transaction, so this leaves no trace of a phantom order.
    delete from public.orders where id = v_id;
    return jsonb_build_object('status', 'insufficient_credits');
  end if;

  return jsonb_build_object('status', 'ok', 'order_id', v_id);
end;
$function$;

revoke execute on function public.begin_order(uuid, text, text, integer, integer)
  from public, anon, authenticated;
