-- Phase E: in-app purchase receipts.
-- transaction_id is globally unique per Apple — we use it for idempotency.

create table public.iap_receipts (
    id                bigserial primary key,
    user_id           uuid not null references auth.users(id) on delete cascade,
    transaction_id    text not null unique,
    original_transaction_id text not null,
    product_id        text not null,
    bundle_id         text not null,
    environment       text not null check (environment in ('Sandbox','Production')),
    granted_credits   int  not null,
    purchase_date_ms  bigint not null,
    raw_jws           text not null,
    created_at        timestamptz not null default now()
);

create index iap_receipts_user_idx on public.iap_receipts(user_id, created_at desc);
create index iap_receipts_original_idx on public.iap_receipts(original_transaction_id);

alter table public.iap_receipts enable row level security;

create policy "iap_receipts: self read" on public.iap_receipts
    for select to authenticated using (user_id = auth.uid());
