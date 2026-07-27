-- Schema hardening from the security audit. Closes one whole bug CLASS plus
-- several missing integrity constraints and two hot-path indexes.

-- ── S3. Write grants RLS cannot restrain.
--
-- TRUNCATE is NOT subject to row security — a role holding it empties the table
-- whatever the policies say. PostgREST never emits TRUNCATE so this isn't
-- reachable today, but telegram_events is the exactly-once claim table: one
-- accidental permissive policy away from letting any user delete claim rows and
-- force duplicate sends. Neither table needs a client write.
revoke insert, update, delete, truncate on public.profiles from anon, authenticated;
-- Re-assert the ONE legitimate client write (column-scoped, as 20260721040000
-- established after table-wide UPDATE let users point referrals at themselves).
grant update (display_name) on public.profiles to authenticated;
revoke all on public.telegram_events from anon, authenticated;

-- ── S4. The ledger's two load-bearing references were unenforced.
--
-- 20260727160000's header claimed "order_id FKs public.orders" to justify the
-- separate esim_order_id column. It does not — wallet_transactions had exactly
-- three constraints and neither order_id nor iap_receipt_id was among them. The
-- separate column is still right; the stated reason was false.
--
-- ON DELETE SET NULL, not RESTRICT: both parents cascade from auth.users and
-- Postgres does not guarantee cascade ordering, so RESTRICT could block account
-- deletion.
alter table public.wallet_transactions
  add constraint wallet_transactions_order_id_fkey
    foreign key (order_id) references public.orders(id) on delete set null,
  add constraint wallet_transactions_iap_receipt_id_fkey
    foreign key (iap_receipt_id) references public.iap_receipts(id) on delete set null;

-- ── S7. Nothing at the DB level stopped the eSIM double-insert that shipped
-- today from recurring — the same provider transaction could be recorded twice.
create unique index if not exists esim_orders_smspool_tx_key
  on public.esim_orders (smspool_tx) where smspool_tx is not null;
alter table public.esim_orders alter column plan_id set not null;

-- ── S8. Status/provider typos are silent and catastrophic.
--
-- esim_plans.status is unconstrained text and the client filters status=eq.active
-- — so one typo in sync-esim-plans hides the entire eSIM catalog with no error.
-- routes.provider is worse: active_sms_provider() returns whichever provider owns
-- the most active routes, so a typo can invent a phantom provider and orphan
-- every maintenance function at once. That is the precise failure the
-- provider-switch checklist exists to prevent.
alter table public.esim_plans
  add constraint esim_plans_status_check check (status in ('active','hidden'));
alter table public.routes
  add constraint routes_provider_check check (provider in ('smspva','smspool','virtualsms'));
alter table public.orders
  add constraint orders_provider_check check (provider in ('smspva','smspool','virtualsms'));

-- ── S9/S10. Hot-path indexes.
--
-- routes freshness is a full seq scan (18,492 rows, 27ms, 748 buffers) every 10
-- minutes forever via run_watchdog, plus the same shape hourly in sync-prices.
-- wallet_transactions is the only event table with no created_at index, and it
-- is the one that grows with revenue — ops_snapshot powers the digest and /stats.
create index if not exists routes_provider_checked_idx
  on public.routes (provider, last_checked_at desc);
create index if not exists routes_provider_rate_source_idx
  on public.routes (provider, rate_source) where rate_source is not null;
create index if not exists wallet_transactions_created_at_idx
  on public.wallet_transactions (created_at desc);
