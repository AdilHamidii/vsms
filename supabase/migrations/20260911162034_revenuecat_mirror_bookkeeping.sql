-- Mirror Apple purchases into RevenueCat, for the owner's phone dashboard.
--
-- Bookkeeping only: nothing here decides money, grants an entitlement, or gates
-- a product. RevenueCat is a READ surface. `has_email_subscription`,
-- `reclaim_lapsed_lines` and `credit_iap_purchase` are untouched and must stay
-- that way - the entitlement truth is Postgres, and a third party being down
-- may never cost a subscriber their phone number.
--
-- Why a sweep instead of forwarding from `iap-verify` / `apple-notifications`:
-- RevenueCat requires the receipts call to actually land ("if you don't have
-- this endpoint hit for that user, that subscription will most likely not be
-- tracked"). An inline fire-and-forget POST in a money path would fail silently
-- - the exact shape of the four `wallet_credit` bugs this repo has already
-- fixed. A sweep that reads its own backlog cannot lose a row: an unsynced row
-- stays unsynced and is retried.

-- Packs: a consumable purchase is immutable, so one shot is enough.
alter table public.iap_receipts
  add column if not exists rc_synced_at     timestamptz,
  add column if not exists rc_sync_attempts integer not null default 0,
  add column if not exists rc_sync_error    text;

-- Subscriptions: a renewal REWRITES `latest_signed_transaction`, so a boolean
-- "synced" would mirror the first period and then go quiet forever. Track WHICH
-- transaction was mirrored; the sweep re-sends when it moves.
alter table public.line_subscriptions
  add column if not exists rc_synced_txn    text,
  add column if not exists rc_synced_at     timestamptz,
  add column if not exists rc_sync_attempts integer not null default 0,
  add column if not exists rc_sync_error    text;

alter table public.email_subscriptions
  add column if not exists rc_synced_txn    text,
  add column if not exists rc_synced_at     timestamptz,
  add column if not exists rc_sync_attempts integer not null default 0,
  add column if not exists rc_sync_error    text;

-- Sweep indexes. Sandbox is deliberately excluded everywhere: those receipts
-- are genuinely Apple-signed and cost $0, so mirroring them would invent
-- revenue on the very dashboard this exists to make trustworthy. Same reasoning
-- as `credit_iap_purchase`'s Production gate, for a different consequence.
create index if not exists iap_receipts_rc_pending_idx
  on public.iap_receipts (created_at)
  where rc_synced_at is null
    and environment = 'Production'
    and raw_jws is not null
    and rc_sync_attempts < 10;

create index if not exists line_subscriptions_rc_pending_idx
  on public.line_subscriptions (updated_at)
  where environment = 'Production'
    and latest_signed_transaction is not null
    and rc_sync_attempts < 10;

create index if not exists email_subscriptions_rc_pending_idx
  on public.email_subscriptions (updated_at)
  where environment = 'Production'
    and latest_signed_transaction is not null
    and rc_sync_attempts < 10;
