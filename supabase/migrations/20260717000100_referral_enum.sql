-- Referral credits get their own ledger reason (separate from signup_bonus /
-- adjustment) so they're attributable in analytics. Added in its own migration
-- because a new enum value can't be used in the same transaction that adds it.
alter type public.wallet_reason add value if not exists 'referral';
