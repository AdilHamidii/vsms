-- Money-path hardening: make credit grants survive account deletion.
--
-- Everything user-scoped cascades from auth.users. That is correct for user
-- data and wrong for "have we already paid this out?", because Apple's Delete
-- Account requirement means any user can erase our only record of a grant and
-- then present the same evidence again. `signup_grants` already exists for
-- exactly this reason — it tombstones the signup bonus on a hash of the email,
-- outside the cascade. That reasoning was never extended to the two other
-- grants, and both are replayable today:
--
--   1. IAP purchases. `iap_receipts` is ON DELETE CASCADE and the sole replay
--      guard is unique(transaction_id) ON THAT TABLE. A user reads their own
--      raw_jws (authenticated holds SELECT), buys once, spends, deletes the
--      account, signs in again and resubmits. It re-verifies against Apple
--      perfectly, because the receipt IS genuine — it just isn't new. Nothing
--      in _shared/iap.ts binds a receipt to a user (appAccountToken is never
--      read) and the cert chain is checked at signedDate, so it never ages out.
--
--   2. The referral bonus. `redeem_referral` gates on profiles.referred_by,
--      and profiles cascades too. +2 credits per delete/re-signup cycle.
--
-- Neither has ever been exploited: 0 receipts are orphaned from a deleted user
-- and the ledger reconciles exactly across all 204 wallets. This closes them
-- before that changes.

-- ── 1. The IAP tombstone ────────────────────────────────────────────────────
-- Deliberately NO foreign key on last_user_id. A reference to auth.users is
-- precisely what would delete this row along with the account, which is the
-- bug. The column is informational; the primary key is the whole point.
--
-- Keyed on transaction_id, not original_transaction_id: consumables mint a new
-- transaction_id per purchase, so this blocks replaying one purchase while
-- leaving genuine repeat purchases of the same pack unaffected.
create table if not exists public.iap_grants (
    transaction_id          text primary key,
    original_transaction_id text,
    credits                 integer     not null,
    first_granted_at        timestamptz not null default now(),
    -- Counts REPLAY ATTEMPTS, like signup_grants.grant_count. A value above 1
    -- means someone presented an already-granted receipt again — which is the
    -- signal that this defence is load-bearing rather than theoretical.
    grant_count             integer     not null default 1,
    last_user_id            uuid
);

alter table public.iap_grants enable row level security;
revoke all on public.iap_grants from anon, authenticated;

comment on table public.iap_grants is
  'Tombstone: one row per Apple transaction_id ever credited. Lives OUTSIDE the auth.users cascade so Delete Account cannot erase the record of a payout. Never add a FK to auth.users.';

-- Backfill from receipts that genuinely moved money. Without this, every
-- purchase made before today stays replayable.
--
-- The filter is `granted_credits > 0`, which deliberately EXCLUDES rows the
-- old rollback zeroed: those are payments we took and never credited, and they
-- must stay recoverable rather than be tombstoned as already-paid.
insert into public.iap_grants (transaction_id, original_transaction_id, credits,
                               first_granted_at, last_user_id)
select r.transaction_id, r.original_transaction_id, r.granted_credits,
       coalesce(r.created_at, now()), r.user_id
from public.iap_receipts r
where r.environment = 'Production'
  and coalesce(r.granted_credits, 0) > 0
on conflict (transaction_id) do nothing;

-- ── 2. Tombstone + credit, atomically ───────────────────────────────────────
-- One entry point so the check and the payout cannot drift apart. The advisory
-- lock serialises the two StoreKit paths (Transaction.updates and the
-- unfinished sweep), which can carry the same JWS concurrently.
--
-- If wallet_credit raises, the whole transaction rolls back INCLUDING the
-- tombstone insert, so a retry credits normally. That is what makes the caller
-- safe to simply call again — the previous design needed a TypeScript-level
-- rollback that contradicted its own retry guard.
create or replace function public.credit_iap_purchase(
    p_user                    uuid,
    p_receipt                 bigint,
    p_amount                  integer,
    p_transaction_id          text,
    p_original_transaction_id text default null
) returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_n integer;
begin
    if p_transaction_id is null or length(trim(p_transaction_id)) = 0 then
        return 'invalid_transaction';
    end if;
    if p_amount is null or p_amount <= 0 then
        return 'invalid_amount';
    end if;

    perform pg_advisory_xact_lock(hashtext('iap:' || p_transaction_id));

    insert into public.iap_grants (transaction_id, original_transaction_id,
                                   credits, last_user_id)
    values (p_transaction_id, p_original_transaction_id, p_amount, p_user)
    on conflict (transaction_id) do nothing;
    get diagnostics v_n = row_count;

    if v_n = 0 then
        -- Already paid out, possibly to an account that no longer exists.
        update public.iap_grants
           set grant_count = grant_count + 1
         where transaction_id = p_transaction_id;
        return 'already_granted';
    end if;

    perform public.wallet_credit(p_user, p_amount, 'purchase', null, p_receipt);

    -- Keep the receipt honest. The caller inserts granted_credits = 0 and this
    -- is what makes it non-zero, so the column always reflects money that
    -- actually moved rather than money we intended to move.
    if p_receipt is not null then
        update public.iap_receipts
           set granted_credits = p_amount
         where id = p_receipt;
    end if;

    return 'granted';
end;
$$;

-- CREATE FUNCTION grants EXECUTE to PUBLIC, and anon/authenticated are members
-- of PUBLIC — so revoking from them alone is a no-op. Revoke from PUBLIC too.
revoke execute on function public.credit_iap_purchase(uuid, bigint, integer, text, text)
    from public, anon, authenticated;

-- ── 3. Tombstone the referral bonus ─────────────────────────────────────────
alter table public.signup_grants
    add column if not exists referral_redeemed_at timestamptz;

comment on column public.signup_grants.referral_redeemed_at is
  'Set by redeem_referral. profiles.referred_by cascades from auth.users, so it cannot be the durable record of an invitee payout.';

create or replace function public.redeem_referral(p_referee uuid, p_code text)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
    v_referrer uuid;
    v_n        integer;
    v_hash     text;
begin
    if p_code is null or length(trim(p_code)) = 0 then
        return 'invalid_code';
    end if;

    -- Serialise per invitee so two concurrent redemptions cannot both pay.
    perform pg_advisory_xact_lock(hashtext(p_referee::text));

    if exists (select 1 from public.profiles
                where user_id = p_referee and referred_by is not null) then
        return 'already_referred';
    end if;

    -- Durable identity check. The predicate above reads `profiles`, which is
    -- erased by Delete Account, so on its own it re-opens the +2 on every
    -- re-signup. signup_grants lives outside that cascade and is keyed on the
    -- same md5(lower(email)) as handle_new_user — Apple's private relay
    -- address is stable per (user, app), so it survives deletion.
    --
    -- Fails OPEN on a null email, matching handle_new_user's stated policy: a
    -- blocked redemption for a legitimate user costs more than a rare
    -- duplicate.
    select md5(lower(u.email)) into v_hash from auth.users u where u.id = p_referee;
    if v_hash is not null and exists (
        select 1 from public.signup_grants
         where email_hash = v_hash and referral_redeemed_at is not null
    ) then
        return 'already_referred';
    end if;

    select user_id into v_referrer
        from public.profiles
        where upper(referral_code) = upper(trim(p_code));
    if v_referrer is null then return 'invalid_code'; end if;
    if v_referrer = p_referee then return 'self'; end if;

    update public.profiles
        set referred_by = v_referrer
        where user_id = p_referee and referred_by is null;

    -- Only pay if THIS call is the one that claimed the referral.
    get diagnostics v_n = row_count;
    if v_n = 0 then return 'already_referred'; end if;

    if v_hash is not null then
        update public.signup_grants
           set referral_redeemed_at = now()
         where email_hash = v_hash;
    end if;

    perform public.wallet_credit(p_referee, 2, 'referral_invitee', null, null);
    return 'ok';
end;
$$;

-- Backfill: anyone already referred has had their payout, so record it before
-- their account can be deleted and the evidence lost with it.
update public.signup_grants g
   set referral_redeemed_at = now()
  from public.profiles p
  join auth.users u on u.id = p.user_id
 where p.referred_by is not null
   and u.email is not null
   and g.email_hash = md5(lower(u.email))
   and g.referral_redeemed_at is null;
