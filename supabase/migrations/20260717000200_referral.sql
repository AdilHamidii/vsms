-- Referral program: an inviter earns 5 credits when someone they referred makes
-- their first credit-pack purchase. Attribution is by short code (Sign in with
-- Apple gives us no contacts to match on), set once per referee and immutable.

alter table public.profiles
  add column if not exists referral_code       text,
  add column if not exists referred_by          uuid references auth.users(id) on delete set null,
  add column if not exists referral_rewarded_at timestamptz;

-- Short, shareable, case-insensitive-unique code.
create or replace function public.gen_referral_code()
returns text
language sql
volatile
as $$
  select upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 7));
$$;

-- Backfill existing users (retry-free at this scale; unique index added after).
update public.profiles
set referral_code = public.gen_referral_code()
where referral_code is null;

create unique index if not exists profiles_referral_code_key
  on public.profiles (upper(referral_code));

-- New users get a code at signup. (CREATE OR REPLACE preserves privileges, but
-- re-assert the public-execute revoke from 20260716000000 to stay correct.)
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into public.profiles (user_id, display_name, referral_code)
    values (
        new.id,
        coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
        public.gen_referral_code()
    );

    insert into public.wallets (user_id, balance, updated_at)
    values (new.id, 3, now());

    insert into public.wallet_transactions (user_id, delta, reason)
    values (new.id, 3, 'signup_bonus');

    return new;
end;
$$;

revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- Attach a referrer to the caller. Set-once, no self-referral. Runs SECURITY
-- DEFINER so it can look up another user's profile by code past RLS. Returns a
-- status string the edge function maps to a user message.
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
    return 'ok';
end;
$$;

-- Pay the inviter once, when the referee first buys. Idempotent via
-- referral_rewarded_at + a row lock, so calling it on every purchase is safe.
create or replace function public.apply_referral_reward(p_referee uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    v_referrer uuid;
    v_rewarded timestamptz;
begin
    select referred_by, referral_rewarded_at
        into v_referrer, v_rewarded
        from public.profiles
        where user_id = p_referee
        for update;
    if v_referrer is null or v_rewarded is not null then
        return false;
    end if;

    update public.profiles set referral_rewarded_at = now() where user_id = p_referee;
    perform public.wallet_credit(v_referrer, 5, 'referral', null, null);
    return true;
end;
$$;

-- Client roles must not call these directly (they'd let a user attach arbitrary
-- referrers or mint referral credit). Only the edge functions, via service_role.
revoke execute on function public.redeem_referral(uuid, text)     from public, anon, authenticated;
revoke execute on function public.apply_referral_reward(uuid)     from public, anon, authenticated;
revoke execute on function public.gen_referral_code()             from public, anon, authenticated;
