-- Signup bonus 1 -> 5 credits (owner decision 2026-07-26).
--
-- WHY, with the numbers that forced it. The 3x -> 6x margin change on
-- 2026-07-25 halved every retail price's purchasing power, and nothing moved
-- the signup grant to match. Measured 2026-07-26 against the live catalog:
--
--   routes an active 1-credit balance can buy, old 3x divisor (0.10):  971
--   routes an active 1-credit balance can buy, new 6x divisor (0.05):   24
--
-- A 97.5% collapse — from ~6% of the catalog to 0.15% of 16,303 active
-- routes, against a median route price of 12 credits. The grant was not
-- "small", it was functionally zero.
--
-- Worse, the surviving 24 routes are the WORST inventory we sell. Delivery by
-- price band over the 30 days to 2026-07-26:
--
--   1 credit      46 orders   5 delivered   10.9%   <- where new users are trapped
--   2-5 credits   57 orders  24 delivered   42.1%   <- where 5 credits lands them
--   6-15 credits  29 orders   6 delivered   20.7%
--   16+ credits    6 orders   0 delivered    0.0%
--
-- So the free credit bought a ~1-in-9 shot on a cluster dominated by unproven
-- Colombia routes carrying no measured success data at all, and that was every
-- new user's entire first impression. In the 24h to 2026-07-26: 11 signups,
-- 2 orders, 0 codes, 0 purchases. Both of those orders cost exactly 1 credit
-- and both expired.
--
-- 5 credits is chosen deliberately, NOT as "more is better". Delivery does not
-- improve monotonically with price — the 6-15 band (20.7%) and 16+ band (0%)
-- are both worse than 2-5. Paying more buys country cost, not quality; SMSPVA
-- per-country carrier prices carry no quality signal (see CLAUDE.md). 5 credits
-- is the smallest grant that reaches the 42.1% band, opening 2,851 routes
-- instead of 24.
--
-- COST: capped at 5 x $0.05 = $0.25 of wholesale per signup, and only if the
-- user spends all of it. At the current ~11 signups/day that is <= $2.75/day
-- against ~$5.85/day of revenue. It is a real cost; it is bounded, and the
-- alternative measured above is a 0%-conversion funnel.
--
-- Only affects users created after this runs — the trigger fires on insert
-- into auth.users. Existing users are NOT topped up; 48 accounts currently sit
-- at exactly 1 credit and would need a separate, deliberate backfill.
--
-- History of this grant: 5 at launch (20260528000001), 1 (20260530100000),
-- 3 (20260716000100, 20260717000200), 1 (20260721130000), 5 here.
--
-- This re-creates the CURRENT handle_new_user verbatim (verified against
-- pg_get_functiondef on 2026-07-26 — referral-aware, profiles get a
-- referral_code), changing ONLY the granted amount. Keep the three numbers
-- below in lockstep: wallets.balance, wallet_transactions.delta, and the
-- onboarding copy in VirtualSIM/Onboarding/OnboardingScreen.swift, which
-- states the amount to the user before they sign in.

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
    values (new.id, 5, now());

    insert into public.wallet_transactions (user_id, delta, reason)
    values (new.id, 5, 'signup_bonus');

    return new;
end;
$$;

revoke execute on function public.handle_new_user() from public, anon, authenticated;
