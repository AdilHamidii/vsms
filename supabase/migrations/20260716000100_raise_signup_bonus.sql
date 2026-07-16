-- Growth: raise the signup bonus 1 -> 3 credits to unblock activation.
--
-- Data (2026-07-16): 59 signups, only 8 ever ordered (13.6% activation), and 50
-- users sit at exactly 1 credit having never placed an order. The 1-credit bonus
-- can't cover the services people actually want (e.g. leboncoin/nl = 4cr,
-- leboncoin/ro = 3cr), so first-order intent dies at the paywall. 3 credits buys
-- a real first order of a popular route. Outstanding credit liability is tiny
-- (~191 cr across 58 wallets), so the downside is negligible vs. the activation
-- upside. Only affects users created after this runs.
--
-- CREATE OR REPLACE preserves existing privileges, so the PUBLIC-execute revoke
-- from 20260716000000 is retained; we re-assert it here to stay correct
-- regardless of apply order.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into public.profiles (user_id, display_name)
    values (new.id, coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)));

    insert into public.wallets (user_id, balance, updated_at)
    values (new.id, 3, now());

    insert into public.wallet_transactions (user_id, delta, reason)
    values (new.id, 3, 'signup_bonus');

    return new;
end;
$$;

revoke execute on function public.handle_new_user() from public, anon, authenticated;
