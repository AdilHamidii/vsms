-- Backend hardening batch (from the 2026-07-21 four-agent audit). None of
-- these change current behavior — every one is a belt-and-suspenders invariant
-- or a scoped-down grant that RLS was already enforcing.

-- ── 6) Double-refund can never recur, at the schema level ────────────────
-- Three orders were historically refunded twice (39cr leaked) before the
-- atomic-claim guards landed. Every current refund path does compare-and-swap
-- before wallet_credit, so this is convention-enforced across N call sites —
-- one forgetful future path silently reintroduces it. A partial unique index
-- makes "at most one refund per order" a hard DB invariant.
--
-- Three historical orders (from before the atomic-claim guards) still carry a
-- duplicate refund row. Relabel the erroneous SECOND row of each to
-- 'adjustment' — money-neutral (delta unchanged, so balances still reconcile,
-- no clawback from users who received the credits weeks ago) and more accurate
-- than 'refund' for what it is: an erroneous extra credit. This clears the way
-- for the invariant without rewriting history's dollar amounts.
update public.wallet_transactions
set reason = 'adjustment'
where id in (278, 205, 281)
  and reason = 'refund'
  and order_id in (
    '041dba74-b8ff-4386-b322-b65cfbdc7a15',
    '9205d5e7-6c6b-49b3-838e-63676cb21d29',
    'e7e3c2eb-96a1-4239-a729-8d553251d796');

create unique index if not exists wallet_transactions_refund_once_idx
  on public.wallet_transactions (order_id)
  where reason = 'refund' and order_id is not null;

-- ── 7) app_config: clients only ever need the maintenance flag ───────────
-- The old policy let any signed-in user read every key — provider USD
-- balances (smspva_health/smspool_health), the anti-abuse blocked_routes
-- list, sync cursors. iOS only reads key='maintenance' (MaintenanceAPI).
-- Edge functions use the service role, which bypasses RLS, so this doesn't
-- affect them.
drop policy if exists app_config_read on public.app_config;
create policy app_config_read on public.app_config
  for select to authenticated
  using (key = 'maintenance');

-- ── 8) Defense-in-depth: revoke client write on money + catalog tables ───
-- Supabase's platform default grants ALL to anon/authenticated on every
-- table; RLS is currently the ONLY thing preventing writes. If a future
-- migration ever disables RLS on one of these (even briefly, to backfill),
-- the table becomes world-writable with no second layer. Clients never write
-- any of these — every mutation goes through a service-role edge function —
-- so revoking write is invisible today and closes that failure mode.
revoke insert, update, delete, truncate on
  public.wallets, public.wallet_transactions, public.orders,
  public.esim_orders, public.iap_receipts, public.push_devices,
  public.routes, public.services, public.countries, public.esim_plans,
  public.app_config
  from anon, authenticated;

-- ── 10) Index the analytics hot path before it becomes a seq-scan cliff ──
-- refresh_route_observed_success (3d), refresh_service_delivery (30d) and
-- ops_snapshot all filter orders by (provider, created_at) with closed_at not
-- null, and the first two run every hour from sync-prices. Free at 126 rows,
-- a repeated full scan once the table is 100-1000x larger.
create index if not exists orders_provider_created_idx
  on public.orders (provider, created_at)
  where closed_at is not null;
