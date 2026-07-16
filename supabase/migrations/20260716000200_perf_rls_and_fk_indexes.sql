-- Performance advisor cleanup: RLS init-plan re-evaluation, unindexed FKs, and
-- one unused index. All idempotent.

-- 1) RLS init-plan: wrap auth.uid() in a scalar subselect so Postgres evaluates
--    it once per query instead of once per row. Same semantics, better plans at
--    scale. Recreate each flagged policy verbatim except for the (select ...).

drop policy if exists "profiles: self read" on public.profiles;
create policy "profiles: self read" on public.profiles
    for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists "profiles: self write" on public.profiles;
create policy "profiles: self write" on public.profiles
    for update to authenticated
    using (user_id = (select auth.uid()))
    with check (user_id = (select auth.uid()));

drop policy if exists "wallets: self read" on public.wallets;
create policy "wallets: self read" on public.wallets
    for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists "wallet_transactions: self read" on public.wallet_transactions;
create policy "wallet_transactions: self read" on public.wallet_transactions
    for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists "orders: self read" on public.orders;
create policy "orders: self read" on public.orders
    for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists "push_devices: self read" on public.push_devices;
create policy "push_devices: self read" on public.push_devices
    for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists "iap_receipts: self read" on public.iap_receipts;
create policy "iap_receipts: self read" on public.iap_receipts
    for select to authenticated using (user_id = (select auth.uid()));

-- 2) Covering indexes for foreign keys that lacked one. routes is ~16k rows and
--    joins/filters on country_id; orders FKs will matter as volume grows.
create index if not exists orders_service_id_idx on public.orders(service_id);
create index if not exists orders_country_id_idx on public.orders(country_id);
create index if not exists routes_country_id_idx on public.routes(country_id);

-- 3) Drop the never-used index on iap_receipts.original_transaction_id. Credits
--    are one-shot consumables (no subscriptions), iap-verify dedupes on the
--    unique transaction_id, and nothing queries by original_transaction_id, so
--    this index only adds write overhead on every receipt insert.
drop index if exists public.iap_receipts_original_idx;
