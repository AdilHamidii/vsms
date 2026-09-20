-- rc-sync: make "needs mirroring" answerable in SQL.
--
-- 🔴 THE BUG THIS FIXES. `rc-sync` selected the 40 oldest rows by `updated_at`
-- and then skipped the already-synced ones IN JAVASCRIPT. Once a table held
-- more than 40 rows, the batch filled entirely with synced rows the loop threw
-- away, and the rows that actually needed syncing — always the NEWEST, because
-- both a purchase and a renewal set `updated_at = now()` — sat behind that wall
-- and were never reached. It is not a delay that drains: every new subscription
-- lands at the end of an ascending sort, so the mirror stops forever.
--
-- Observed 2026-09-20: `line_subscriptions` reached 42 matching rows, ranks
-- 1..40 all synced, ranks 41 (09-19 23:40) and 42 (09-20 18:37) stranded with
-- `rc_sync_attempts = 0` — never even attempted. `email_subscriptions` had 24
-- rows and kept working, which is exactly why RevenueCat showed mail.monthly
-- and no line.monthly.
--
-- PostgREST cannot compare two columns in a filter, which is why the predicate
-- lived in TypeScript at all. A STORED generated column moves it into SQL, so
-- the sweep can ask for pending rows directly and its cost scales with the
-- backlog instead of the table.
--
-- `IS DISTINCT FROM` (not `<>`) is required: `rc_synced_txn` is NULL on a row
-- that has never synced, and `NULL <> 'x'` is NULL, not true — the never-synced
-- rows, the ones that matter most, would be filtered out.
--
-- Verified before writing: zero rows in either table have
-- `latest_signed_transaction IS NOT NULL AND last_transaction_id IS NULL`, so
-- no row is silently excluded by depending on `last_transaction_id`. If that
-- ever changes, such a row reads NOT pending and would never mirror.
--
-- RevenueCat is a read-only mirror: it grants no entitlement, gates no product
-- and settles no money. This migration cannot affect billing.

alter table public.line_subscriptions
  add column if not exists rc_pending boolean
  generated always as (rc_synced_txn is distinct from last_transaction_id) stored;

alter table public.email_subscriptions
  add column if not exists rc_pending boolean
  generated always as (rc_synced_txn is distinct from last_transaction_id) stored;

-- Partial indexes: the sweep only ever asks for the true rows, and in the
-- steady state there are none, so these stay tiny.
create index if not exists line_subscriptions_rc_pending_idx
  on public.line_subscriptions (updated_at) where rc_pending;

create index if not exists email_subscriptions_rc_pending_idx
  on public.email_subscriptions (updated_at) where rc_pending;

comment on column public.line_subscriptions.rc_pending is
  'Generated: this row still needs mirroring to RevenueCat. Read by rc-sync so '
  'the batch cannot fill with already-synced rows (see 20260920200000).';
comment on column public.email_subscriptions.rc_pending is
  'Generated: this row still needs mirroring to RevenueCat. Read by rc-sync so '
  'the batch cannot fill with already-synced rows (see 20260920200000).';
