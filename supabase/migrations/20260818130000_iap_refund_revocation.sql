-- Apple REFUND / REVOKE for CONSUMABLE credit packs.
--
-- ── The exposure ───────────────────────────────────────────────────────────
-- `apple-notifications` handled CONSUMPTION_REQUEST for consumables and then
-- returned at `if (!isSubscriptionProduct(tx.productId)) return;` — so REFUND
-- and REVOKE for a credit pack were dropped entirely: no log, no alert, no
-- revocation. `iap_receipts` had no revocation column and nothing anywhere
-- consumed `revocationDate`. A user could buy a pack, spend the credits, ask
-- Apple for a refund, and keep both. Live exposure at the time of writing is
-- 3 refund requests, all REFUND_DECLINED (so $0 realized) — the moment Apple
-- grants one, 100% of it leaks. The same account produced the only
-- `iap_grants.grant_count = 2` on record, i.e. a replay attempt that
-- `credit_iap_purchase` correctly refused. This is not a theoretical actor.
--
-- ── One transaction, always ────────────────────────────────────────────────
-- The repo's standing rule: a status claim and its money move must be ONE
-- transaction, never two round-trips. A worker killed between "stamp the
-- receipt revoked" and "take the credits back" would leave a receipt that
-- looks handled with the credits still spendable, and nothing revisits a
-- terminal row. So the stamp, the ledger row and the balance move all happen
-- inside `revoke_iap_purchase` under one advisory lock, exactly as
-- `credit_iap_purchase` does for the granting direction.
--
-- ── Why a new wallet_reason ────────────────────────────────────────────────
-- 'refund' in this ledger means "money back TO the user" and carries a
-- POSITIVE delta everywhere it appears. Reusing it for a clawback would make
-- the word mean both directions at once and quietly corrupt every query that
-- reads it. 'revocation' is the negative-delta counterpart and exists only
-- here.

alter type public.wallet_reason add value if not exists 'revocation';

alter table public.iap_receipts
  add column if not exists revoked_at        timestamptz,
  add column if not exists revocation_reason text;

comment on column public.iap_receipts.revoked_at is
  'Set by revoke_iap_purchase() when Apple refunds/revokes the purchase. Non-null means the granted credits have been clawed back in the same transaction.';

create index if not exists iap_receipts_revoked_idx
  on public.iap_receipts (revoked_at) where revoked_at is not null;

-- Claw back the credits granted for one Apple transaction.
--
-- 🔴 THE CLAWBACK IS CAPPED AT THE LIVE BALANCE, and the design intent was the
-- opposite. A negative wallet is the truest statement of what is owed — but
-- `wallets` carries `wallets_balance_check (balance >= 0)`, a global invariant
-- every money path in this app has been written against, and relaxing it from
-- a refund handler would silently permit an overdraw on every OTHER path too
-- (`wallet_spend` guards itself with `balance >= p_amount`, but nothing else
-- would). Attempted and rejected: the first run of this function raised 23514
-- with `balance = -3`.
--
-- So we take what is there and REPORT THE REST rather than absorbing it. This
-- keeps `sum(wallet_transactions.delta) = wallets.balance` exact — the property
-- asserted across all 204 wallets on 2026-07-31 — while making the un-recovered
-- amount visible instead of quietly forgiven. The edge function pages on a
-- non-zero shortfall; it is real money lost to a user who spent credits they
-- no longer paid for.
--
-- What was NOT recovered, per receipt:
--   select r.id, r.granted_credits + t.delta as shortfall
--     from public.iap_receipts r
--     join public.wallet_transactions t on t.iap_receipt_id = r.id
--    where r.revoked_at is not null and t.reason = 'revocation';
--
-- Deliberately NOT routed through wallet_credit/wallet_spend: both raise on a
-- non-positive amount and wallet_spend refuses to move anything at all when
-- the balance is short, which is exactly the case that matters here.
create or replace function public.revoke_iap_purchase(
  p_transaction_id  text,
  p_revocation_date timestamptz default null,
  p_reason          text default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_receipt   public.iap_receipts%rowtype;
  v_balance   integer;
  v_clawed    integer;
  v_shortfall integer;
  v_n         integer;
begin
  if p_transaction_id is null or length(trim(p_transaction_id)) = 0 then
    return jsonb_build_object('status', 'invalid_transaction');
  end if;

  -- Same lock key shape as credit_iap_purchase, so a grant and a revocation
  -- for the same transaction can never interleave.
  perform pg_advisory_xact_lock(hashtext('iap:' || p_transaction_id));

  select * into v_receipt
    from public.iap_receipts
   where transaction_id = p_transaction_id
     and environment = 'Production'
   order by id desc
   limit 1
     for update;

  if not found then
    -- Sandbox / Xcode receipts move no money, and a deleted account takes its
    -- receipts with it (ON DELETE CASCADE) while `iap_grants` — which has no
    -- FK to auth.users — still refuses the replay. Nothing to claw back.
    return jsonb_build_object('status', 'not_found');
  end if;

  if v_receipt.revoked_at is not null then
    -- Apple retries at 1h/12h/24h/48h/72h. A second pass must not double-debit.
    return jsonb_build_object(
      'status', 'already_revoked',
      'credits', v_receipt.granted_credits,
      'revoked_at', v_receipt.revoked_at);
  end if;

  if coalesce(v_receipt.granted_credits, 0) <= 0 then
    -- Verified but never credited (a failed grant, or a rollback). Stamp it so
    -- the forensic trail records that Apple undid it, and move no money.
    update public.iap_receipts
       set revoked_at = coalesce(p_revocation_date, now()),
           revocation_reason = p_reason
     where id = v_receipt.id;
    return jsonb_build_object('status', 'nothing_granted', 'credits', 0);
  end if;

  update public.iap_receipts
     set revoked_at = coalesce(p_revocation_date, now()),
         revocation_reason = p_reason
   where id = v_receipt.id;

  -- Locked so the balance we read is the balance we debit. Without this a
  -- concurrent spend between the read and the write would make `v_clawed`
  -- describe a balance that no longer exists, and the ledger identity would
  -- break by exactly that amount.
  select balance into v_balance
    from public.wallets where user_id = v_receipt.user_id for update;

  if not found then
    -- No wallet to debit. The stamp stands (Apple really did undo it) and the
    -- absence is reported rather than raised: raising would return 500 and put
    -- Apple's retry ladder to work on something no retry can fix.
    return jsonb_build_object(
      'status', 'revoked_no_wallet',
      'credits', v_receipt.granted_credits,
      'user_id', v_receipt.user_id);
  end if;

  v_clawed    := least(v_balance, v_receipt.granted_credits);
  v_shortfall := v_receipt.granted_credits - v_clawed;

  if v_clawed > 0 then
    update public.wallets
       set balance = balance - v_clawed, updated_at = now()
     where user_id = v_receipt.user_id
    returning balance into v_balance;

    insert into public.wallet_transactions (user_id, delta, reason, iap_receipt_id)
    values (v_receipt.user_id, -v_clawed, 'revocation', v_receipt.id);
  end if;

  return jsonb_build_object(
    'status', 'revoked',
    'credits', v_receipt.granted_credits,
    'clawed_back', v_clawed,
    'shortfall', v_shortfall,
    'balance_after', v_balance,
    'user_id', v_receipt.user_id,
    'product_id', v_receipt.product_id);
end;
$$;

-- CREATE FUNCTION grants EXECUTE to PUBLIC by default, and anon/authenticated
-- are members of PUBLIC — revoking from them alone is a documented no-op in
-- this repo. Revoke from PUBLIC too, or this stays callable at
-- /rest/v1/rpc/revoke_iap_purchase.
revoke execute on function public.revoke_iap_purchase(text, timestamptz, text)
  from public, anon, authenticated;
