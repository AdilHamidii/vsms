-- eSIM: link wallet moves to their order, and clean up the double-insert orphans.
--
-- 1) LEDGER LINK. begin_esim_order calls wallet_spend(..., null) and failEsim
--    calls wallet_credit(...) with no order at all, both violating the standing
--    rule "always pass p_order so the ledger reconciles". esim_orders.id cannot
--    go in wallet_transactions.order_id — that column FKs public.orders — so
--    the ledger needs its own sibling column. Without it eSIM spends and
--    refunds are unattributable, which is the same unreconcilable state that
--    produced "258 spends vs 126 orders" for SMS.
--
-- 2) ORPHANS. create-esim-order INSERTed a second row instead of updating the
--    one begin_esim_order reserved, so every purchase since 20260725180000 left
--    a permanent 'provisioning' row with no smspool_tx. expire_esim_orders()
--    cannot reach them (it requires a non-null expires_at), so the buyer sees a
--    phantom eSIM forever and every revenue aggregate double-counts.
--    The function is fixed; this closes the rows it already created.
--    Their credits were NOT lost — the real row carries the same cost and the
--    user got the eSIM — so these are closed as 'canceled' with no refund.

alter table public.wallet_transactions
  add column if not exists esim_order_id uuid references public.esim_orders(id) on delete set null;

create index if not exists wallet_transactions_esim_order_idx
  on public.wallet_transactions (esim_order_id)
  where esim_order_id is not null;

comment on column public.wallet_transactions.esim_order_id is
  'eSIM counterpart to order_id (which FKs public.orders). Exactly one of the '
  'two is set for a product-related move; both null for signup/daily/referral.';

-- Overload that records the eSIM order. Kept separate from wallet_spend/
-- wallet_credit rather than adding a parameter, so no existing caller changes
-- shape and no ambiguous-overload risk is introduced.
create or replace function public.wallet_move_esim(
  p_user uuid,
  p_amount integer,
  p_reason wallet_reason,
  p_esim_order uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if p_amount is null or p_amount = 0 then
    raise exception 'wallet_move_esim: amount must be non-zero';
  end if;

  update public.wallets
     set balance = balance + p_amount, updated_at = now()
   where user_id = p_user;
  if not found then
    raise exception 'wallet_move_esim: no wallet for user %', p_user;
  end if;

  insert into public.wallet_transactions (user_id, delta, reason, esim_order_id)
  values (p_user, p_amount, p_reason, p_esim_order);
end;
$function$;

revoke execute on function public.wallet_move_esim(uuid, integer, wallet_reason, uuid)
  from public, anon, authenticated;

-- Close the orphans left by the double-insert. Identified precisely: a
-- provisioning row with no transaction id, where the SAME user holds another
-- row for the SAME plan created within a minute that DID get one.
-- 'failed' — NOT 'canceled'. esim_status is
--    (provisioning, installed, active, depleted, expired, refunded, failed);
--    'canceled' is a value of order_status, a different enum.
update public.esim_orders o
set status = 'failed', updated_at = now()
where o.status = 'provisioning'
  and o.smspool_tx is null
  and exists (
    select 1 from public.esim_orders d
    where d.user_id = o.user_id
      and d.plan_id = o.plan_id
      and d.id <> o.id
      and d.smspool_tx is not null
      and abs(extract(epoch from (d.created_at - o.created_at))) < 60
  );
