-- Two-sided referral: the invitee now gets 2 credits immediately when their
-- invite code is accepted (the inviter still earns 5 on the invitee's first
-- pack purchase, unchanged). Redemption stays set-once per user, so the extra
-- surface for farming is one grant per fresh Apple ID — same cost profile as
-- the signup bonus itself.
--
-- Also rolls in the outstanding DB-advisor fixes: pin gen_referral_code's
-- search_path, and cover the two unindexed foreign keys.

create or replace function public.redeem_referral(p_referee uuid, p_code text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
    v_referrer uuid;
begin
    if p_code is null or length(trim(p_code)) = 0 then
        return 'invalid_code';
    end if;
    if exists (select 1 from public.profiles where user_id = p_referee and referred_by is not null) then
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

    -- Welcome bonus for the invitee, granted once (redemption is set-once).
    perform public.wallet_credit(p_referee, 2, 'referral_invitee', null, null);
    return 'ok';
end;
$$;

-- CREATE OR REPLACE preserves privileges, but re-assert the revoke to stay safe.
revoke execute on function public.redeem_referral(uuid, text) from public, anon, authenticated;

-- Advisor: function_search_path_mutable on gen_referral_code.
alter function public.gen_referral_code() set search_path = '';

-- Advisor: unindexed foreign keys.
create index if not exists esim_orders_plan_id_idx  on public.esim_orders (plan_id);
create index if not exists profiles_referred_by_idx on public.profiles (referred_by);
