-- Stop clients writing their own referral state.
--
-- `profiles` had exactly one write policy — "profiles: self write", qual
-- `user_id = auth.uid()`. That is ROW-level, and Postgres RLS cannot express
-- "this row but only these columns". Combined with a table-wide UPDATE grant,
-- `authenticated` (and `anon`) could PATCH any column of their own profile
-- through PostgREST, including:
--
--     referred_by            -- who invited me
--     referral_rewarded_at   -- whether the 5-credit payout already happened
--
-- redeem_referral() refuses self-referral and apply_referral_reward() pays out
-- once, but both are SECURITY DEFINER functions correctly revoked from clients
-- — and both decide by READING these two columns. Letting the user write the
-- inputs makes the guards decorative:
--
--   1. PATCH profiles SET referred_by = <my own user_id>   (self-referral,
--      which redeem_referral() explicitly rejects at the front door)
--   2. make a real purchase -> iap-verify calls apply_referral_reward()
--      -> pays me 5 credits
--   3. PATCH profiles SET referral_rewarded_at = null      -> repeat forever
--
-- Every subsequent purchase mints 5 unearned credits, which spend against real
-- provider money. No second account required.
--
-- Fix: no blanket UPDATE for clients. Re-grant only display_name, the sole
-- genuinely user-owned field. Nothing in the app writes profiles today
-- (ProfileAPI issues a GET; referral redemption goes through the
-- redeem-referral edge function on the service role), so this removes an
-- attack surface without removing a capability.

revoke update on public.profiles from anon, authenticated;

grant update (display_name) on public.profiles to authenticated;

-- Defence in depth: even a future service-role bug shouldn't be able to record
-- someone as their own inviter.
alter table public.profiles
  drop constraint if exists profiles_no_self_referral;
alter table public.profiles
  add constraint profiles_no_self_referral
  check (referred_by is null or referred_by <> user_id);
