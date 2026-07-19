-- redeem_referral (two-sided referral, 20260719000000) writes 'referral_invitee'
-- and the winback grant writes 'winback_bonus' — neither existed in the
-- wallet_reason enum, which would make the first invitee redemption throw at
-- runtime (plpgsql string literals aren't type-checked at definition time).
alter type public.wallet_reason add value if not exists 'referral_invitee';
alter type public.wallet_reason add value if not exists 'winback_bonus';
