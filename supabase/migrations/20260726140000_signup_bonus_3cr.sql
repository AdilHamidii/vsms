-- Signup bonus 5 -> 3 credits (owner decision 2026-07-26, hours after
-- 20260726130000 raised it 1 -> 5).
--
-- The evidence says 3 is the right number, and that 5 was overshooting. The
-- decisive cliff is between 1 and 2 credits, NOT between 3 and 5. Measured
-- against the live catalog and the 30 days of orders to 2026-07-26:
--
--   grant   routes reachable   % of active catalog   delivery at that price
--   1 cr                  24                0.15%   10.9%  (46 orders)
--   2 cr                 971                5.96%   40.0%  (15 orders)
--   3 cr               1,636               10.03%   39.3%  (28 orders)  <- here
--   4 cr               2,401               14.73%   53.8%  (13 orders)
--   5 cr               2,851               17.49%    —     ( 1 order, noise)
--
-- Delivery roughly QUADRUPLES from 1 -> 2 credits (10.9% -> 40.0%) and is then
-- flat through 3. Going 3 -> 5 buys catalog breadth (10.0% -> 17.5%) but no
-- measurable delivery improvement, and the 3-credit price point carries the
-- LARGEST order sample in the whole 2-5 range, so it is the best-evidenced
-- point available. The 53.8% at 4 credits is on 13 orders and is contradicted
-- by the single 5-credit order at 0%; not enough to justify the extra spend.
--
-- Cost: capped at 3 x $0.05 = $0.15 of wholesale per signup (down from $0.25),
-- so <= $1.65/day at the current ~11 signups/day, against ~$5.85/day revenue.
--
-- Still a 68x improvement in reach over the 1-credit grant this replaced
-- (24 -> 1,636 routes), which was the actual bug: the 3x -> 6x margin change on
-- 2026-07-25 devalued the fixed grant and nothing recomputed it.
--
-- Only affects users created after this runs. Users created in the window
-- between 20260726130000 and this migration keep their 5 credits — that is
-- correct, not a discrepancy to repair.
--
-- History of this grant: 5 at launch (20260528000001), 1 (20260530100000),
-- 3 (20260716000100, 20260717000200), 1 (20260721130000), 5 (20260726130000),
-- 3 here.
--
-- Re-creates the CURRENT handle_new_user verbatim, changing only the amount.
-- Keep in lockstep with the onboarding copy in
-- VirtualSIM/Onboarding/OnboardingScreen.swift, which states the amount to the
-- user BEFORE they sign in.

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
